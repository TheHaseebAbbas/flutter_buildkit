import 'dart:io';

/// Minimal prompt helpers. Input and output are injectable for tests.
class Console {
  Console({String? Function()? readLine, void Function(String)? write})
      : _readLine = readLine ?? stdin.readLineSync,
        _write = write ?? stdout.write;

  final String? Function() _readLine;
  final void Function(String) _write;

  void out(String text) => _write('$text\n');
  void blank() => _write('\n');
  void heading(String text) => _write('\n== $text ==\n');
  void raw(String text) => _write(text);

  /// Reads a line; null means the input stream ended (Ctrl-D).
  String? _read(String prompt) {
    _write(prompt);
    return _readLine();
  }

  /// Free text. Empty input returns [defaultValue]. Returns null on EOF.
  String? ask(String question, {String? defaultValue}) {
    final hint = defaultValue == null ? '' : ' [$defaultValue]';
    final line = _read('$question$hint: ');
    if (line == null) return null;
    final value = line.trim();
    return value.isEmpty ? defaultValue : value;
  }

  bool confirm(String question, {bool defaultValue = false}) {
    while (true) {
      final line = _read('$question [${defaultValue ? 'Y/n' : 'y/N'}]: ');
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

  /// Numbered menu; returns the chosen index, or null for back/EOF.
  /// "0" (or Enter with no default) goes back.
  int? choose(String title, List<String> options,
      {int? defaultIndex, String backLabel = 'Back'}) {
    while (true) {
      out('\n$title');
      for (var i = 0; i < options.length; i++) {
        out('  ${i + 1}) ${options[i]}');
      }
      out('  0) $backLabel');
      final hint = defaultIndex == null ? '' : ' [${defaultIndex + 1}]';
      final line = _read('Choose$hint: ');
      if (line == null) return null;
      final text = line.trim();
      if (text.isEmpty && defaultIndex != null) return defaultIndex;
      final n = int.tryParse(text);
      if (n == 0) return null;
      if (n != null && n >= 1 && n <= options.length) return n - 1;
      out('Enter a number from 0 to ${options.length}.');
    }
  }

  /// Comma/space separated numbers, or "a" for all. Returns indexes.
  List<int>? chooseMany(String title, List<String> options) {
    while (true) {
      out('\n$title');
      for (var i = 0; i < options.length; i++) {
        out('  ${i + 1}) ${options[i]}');
      }
      final line = _read('Numbers (e.g. 1,3), "a" for all, Enter to cancel: ');
      if (line == null || line.trim().isEmpty) return null;
      final text = line.trim().toLowerCase();
      if (text == 'a' || text == 'all') {
        return List.generate(options.length, (i) => i);
      }
      final picks = text.split(RegExp(r'[,\s]+')).map(int.tryParse).toList();
      if (picks.every((n) => n != null && n >= 1 && n <= options.length)) {
        return {for (final n in picks) n! - 1}.toList()..sort();
      }
      out('Enter numbers between 1 and ${options.length}.');
    }
  }

  /// Asks until the answer parses as an int.
  int? askInt(String question, {int? defaultValue}) {
    while (true) {
      final value = ask(question, defaultValue: defaultValue?.toString());
      if (value == null) return null;
      final n = int.tryParse(value);
      if (n != null) return n;
      out('Enter a whole number.');
    }
  }
}
