// Clever Place in Turkish or English (owner, 2026-11-24). The Turkish text in the code is the source
// and the key: [t] returns it as is in Turkish, its English from the dictionary in English. Scope:
// interface, game names, rules, in-game messages and result screens. Language-bound content stays
// Turkish in both (Doğru Söz, IQ verbal items, word lists, listening stories, the tutorial courses).
//
// The dictionary is split by area so several people can add to it at once:
// en_shell.dart (hub, game page, result, settings), en_views.dart / en_views2.dart (game screens), en_catalog.dart
// (game names, categories, taglines), en_core.dart (messages the Rust core writes).

import 'en_catalog.dart';
import 'en_core.dart';
import 'en_shell.dart';
import 'en_views.dart';
import 'en_views2.dart';

/// The language Clever Place shows. Set from the app's locale ([main.dart] builder); anything but
/// English is Turkish.
class Lang {
  Lang._();
  static bool en = false;

  static String get code => en ? 'en' : 'tr';

  static void set(String languageCode) => en = languageCode == 'en';

  static final Map<String, String> _dict = {...enCoreExact, ...enCatalog, ...enShell, ...enViews, ...enViews2};

  /// English for [tr], or null when the dictionary has none (tests use this to find gaps).
  static String? english(String tr) => _dict[tr];

  static List<CoreTemplate>? _templates;
  static List<CoreTemplate> get templates => _templates ??= [
        for (final e in enCoreTemplates)
          // A template that is nothing but holes would match every line.
          if (e.$1.replaceAll(RegExp(r'\{\d*\}'), '').trim().isNotEmpty) CoreTemplate(e.$1, e.$2),
      ];

  /// Results of [ct], so a string the core repeats every frame is matched once.
  static final Map<String, String> _coreCache = {};
}

/// [tr] in the app's language.
String t(String tr) => Lang.en ? (Lang._dict[tr] ?? tr) : tr;

/// [tr] with `{0}`, `{1}` … filled from [args], in the app's language. The English text uses the same
/// placeholders, in whatever order the sentence needs.
String tf(String tr, List<Object?> args) {
  var s = Lang.en ? (Lang._dict[tr] ?? tr) : tr;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}

/// Text written by the Rust core (goal lines, summaries, refusals, labels): an exact dictionary entry,
/// else a template with `{}` holes for the numbers and words the core fills in, else each part of a
/// "a · b" line on its own. Untranslated text stays as it is.
String ct(String? s) {
  if (s == null) return '';
  if (!Lang.en || s.isEmpty) return s;
  final cached = Lang._coreCache[s];
  if (cached != null) return cached;
  final out = _core(s) ?? (s.contains(' · ') ? s.split(' · ').map((p) => _core(p) ?? p).join(' · ') : s);
  if (Lang._coreCache.length > 4000) Lang._coreCache.clear();
  return Lang._coreCache[s] = out;
}

String? _core(String s) {
  final exact = Lang._dict[s];
  if (exact != null) return exact;
  for (final tpl in Lang.templates) {
    final r = tpl.apply(s);
    if (r != null) return r;
  }
  return null;
}

/// One core message with holes: Turkish `"Bu satırda zaten {} var"` → English `"This row already has a {}"`.
/// Holes are `{}` (Rust's format holes, filled in order) or `{0}`, `{1}` … when English needs another
/// order. A hole matches any text.
class CoreTemplate {
  final RegExp _re;
  final String _en;
  CoreTemplate(String tr, this._en) : _re = _compile(tr);

  static RegExp _compile(String tr) {
    final joined = tr.contains(' · ');
    final b = StringBuffer('^');
    var i = 0;
    final holes = RegExp(r'\{\d*\}');
    for (final m in holes.allMatches(tr)) {
      b.write(RegExp.escape(tr.substring(i, m.start)));
      // A hole never spans a " · " join unless the template itself has one; the split fallback in
      // ct() then translates each part.
      b.write(joined ? '(.+?)' : '((?:(?! · ).)+?)');
      i = m.end;
    }
    b.write(RegExp.escape(tr.substring(i)));
    b.write(r'$');
    return RegExp(b.toString(), dotAll: true);
  }

  String? apply(String s) {
    final m = _re.firstMatch(s);
    if (m == null) return null;
    var n = 0;
    // `{}` holes take the groups in order; `{k}` takes group k + 1.
    return _en.replaceAllMapped(RegExp(r'\{(\d*)\}'), (h) {
      final k = h.group(1)!.isEmpty ? n++ : int.parse(h.group(1)!);
      final g = k + 1 <= m.groupCount ? m.group(k + 1) : null;
      // Words the core put in a hole (a tier, a colour) are translated too; never the whole line again.
      return g == null ? '' : (g == s ? g : ct(g));
    });
  }
}
