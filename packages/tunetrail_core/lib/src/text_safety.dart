/// Rules for text players type that other players see: usernames, direct
/// messages, notes and titles.
///
/// The game only ever shows this text as plain text (never as HTML,
/// Markdown or a link), and the server only stores it inside JSON, so text
/// can't run as code. These rules add defence in depth on top: they strip
/// invisible and direction-flipping characters (used to disguise names),
/// stop "Zalgo" stacks of accent marks, and keep characters used by HTML,
/// SQL and shell syntax out of usernames.
library;

const int kUsernameMin = 3;
const int kUsernameMax = 24;

/// Maximum length of a direct message.
const int kMaxMessageLength = 500;

final _allowed = RegExp(r'^[\p{L}\p{N}\p{M}\p{S}\p{P}]$', unicode: true);
final _pictographic = RegExp(r'^\p{Extended_Pictographic}$', unicode: true);
final _letterOrNumberOrSymbol = RegExp(r'[\p{L}\p{N}\p{So}]', unicode: true);
final _whitespace = RegExp(r'[\s\p{Z}]', unicode: true);
final _mark = RegExp(r'^[\p{Mn}\p{Me}]$', unicode: true);
final _otherControl = RegExp(r'^[\p{Cc}\p{Cf}\p{Co}\p{Cn}\p{Cs}]$', unicode: true);

const _zwj = 0x200D;

/// Characters kept out of usernames: they mean something in HTML, SQL,
/// URLs or shells, so a name can never be mistaken for markup or a command
/// if it's ever shown somewhere other than the game.
const kUsernameForbidden = '<>&"\'`\\/';

bool _isVariationSelector(int r) => (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0xE0100 && r <= 0xE01EF);
bool _isSkinTone(int r) => r >= 0x1F3FB && r <= 0x1F3FF;
bool _isRegionalIndicator(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
bool _isMark(int r) => _mark.hasMatch(String.fromCharCode(r));
bool _isPictographic(int r) => _pictographic.hasMatch(String.fromCharCode(r));

/// Visible characters in [s], counted like the text field counts them: an
/// emoji with skin tone, a flag or a family emoji is one character, and an
/// accent mark belongs to the letter before it.
int visibleLength(String s) {
  var n = 0;
  var afterZwj = false;
  var openFlag = false;
  for (final r in s.runes) {
    if (r == _zwj) {
      afterZwj = true;
      continue;
    }
    if (_isVariationSelector(r) || _isSkinTone(r) || _isMark(r) || (r >= 0xE0020 && r <= 0xE007F)) continue;
    if (afterZwj) {
      afterZwj = false;
      continue;
    }
    if (_isRegionalIndicator(r)) {
      if (openFlag) {
        openFlag = false;
        continue;
      }
      openFlag = true;
    } else {
      openFlag = false;
    }
    n++;
  }
  return n;
}

const _reserved = {
  'admin', 'administrator', 'moderator', 'mod', 'mods', 'support', 'official', 'system', 'staff', 'server',
  'dev', 'developer', 'help', 'root', 'null', 'undefined', 'everyone', 'here', 'owner', 'tunetrailteam',
};

/// Why [name] can't be used as a username, or null when it's fine.
/// [name] should already be trimmed.
String? usernameError(String name) {
  if (name.isEmpty) return 'Choose a username';
  if (_whitespace.hasMatch(name)) return 'No spaces — try _ or . instead';
  final runes = name.runes.toList();
  if (runes.length > 96) return 'That name is too long';
  for (final ch in kUsernameForbidden.split('')) {
    if (name.contains(ch)) return 'These characters aren\'t allowed: < > & " \' ` \\ /';
  }
  var marks = 0;
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (r == _zwj) {
      // Only inside emoji sequences (e.g. 👩‍💻), never hiding between letters.
      final prev = i > 0 ? runes[i - 1] : 0, next = i + 1 < runes.length ? runes[i + 1] : 0;
      final prevOk = _isPictographic(prev) || _isVariationSelector(prev) || _isSkinTone(prev);
      if (!prevOk || !_isPictographic(next)) return 'That name contains a hidden character';
      continue;
    }
    final ch = String.fromCharCode(r);
    if (_otherControl.hasMatch(ch) || !_allowed.hasMatch(ch)) return 'That name contains a character that isn\'t allowed';
    if (_isMark(r) && !_isVariationSelector(r)) {
      if (i == 0) return 'A name can\'t start with an accent mark';
      if (++marks > 2) return 'Too many accent marks on one letter';
    } else if (!_isVariationSelector(r)) {
      marks = 0;
    }
  }
  if (!_letterOrNumberOrSymbol.hasMatch(name)) return 'Use at least one letter, number or emoji';
  final len = visibleLength(name);
  if (len < kUsernameMin) return 'At least $kUsernameMin characters';
  if (len > kUsernameMax) return 'At most $kUsernameMax characters';
  final plain = usernameKey(name).replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (plain.contains('tunetrail') || _reserved.contains(plain)) return 'That name is reserved';
  return null;
}

/// The form two usernames are compared in: names whose keys are equal
/// count as the same name. Ignores letter case, accents, emoji style
/// selectors, full-width letters and the Cyrillic/Greek letters that look
/// exactly like Latin ones, so nobody can register a look-alike of
/// someone else's name.
String usernameKey(String name) {
  final out = StringBuffer();
  for (var r in name.toLowerCase().runes) {
    if (_isVariationSelector(r) || r == _zwj) continue;
    if (r >= 0x0300 && r <= 0x036F) continue; // combining accents
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0; // full-width → ASCII
    final folded = _fold[r];
    if (folded != null) {
      out.write(folded);
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString().toLowerCase();
}

/// Accented Latin letters → base letters, and look-alike letters from other
/// scripts → Latin.
final Map<int, String> _fold = () {
  final m = <int, String>{};
  void add(String chars, String base) {
    for (final r in chars.runes) {
      m[r] = base;
    }
  }

  add('àáâãäåāăąǎǟǡǻȁȃȧ', 'a');
  add('çćĉċč', 'c');
  add('ďđ', 'd');
  add('èéêëēĕėęěȅȇȩ', 'e');
  add('ĝğġģǧǵ', 'g');
  add('ĥħ', 'h');
  add('ìíîïĩīĭįıǐȉȋ', 'i');
  add('ĵǰ', 'j');
  add('ķǩ', 'k');
  add('ĺļľŀł', 'l');
  add('ñńņňŉǹ', 'n');
  add('òóôõöøōŏőǒǫǭǿȍȏȫȭȯȱ', 'o');
  add('ŕŗřȑȓ', 'r');
  add('śŝşšșß', 's');
  add('ţťŧț', 't');
  add('ùúûüũūŭůűųǔǖǘǚǜȕȗ', 'u');
  add('ŵ', 'w');
  add('ýÿŷȳ', 'y');
  add('źżžƶ', 'z');
  add('æ', 'ae');
  add('œ', 'oe');
  // Cyrillic and Greek letters drawn like Latin ones.
  add('аα', 'a');
  add('вβ', 'b');
  add('сϲ', 'c');
  add('еε', 'e');
  add('һ', 'h');
  add('іιї', 'i');
  add('ј', 'j');
  add('кκ', 'k');
  add('мμ', 'm');
  add('нη', 'n');
  add('оο', 'o');
  add('рρ', 'p');
  add('ѕ', 's');
  add('тτ', 't');
  add('υ', 'u');
  add('ν', 'v');
  add('ԝω', 'w');
  add('хχ', 'x');
  add('уγ', 'y');
  return m;
}();

/// Cleans free text (messages, notes, titles) before it's stored or shown:
/// removes invisible, control and direction-flipping characters, limits
/// stacked accent marks, collapses runs of blank lines and trims it to
/// [maxLength] characters.
String cleanUserText(String s, {required int maxLength, bool multiline = false}) {
  final out = StringBuffer();
  var marks = 0;
  var newlines = 0;
  var count = 0;
  final runes = s.replaceAll('\r\n', '\n').runes.toList();
  for (var i = 0; i < runes.length && count < maxLength; i++) {
    final r = runes[i];
    if (r == 0x0A) {
      if (!multiline) {
        out.write(' ');
        count++;
        continue;
      }
      if (++newlines > 2) continue;
      out.writeCharCode(r);
      count++;
      continue;
    }
    if (r == 0x09) {
      out.write(' ');
      count++;
      continue;
    }
    final ch = String.fromCharCode(r);
    if (r == _zwj) {
      final prev = i > 0 ? runes[i - 1] : 0, next = i + 1 < runes.length ? runes[i + 1] : 0;
      if ((_isPictographic(prev) || _isVariationSelector(prev) || _isSkinTone(prev)) && _isPictographic(next)) out.writeCharCode(r);
      continue;
    }
    if (_otherControl.hasMatch(ch) && !(r >= 0xE0020 && r <= 0xE007F)) continue;
    if (_isMark(r) && !_isVariationSelector(r)) {
      if (++marks > 2) continue;
    } else if (!_isVariationSelector(r)) {
      marks = 0;
    }
    if (!_isMark(r)) newlines = 0;
    out.writeCharCode(r);
    count++;
  }
  return out.toString().trim();
}
