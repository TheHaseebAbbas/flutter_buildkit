import 'dart:async';
import 'dart:io';

import 'keys.dart';
import 'select_model.dart';

/// Thrown when the user presses Ctrl-C inside a prompt.
class ConsoleAbort implements Exception {
  @override
  String toString() => 'Aborted.';
}

/// Prompts for the menu: arrow-key lists, space multi-select, line input.
///
/// On a real terminal the prompts are interactive (raw key input). When
/// stdin or stdout is not a terminal (pipes, CI, tests) every prompt falls
/// back to plain numbered questions read line by line.
class Console {
  Console({
    String? Function()? readLine,
    void Function(String)? write,
    bool? interactive,
  })  : _readLine = readLine ?? stdin.readLineSync,
        _write = write ?? stdout.write,
        interactive = interactive ??
            (readLine == null &&
                write == null &&
                stdin.hasTerminal &&
                stdout.hasTerminal);

  final String? Function() _readLine;
  final void Function(String) _write;

  /// True when prompts use raw key input.
  final bool interactive;

  StreamIterator<List<int>>? _input;
  final List<KeyPress> _queue = [];

  void out(String text) => _write('$text\n');
  void blank() => _write('\n');
  void heading(String text) => _write('\n== $text ==\n');
  void raw(String text) => _write(text);

  int get _rows =>
      interactive && stdout.hasTerminal ? stdout.terminalLines : 24;

  // ---- raw key input -----------------------------------------------------

  Future<KeyPress> _nextKey() async {
    while (_queue.isEmpty) {
      final input = _input ??= StreamIterator(stdin);
      if (!await input.moveNext()) throw ConsoleAbort();
      _queue.addAll(parseKeys(input.current));
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

  /// Free text. Empty input returns [defaultValue]. Returns null on Esc or
  /// end of input.
  Future<String?> ask(String question, {String? defaultValue}) async {
    final hint = defaultValue == null ? '' : ' [$defaultValue]';
    if (!interactive) {
      _write('$question$hint: ');
      final line = _readLine();
      if (line == null) return null;
      final value = line.trim();
      return value.isEmpty ? defaultValue : value;
    }
    final value = await _raw(() => _editLine('$question$hint: '));
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

  Future<bool> confirm(String question, {bool defaultValue = false}) async {
    final hint = defaultValue ? 'Y/n' : 'y/N';
    if (!interactive) {
      while (true) {
        _write('$question [$hint]: ');
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
      _write('$question [$hint] ');
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
          _write('${answer ? 'yes' : 'no'}\n');
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
      out('Enter a whole number.');
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
  /// confirmed with nothing ticked, or null when cancelled. [ticked] pre-ticks rows; [items] may
  /// contain disabled rows that cannot be ticked.
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
            multi: multi, initial: initial, backLabel: backLabel);
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
    final maxRows = (_rows - 6).clamp(4, 20);
    var drawn = 0;

    void draw() {
      if (drawn > 0) _write('\x1b[${drawn}A');
      final lines = renderSelect(title, model, maxRows: maxRows);
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
              _write('$title ${_summary(items, picked)}\n');
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

  Future<List<int>?> _selectPlain(
    String title,
    List<SelectItem> items, {
    required bool multi,
    int? initial,
    String backLabel = 'Back',
  }) async {
    while (true) {
      out('\n$title');
      for (var i = 0; i < items.length; i++) {
        final tag = items[i].disabled ? ' (unavailable)' : '';
        out('  ${i + 1}) ${items[i].label}$tag');
      }
      if (!multi) out('  0) $backLabel');
      final hint = initial == null || multi ? '' : ' [${initial + 1}]';
      _write(multi
          ? 'Numbers (e.g. 1,3), "a" for all, "none", Enter to cancel: '
          : 'Choose$hint: ');
      final line = _readLine();
      if (line == null) return null;
      final text = line.trim().toLowerCase();
      if (multi) {
        if (text.isEmpty) return null;
        if (text == 'none' || text == '0') return [];
        final enabled = [
          for (var i = 0; i < items.length; i++)
            if (!items[i].disabled) i,
        ];
        if (text == 'a' || text == 'all') return enabled;
        final picks = text.split(RegExp(r'[,\s]+')).map(int.tryParse).toList();
        if (picks.every((n) =>
            n != null &&
            n >= 1 &&
            n <= items.length &&
            !items[n - 1].disabled)) {
          return {for (final n in picks) n! - 1}.toList()..sort();
        }
        out('Enter numbers between 1 and ${items.length}.');
      } else {
        if (text.isEmpty && initial != null) return [initial];
        final n = int.tryParse(text);
        if (n == 0) return null;
        if (n != null && n >= 1 && n <= items.length) return [n - 1];
        out('Enter a number from 0 to ${items.length}.');
      }
    }
  }
}
