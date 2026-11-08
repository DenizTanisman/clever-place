//! Clever Place core.
//!
//! Every game's rules, level generator and solver live here. The Flutter app is a pure renderer: it
//! talks to this crate through one C function, [`cp_call`], exchanging JSON messages.
//!
//! Protocol (request → response), all JSON objects:
//! - `{"op":"info"}` → `{"visible_levels","max_level","games":[…]}`
//! - `{"op":"new","game":"hanoi","level":1,"mode":"level"|"endless"}` → `{"id":7,"state":{...}}`
//! - `{"op":"act","id":7,"action":{...}}` → `{"ok":true,"state":{...}}` or `{"ok":false,"error":"…","state":{...}}`
//! - `{"op":"tick","id":7,"dt":16.6}` → `{"state":{...}}` (real-time games only; others ignore it)
//! - `{"op":"drop","id":7}` → `{"ok":true}`
//!
//! Every state object carries at least `status` (`"playing" | "won" | "lost"`) and `stars` (0–3,
//! meaningful once won). Everything else is game-specific and documented in each game module.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

pub mod games;
pub mod rng;

/// How many levels each level-based game currently exposes. Generators accept any level in
/// `1..=MAX_LEVEL`; this constant only gates what the app shows (preview first, then the full set).
pub const VISIBLE_LEVELS: u32 = 500;
/// Upper bound every generator must support.
pub const MAX_LEVEL: u32 = 500;

/// A running game. Created from (game, level, mode); driven by actions and, for real-time games,
/// by ticks.
pub trait Session: Send {
    /// Full renderable state as JSON.
    fn state(&self) -> Value;
    /// Apply a player action. `Err` = illegal action (state must be unchanged).
    fn act(&mut self, action: &Value) -> Result<(), String>;
    /// Advance real time by `dt_ms` milliseconds. Turn-based games keep the default no-op.
    fn tick(&mut self, _dt_ms: f64) {}
}

struct Registry {
    next_id: u64,
    sessions: HashMap<u64, Box<dyn Session>>,
}

static REGISTRY: Mutex<Option<Registry>> = Mutex::new(None);

/// Handle one JSON request and return the JSON response (pure Rust entry point, used by tests and by
/// the FFI wrapper).
pub fn handle(req: &str) -> Value {
    let req: Value = match serde_json::from_str(req) {
        Ok(v) => v,
        Err(e) => return json!({"ok": false, "error": format!("bad json: {e}")}),
    };
    let op = req["op"].as_str().unwrap_or("");
    let mut guard = REGISTRY.lock().unwrap_or_else(|p| p.into_inner());
    let reg = guard.get_or_insert_with(|| Registry { next_id: 1, sessions: HashMap::new() });
    match op {
        "info" => json!({
            "ok": true,
            "visible_levels": VISIBLE_LEVELS,
            "max_level": MAX_LEVEL,
            "games": games::GAME_IDS,
        }),
        "new" => {
            let game = req["game"].as_str().unwrap_or("");
            let level = req["level"].as_u64().unwrap_or(1).clamp(1, MAX_LEVEL as u64) as u32;
            let mode = req["mode"].as_str().unwrap_or("level");
            match games::create(game, level, mode) {
                Ok(s) => {
                    let id = reg.next_id;
                    reg.next_id += 1;
                    let state = s.state();
                    reg.sessions.insert(id, s);
                    json!({"ok": true, "id": id, "state": state})
                }
                Err(e) => json!({"ok": false, "error": e}),
            }
        }
        "act" => with_session(reg, &req, |s| match s.act(&req["action"]) {
            Ok(()) => json!({"ok": true, "state": s.state()}),
            Err(e) => json!({"ok": false, "error": e, "state": s.state()}),
        }),
        "tick" => with_session(reg, &req, |s| {
            let dt = req["dt"].as_f64().unwrap_or(16.0).clamp(0.0, 250.0);
            s.tick(dt);
            json!({"ok": true, "state": s.state()})
        }),
        "drop" => {
            if let Some(id) = req["id"].as_u64() {
                reg.sessions.remove(&id);
            }
            json!({"ok": true})
        }
        _ => json!({"ok": false, "error": format!("unknown op: {op}")}),
    }
}

fn with_session(reg: &mut Registry, req: &Value, f: impl FnOnce(&mut Box<dyn Session>) -> Value) -> Value {
    let Some(id) = req["id"].as_u64() else {
        return json!({"ok": false, "error": "missing id"});
    };
    match reg.sessions.get_mut(&id) {
        Some(s) => {
            // A bug in one game must never take the whole app down.
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(s))) {
                Ok(v) => v,
                Err(_) => json!({"ok": false, "error": "internal error"}),
            }
        }
        None => json!({"ok": false, "error": "no such session"}),
    }
}

/// FFI entry point: takes a NUL-terminated UTF-8 JSON request, returns a newly allocated
/// NUL-terminated JSON response that the caller must release with [`cp_free`].
///
/// # Safety
/// `req` must be a valid pointer to a NUL-terminated string (or null).
#[no_mangle]
pub unsafe extern "C" fn cp_call(req: *const c_char) -> *mut c_char {
    let out = if req.is_null() {
        json!({"ok": false, "error": "null request"})
    } else {
        let s = CStr::from_ptr(req).to_string_lossy();
        std::panic::catch_unwind(|| handle(&s)).unwrap_or_else(|_| json!({"ok": false, "error": "panic"}))
    };
    CString::new(out.to_string()).unwrap_or_default().into_raw()
}

/// Release a string returned by [`cp_call`].
///
/// # Safety
/// `p` must come from [`cp_call`] and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn cp_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
