#!/usr/bin/env python3
"""Records the 3D cube player for the promo's `cube_player` clip and lays it into that clip.

The player is a web page (assets/cube/player, three.js) that the app shows in a WebView; the Flutter
test engine cannot draw a WebView, so the clip's scene draws the page frame around an empty box and
writes the box to cube_player_box.json. This script opens the same page in headless Chromium at the
phone's size, plays the Y-perm the way the app does (KupApp.open, then the play button), drives the
page's clock (performance.now, requestAnimationFrame, setTimeout) one video frame at a time, and overlays the frames onto the clip in that box.

Usage: python3 tool/promo/cube3d.py build/promo          (needs: pip install playwright; playwright install chromium)
"""
import json
import pathlib
import subprocess
import sys

from playwright.sync_api import sync_playwright

APP = pathlib.Path(__file__).resolve().parents[2]
PAGE = APP / 'assets/cube/player/index.html'
FPS = 30
DPR = 3              # the promo's output pixels per frame unit (Stage.dpr)
FADE = 5             # frames the stage fades a scene in and out
CASE, ROW, LABEL = 'm6957abd907', 0, 'OH · 2 el'   # Y-perm from Küp Defteri
SPEED = 1            # one of the player's speeds (0.25, 0.5, 1, 2); 1 is the app's default
PLAY_AT = 1.0        # seconds into the clip the play button is pressed


# The page's clock, stepped by us: animation frames and timers run only in __step(ms).
CLOCK = """(() => {
  let now = 0, rafs = [], timers = [];
  performance.now = () => now;
  window.requestAnimationFrame = cb => { rafs.push(cb); return rafs.length; };
  window.cancelAnimationFrame = () => {};
  window.setTimeout = (cb, ms) => { timers.push({ t: now + (ms || 0), cb }); return timers.length; };
  window.clearTimeout = id => { if (timers[id - 1]) timers[id - 1].cb = null; };
  window.__step = dt => {
    now += dt;
    for (const x of timers) if (x.cb && x.t <= now) { const c = x.cb; x.cb = null; c(); }
    const due = rafs; rafs = [];
    due.forEach(cb => cb(now));
  };
})();"""


def main(out: pathlib.Path) -> None:
    clip = next(out.glob('[0-9][0-9]_cube_player.mp4'))
    box = json.loads((out / 'cube_player_box.json').read_text())
    frames = int(subprocess.check_output([
        'ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0',
        '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', str(clip)]).strip())
    scale = box['scale']
    vw, vh = round(box['w'] / scale), round(box['h'] / scale)   # the WebView's size in app pixels
    entry = json.loads((APP / 'assets/cube/player/player_index.json').read_text())['cases'][CASE][ROW]
    entry = {**entry, 'label': LABEL, 'speed': SPEED}

    shots = out / 'cube3d'
    shots.mkdir(exist_ok=True)
    for f in shots.glob('*.png'):
        f.unlink()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'])
        ctx = browser.new_context(viewport={'width': vw, 'height': vh}, device_scale_factor=scale * DPR)
        page = ctx.new_page()
        page.add_init_script(CLOCK)
        page.goto(PAGE.as_uri())
        page.wait_for_function('window.KupApp && window.THREE')
        page.evaluate('e => KupApp.open(e)', entry)
        page.wait_for_function('KupApp.state() && KupApp.state().gl')
        played = False
        for i in range(frames):
            if not played and i >= PLAY_AT * FPS:
                page.evaluate("document.querySelector('[data-act=play]').click()")
                played = True
            page.evaluate(f'__step({1000 / FPS})')
            page.screenshot(path=str(shots / f'{i:04d}.png'), omit_background=True)
        state = page.evaluate('KupApp.state()')
        browser.close()
    print(f'cube3d: {frames} frames, player at move {state["i"]}/{state["n"]}')

    # Lay the frames into the box, fading with the stage.
    x, y = round(box['x'] * DPR), round(box['y'] * DPR)
    end = (frames - FADE) / FPS
    tmp = clip.with_suffix('.tmp.mp4')
    subprocess.check_call([
        'ffmpeg', '-y', '-loglevel', 'error', '-i', str(clip), '-framerate', str(FPS), '-i', str(shots / '%04d.png'),
        '-filter_complex',
        f'[1]format=rgba,fade=in:st=0:d={FADE / FPS}:alpha=1,fade=out:st={end}:d={FADE / FPS}:alpha=1[p];'
        f'[0][p]overlay={x}:{y}:shortest=1',
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '15', '-pix_fmt', 'yuv420p', str(tmp)])
    tmp.replace(clip)


if __name__ == '__main__':
    main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/promo'))
