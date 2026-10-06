import 'dart:async';
import 'dart:io';

import 'keys.dart';
import 'select_model.dart';
import 'style.dart';

/// Thrown when the user presses Ctrl-C inside a prompt.
class ConsoleAbort implements Exception {
  /// Creates the exception thrown when a prompt is aborted.
  ConsoleAbort();

  @override
  String toString() => 'Aborted.';
}

/// How prompts read input.
enum UiMode {
  /// Arrow keys on a real terminal, numbered questions otherwise.
  auto,

  /// Force arrow-key prompts.
  keys,

  /// Always numbered questions (type 2, or 1,3 for several, then Enter).
  plain;

  /// Parses a `--ui` value (`keys`, `plain`, ...), defaulting to [auto] when unknown or null.
  static UiMode parse(String? value) => switch (value?.toLowerCase()) {
        'keys' || 'arrows' || 'interactive' => UiMode.keys,
        'plain' || 'numbers' || 'text' => UiMode.plain,
        _ => UiMode.auto,
      };
}

/// Prompts and styled output for the menu.
///
/// On a real terminal lists are driven with the arrow keys, Space, and typed
/// numbers. When stdin or stdout is not a terminal, on Windows, or with
/// `--ui plain`, every prompt is a plain numbered question instead.
class Console {
  /// Creates a console.
  ///
  /// When [readLine] or [write] is given (tests, piping) the console is
  /// non-interactive and uses plain styling; otherwise [mode] and the terminal
  /// decide whether arrow-key prompts are used.
  Console({
    String? Function()? readLine,
    void Function(String)? write,
    UiMode mode = UiMode.auto,
    Style? style,
    bool? interactive,
  })  : _rawReadLine = readLine ?? stdin.readLineSync,
        _write = write ?? stdout.write,
        style = style ??
            (readLine == null && write == null ? Style.detect() : Style.plain),
        interactive = interactive ??
            (readLine == null && write == null && _wantsKeys(mode));

  /// Set by the entry point after `WindowsConsole.enable` succeeds.
  static bool windowsKeysReady = false;

  static bool _wantsKeys(UiMode mode) {
    if (mode == UiMode.plain) return false;
    if (!stdin.hasTerminal || !stdout.hasTerminal) return false;
    if (mode == UiMode.keys) return true;
    if (Platform.environment['TERM'] == 'dumb') return false;
    // Dart only receives arrow keys from the Windows console once virtual
    // terminal input is on (see WindowsConsole); otherwise use numbers.
    if (Platform.isWindows) return windowsKeysReady;
    return true;
  }

  final String? Function() _rawReadLine;

  /// True once plain-mode input has run out (piped stdin, end of file).
  /// Loops that keep asking should stop when this is set.
  bool inputEnded = false;

  String? _readLine() {
    final line = _rawReadLine();
    if (line == null) inputEnded = true;
    return line;
  }

  final void Function(String) _write;

  /// Colors and glyphs.
  final Style style;

  /// True when prompts use raw key input.
  final bool interactive;

  StreamIterator<List<int>>? _input;
  Future<bool>? _pendingMove;
  final List<KeyPress> _queue = [];

  // ---- output --------------------------------------------------------------

  /// Writes [text] followed by a newline.
  void out(String text) => _write('$text\n');

  /// Writes an empty line.
  void blank() => _write('\n');

  /// Writes [text] as is, without a trailing newline.
  void raw(String text) => _write(text);

  int get _columns {
    try {
      return interactive && stdout.hasTerminal ? stdout.terminalColumns : 80;
    } on Object {
      return 80;
    }
  }

  int get _rows {
    try {
      return interactive && stdout.hasTerminal ? stdout.terminalLines : 24;
    } on Object {
      return 24;
    }
  }

  /// A boxed title with optional lines underneath.
  void banner(String title, [List<String> bannerLines = const []]) {
    // Long paths are cut from the left so the box fits the terminal.
    final maxInner = (_columns - 6).clamp(30, 200);
    String fit(String l) => l.length <= maxInner
        ? l
        : '${style.unicode ? '…' : '...'}${l.substring(l.length - maxInner + (style.unicode ? 1 : 3))}';
    final lines = [for (final l in bannerLines) fit(l)];
    final all = [title, ...lines];
    final inner = all.map((l) => l.length).reduce((a, b) => a > b ? a : b);
    final width = inner + 4;
    final u = style.unicode;
    final top = u ? '╭${'─' * width}╮' : '+${'-' * width}+';
    final bottom = u ? '╰${'─' * width}╯' : '+${'-' * width}+';
    final side = u ? '│' : '|';
    String row(String text, String Function(String) paint) =>
        '${style.cyan(side)}  ${paint(text)}${' ' * (inner - text.length)}  ${style.cyan(side)}';
    out('');
    out(style.cyan(top));
    out(row(title, style.bold));
    for (final l in lines) {
      out(row(l, style.dim));
    }
    out(style.cyan(bottom));
  }

  /// A section title with a rule across the screen.
  void heading(String text) {
    final fill = (_columns.clamp(20, 100) - text.length - 4).clamp(2, 100);
    out('');
    out('${style.cyan(style.heavyRule * 2)} ${style.bold(text)} '
        '${style.cyan(style.heavyRule * fill)}');
  }

  /// `label  value` with the label dimmed and aligned to [labelWidth].
  void kv(String label, String value, {int labelWidth = 14}) =>
      out('${style.dim(label.padRight(labelWidth))}$value');

  /// Prints [text] as a success line, with a green check mark.
  void success(String text) => out(style.ok(text));

  /// Prints [text] as an error line, in red.
  void error(String text) => out(style.err(text));

  /// Prints [text] as a warning line, in yellow.
  void warn(String text) => out(style.warn(text));

  /// Prints [text] dimmed, for secondary information.
  void note(String text) => out(style.dim(text));

  // ---- raw key input -----------------------------------------------------

  /// Reads one chunk of terminal input. With a [timeout], returns null if
  /// nothing arrives in time (the read stays pending for the next call).
  Future<List<int>?> _readChunk([Duration? timeout]) async {
    final input = _input ??= StreamIterator(stdin);
    final move = _pendingMove ??= input.moveNext();
    if (timeout != null) {
      final ready = await Future.any<bool?>(
          [move, Future<bool?>.delayed(timeout, () => null)]);
      if (ready == null) return null;
    }
    final more = await move;
    _pendingMove = null;
    if (!more) throw ConsoleAbort();
    return input.current;
  }

  Future<KeyPress> _nextKey() async {
    while (_queue.isEmpty) {
      var bytes = [...(await _readChunk())!];
      // A lone ESC may be the start of an arrow key whose remaining bytes are
      // still on the way (slow terminals, SSH): wait briefly for them.
      while (endsInIncompleteSequence(bytes)) {
        final more = await _readChunk(const Duration(milliseconds: 60));
        if (more == null) break;
        bytes = [...bytes, ...more];
      }
      _queue.addAll(parseKeys(bytes));
    }
    final k = _queue.removeAt(0);
    if (k.key == Key.ctrlC) throw ConsoleAbort();
    return k;
  }

  Future<T> _raw<T>(Future<T> Function() body) async {
    final echo = stdin.echoMode;
    final line = stdin.lineMode;
    stdin.echoMode = false;
    stdin.lineMode = false;
    try {
      return await body();
    } finally {
      stdin.lineMode = line;
      stdin.echoMode = echo;
    }
  }

  // ---- text prompts ------------------------------------------------------

  String _prompt(String question, String hint) =>
      '${style.bold(question)}${hint.isEmpty ? '' : ' ${style.dim(hint)}'}'
      '${style.cyan(' ${style.pointer} ')}';

  /// Free text. Empty input returns [defaultValue]. Returns null on Esc or
  /// end of input.
  Future<String?> ask(String question, {String? defaultValue}) async {
    final hint = defaultValue == null ? '' : '[$defaultValue]';
    if (!interactive) {
      _write(_prompt(question, hint));
      final line = _readLine();
      if (line == null) return null;
      final value = line.trim();
      return value.isEmpty ? defaultValue : value;
    }
    final value = await _raw(() => _editLine(_prompt(question, hint)));
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? defaultValue : trimmed;
  }

  /// Reads one line with basic editing. Null when Esc is pressed.
  Future<String?> _editLine(String prompt, {bool echoNewline = true}) async {
    final buffer = StringBuffer();
    _write(prompt);
    while (true) {
      final k = await _nextKey();
      switch (k.key) {
        case Key.enter:
          if (echoNewline) _write('\n');
          return buffer.toString();
        case Key.escape:
          _write('\n');
          return null;
        case Key.backspace:
          final s = buffer.toString();
          if (s.isNotEmpty) {
            final runes = s.runes.toList()..removeLast();
            buffer
              ..clear()
              ..write(String.fromCharCodes(runes));
            _write('\b \b');
          }
        case Key.ctrlU:
          final n = buffer.toString().runes.length;
          buffer.clear();
          _write('\b \b' * n);
        case Key.space:
          buffer.write(' ');
          _write(' ');
        case Key.char:
          buffer.write(k.char);
          _write(k.char);
        default:
          break;
      }
    }
  }

  /// Several lines until a line holding only [endMarker] (or Esc/EOF).
  /// Meant for pasting a stack trace.
  Future<String> readLines(String instruction, {String endMarker = '.'}) async {
    out(instruction);
    final lines = <String>[];
    if (!interactive) {
      while (true) {
        final line = _readLine();
        if (line == null || line.trim() == endMarker) break;
        lines.add(line);
      }
      return lines.join('\n');
    }
    await _raw(() async {
      while (true) {
        final line = await _editLine('', echoNewline: true);
        if (line == null || line.trim() == endMarker) break;
        lines.add(line);
      }
    });
    return lines.join('\n');
  }

  /// Asks a yes/no question and returns the answer.
  ///
  /// Enter picks [defaultValue]; in plain mode returns false when input ends.
  Future<bool> confirm(String question, {bool defaultValue = false}) async {
    final hint = defaultValue ? 'Y/n' : 'y/N';
    if (!interactive) {
      while (true) {
        _write(_prompt(question, '[$hint]'));
        final line = _readLine();
        if (line == null) return false;
        switch (line.trim().toLowerCase()) {
          case '':
            return defaultValue;
          case 'y' || 'yes':
            return true;
          case 'n' || 'no':
            return false;
        }
        out('Please answer y or n.');
      }
    }
    return _raw(() async {
      _write(_prompt(question, '[$hint]'));
      while (true) {
        final k = await _nextKey();
        final answer = switch (k) {
          KeyPress(key: Key.enter) => defaultValue,
          KeyPress(key: Key.escape) => false,
          KeyPress(key: Key.char, char: 'y' || 'Y') => true,
          KeyPress(key: Key.char, char: 'n' || 'N') => false,
          _ => null,
        };
        if (answer != null) {
          _write('${answer ? style.green('yes') : style.yellow('no')}\n');
          return answer;
        }
      }
    });
  }

  /// Asks until the answer parses as an int; null on Esc/EOF.
  Future<int?> askInt(String question, {int? defaultValue}) async {
    while (true) {
      final value = await ask(question, defaultValue: defaultValue?.toString());
      if (value == null) return null;
      final n = int.tryParse(value);
      if (n != null) return n;
      out(style.red('Enter a whole number.'));
    }
  }

  // ---- lists ---------------------------------------------------------------

  /// Single choice; returns the index or null for back/cancel.
  Future<int?> choose(
    String title,
    List<String> options, {
    int? defaultIndex,
    String backLabel = 'Back',
    List<String>? hints,
  }) async {
    final items = [
      for (var i = 0; i < options.length; i++)
        SelectItem(options[i], hint: hints?[i]),
    ];
    final result = await _select(title, items,
        multi: false, initial: defaultIndex, backLabel: backLabel);
    return result?.first;
  }

  /// Multi choice. Returns the ticked indexes (sorted), an empty list when
  /// confirmed with nothing ticked, or null when cancelled. [ticked] pre-ticks
  /// rows; [disabled] rows are shown but cannot be ticked.
  Future<List<int>?> chooseMany(
    String title,
    List<String> options, {
    Set<int>? ticked,
    Set<int> disabled = const {},
    List<String>? hints,
  }) async {
    final items = [
      for (var i = 0; i < options.length; i++)
        SelectItem(options[i], hint: hints?[i], disabled: disabled.contains(i)),
    ];
    return _select(title, items, multi: true, ticked: ticked);
  }

  Future<List<int>?> _select(
    String title,
    List<SelectItem> items, {
    required bool multi,
    int? initial,
    Set<int>? ticked,
    String backLabel = 'Back',
  }) async {
    if (items.isEmpty) return null;
    return interactive
        ? _selectInteractive(title, items,
            multi: multi, initial: initial, ticked: ticked)
        : _selectPlain(title, items,
            multi: multi,
            initial: initial,
            ticked: ticked,
            backLabel: backLabel);
  }

  Future<List<int>?> _selectInteractive(
    String title,
    List<SelectItem> items, {
    required bool multi,
    int? initial,
    Set<int>? ticked,
  }) async {
    final model =
        SelectModel(items, multi: multi, initial: initial, ticked: ticked);
    final maxRows = (_rows - 8).clamp(4, 20);
    var drawn = 0;

    void draw() {
      if (drawn > 0) _write('\x1b[${drawn}A');
      final lines = renderSelect(title, model, maxRows: maxRows, style: style);
      _write('\x1b[J${lines.join('\n')}\n');
      drawn = lines.length;
    }

    _write('\x1b[?25l');
    try {
      return await _raw(() async {
        _write('\n');
        draw();
        while (true) {
          final outcome = model.handle(await _nextKey());
          switch (outcome) {
            case SelectOutcome.cancel:
              _clear(drawn);
              return null;
            case SelectOutcome.submit:
              _clear(drawn);
              final picked = model.result;
              _write(
                  '${style.bold(title)} ${style.cyan(_summary(items, picked))}\n');
              return picked;
            case SelectOutcome.none:
              draw();
          }
        }
      });
    } finally {
      _write('\x1b[?25h');
    }
  }

  void _clear(int lines) {
    if (lines > 0) _write('\x1b[${lines}A\x1b[J');
  }

  String _summary(List<SelectItem> items, List<int> picked) {
    if (picked.isEmpty) return '-';
    if (picked.length == items.length && items.length > 1) return 'all';
    final names = [for (final i in picked) items[i].label];
    return names.length <= 3 ? names.join(', ') : '${names.length} selected';
  }

  /// Numbered questions: `2` for one, `1,3` / `1-3` / `a` for several.
  Future<List<int>?> _selectPlain(
    String title,
    List<SelectItem> items, {
    required bool multi,
    int? initial,
    Set<int>? ticked,
    String backLabel = 'Back',
  }) async {
    final width = '${items.length}'.length;
    while (true) {
      out('');
      out(style.boldCyan(title));
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        final mark = multi && (ticked?.contains(i) ?? false) ? '*' : ' ';
        final label =
            it.disabled ? style.dim('${it.label} (unavailable)') : it.label;
        final hint = it.hint == null ? '' : '  ${style.dim(it.hint!)}';
        out('  ${style.cyan('${i + 1}'.padLeft(width))})$mark $label$hint');
      }
      if (!multi) {
        out('  ${style.dim('0'.padLeft(width))}) ${style.dim(backLabel)}');
      }
      final hint = multi
          ? (ticked == null || ticked.isEmpty
              ? '[numbers like 1,3 or 1-3, a = all, none, Enter = cancel]'
              : '[numbers like 1,3 or 1-3, a = all, none, Enter = keep * ticked]')
          : (initial == null ? '' : '[${initial + 1}]');
      _write(_prompt(multi ? 'Select' : 'Choose', hint));
      final line = _readLine();
      if (line == null) return null;
      final text = line.trim().toLowerCase();
      final enabled = [
        for (var i = 0; i < items.length; i++)
          if (!items[i].disabled) i,
      ];

      if (multi) {
        if (text.isEmpty) {
          return ticked == null || ticked.isEmpty
              ? null
              : (ticked.toList()..sort());
        }
        if (text == 'none' || text == '0') return [];
        if (text == 'a' || text == 'all') return enabled;
        final numbers = parseNumberList(text) ??
            _matchLabels(items, text.split(RegExp(r'\s*,\s*')));
        if (numbers != null &&
            numbers.every(
                (n) => n >= 1 && n <= items.length && !items[n - 1].disabled)) {
          return {for (final n in numbers) n - 1}.toList()..sort();
        }
        out(style.red(
            'Type numbers between 1 and ${items.length}, like 1,3 or 1-3.'));
      } else {
        if (text.isEmpty && initial != null) return [initial];
        final numbers = parseNumberList(text) ?? _matchLabels(items, [text]);
        final n = numbers?.length == 1 ? numbers!.first : null;
        if (n == 0) return null;
        if (n != null &&
            n >= 1 &&
            n <= items.length &&
            !items[n - 1].disabled) {
          return [n - 1];
        }
        out(style.red('Type a number from 0 to ${items.length}.'));
      }
    }
  }

  /// Numbers (1-based) of the items whose label equals or uniquely starts
  /// with each word in [words], or null when any word matches nothing.
  List<int>? _matchLabels(List<SelectItem> items, List<String> words) {
    final out = <int>[];
    for (final w in words) {
      if (w.isEmpty) return null;
      final exact = [
        for (var i = 0; i < items.length; i++)
          if (items[i].label.toLowerCase() == w) i + 1,
      ];
      final starts = [
        for (var i = 0; i < items.length; i++)
          if (items[i].label.toLowerCase().startsWith(w)) i + 1,
      ];
      final hit = exact.length == 1 ? exact : starts;
      if (hit.length != 1) return null;
      out.add(hit.first);
    }
    return out;
  }
}
