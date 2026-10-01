import 'dart:io';

/// ANSI colors and glyphs. With [enabled] false every method returns the
/// text unchanged, so output stays clean in pipes, logs and tests.
class Style {
  const Style(this.enabled, {this.unicode = true});

  /// No colors, ASCII glyphs.
  static const plain = Style(false, unicode: false);

  final bool enabled;
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

  String bold(String s) => _wrap('1', s);
  String dim(String s) => _wrap('2', s);
  String red(String s) => _wrap('31', s);
  String green(String s) => _wrap('32', s);
  String yellow(String s) => _wrap('33', s);
  String blue(String s) => _wrap('34', s);
  String magenta(String s) => _wrap('35', s);
  String cyan(String s) => _wrap('36', s);
  String boldCyan(String s) => _wrap('1;36', s);

  String get okMark => unicode ? '✔' : '+';
  String get errMark => unicode ? '✖' : 'x';
  String get warnMark => unicode ? '!' : '!';
  String get pointer => unicode ? '›' : '>';
  String get bullet => unicode ? '•' : '-';
  String get rule => unicode ? '─' : '-';
  String get heavyRule => unicode ? '━' : '=';

  String ok(String s) => '${green(okMark)} $s';
  String err(String s) => '${red(errMark)} ${red(s)}';
  String warn(String s) => '${yellow(warnMark)} ${yellow(s)}';
}
