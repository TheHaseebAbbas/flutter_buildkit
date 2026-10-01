import 'dart:io';

/// ANSI colors and glyphs. With [enabled] false every method returns the
/// text unchanged, so output stays clean in pipes, logs and tests.
class Style {
  /// Creates a style; [enabled] turns on colors and [unicode] allows non-ASCII glyphs.
  const Style(this.enabled, {this.unicode = true});

  /// No colors, ASCII glyphs.
  static const plain = Style(false, unicode: false);

  /// Whether ANSI colors are emitted.
  final bool enabled;

  /// Whether Unicode glyphs (rather than ASCII fallbacks) are used.
  final bool unicode;

  /// Colors when writing to a terminal, unless NO_COLOR is set (or
  /// FORCE_COLOR is).
  factory Style.detect({Map<String, String>? env}) {
    env ??= Platform.environment;
    // The classic Windows console (PowerShell 5, cmd) often cannot draw box
    // characters; Windows Terminal and the VS Code terminal can.
    final unicode = !Platform.isWindows ||
        env.containsKey('WT_SESSION') ||
        env['TERM_PROGRAM'] == 'vscode';
    if (env.containsKey('NO_COLOR')) return Style(false, unicode: unicode);
    if (env.containsKey('FORCE_COLOR')) return Style(true, unicode: unicode);
    var on = stdout.hasTerminal && env['TERM'] != 'dumb';
    if (on && Platform.isWindows) on = stdout.supportsAnsiEscapes;
    return Style(on, unicode: unicode);
  }

  String _wrap(String code, String s) => enabled ? '\x1b[${code}m$s\x1b[0m' : s;

  /// Returns [s] in bold.
  String bold(String s) => _wrap('1', s);

  /// Returns [s] dimmed.
  String dim(String s) => _wrap('2', s);

  /// Returns [s] in red.
  String red(String s) => _wrap('31', s);

  /// Returns [s] in green.
  String green(String s) => _wrap('32', s);

  /// Returns [s] in yellow.
  String yellow(String s) => _wrap('33', s);

  /// Returns [s] in blue.
  String blue(String s) => _wrap('34', s);

  /// Returns [s] in magenta.
  String magenta(String s) => _wrap('35', s);

  /// Returns [s] in cyan.
  String cyan(String s) => _wrap('36', s);

  /// Returns [s] in bold cyan.
  String boldCyan(String s) => _wrap('1;36', s);

  /// Mark for success.
  String get okMark => unicode ? '✔' : '+';

  /// Mark for failure.
  String get errMark => unicode ? '✖' : 'x';

  /// Mark for a warning.
  String get warnMark => unicode ? '!' : '!';

  /// Marker for the highlighted row.
  String get pointer => unicode ? '›' : '>';

  /// Bullet for list items.
  String get bullet => unicode ? '•' : '-';

  /// Light horizontal line character.
  String get rule => unicode ? '─' : '-';

  /// Heavy horizontal line character.
  String get heavyRule => unicode ? '━' : '=';

  /// Returns [s] prefixed with a green success mark.
  String ok(String s) => '${green(okMark)} $s';

  /// Returns [s] prefixed with a red failure mark, in red.
  String err(String s) => '${red(errMark)} ${red(s)}';

  /// Returns [s] prefixed with a yellow warning mark, in yellow.
  String warn(String s) => '${yellow(warnMark)} ${yellow(s)}';
}
