import 'dart:convert';

enum Key {
  up,
  down,
  left,
  right,
  home,
  end,
  pageUp,
  pageDown,
  enter,
  space,
  backspace,
  escape,
  ctrlC,
  ctrlU,
  char,
}

class KeyPress {
  const KeyPress(this.key, [this.char = '']);
  const KeyPress.char(String c) : this(Key.char, c);

  final Key key;

  /// The typed character when [key] is [Key.char].
  final String char;

  bool isChar(String c) => key == Key.char && char == c;

  @override
  String toString() => key == Key.char ? 'KeyPress($char)' : 'KeyPress($key)';

  @override
  bool operator ==(Object other) =>
      other is KeyPress && other.key == key && other.char == char;

  @override
  int get hashCode => Object.hash(key, char);
}

/// Parses the bytes of one terminal read into key presses. A terminal
/// delivers a whole escape sequence in one read, so a lone ESC byte is the
/// Escape key and `ESC [ A` is the up arrow.
List<KeyPress> parseKeys(List<int> bytes) {
  final keys = <KeyPress>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 27) {
      if (i + 1 >= bytes.length) {
        keys.add(const KeyPress(Key.escape));
        i++;
        continue;
      }
      final next = bytes[i + 1];
      if (next == 91 || next == 79) {
        // CSI (ESC [) or SS3 (ESC O): parameters then a final byte.
        var j = i + 2;
        final params = <int>[];
        while (j < bytes.length && bytes[j] >= 0x30 && bytes[j] <= 0x3F) {
          params.add(bytes[j]);
          j++;
        }
        final last = j < bytes.length ? bytes[j] : 0;
        final p = String.fromCharCodes(params);
        final key = switch ((String.fromCharCode(last), p)) {
          ('A', _) => Key.up,
          ('B', _) => Key.down,
          ('C', _) => Key.right,
          ('D', _) => Key.left,
          ('H', _) => Key.home,
          ('F', _) => Key.end,
          ('~', '1') || ('~', '7') => Key.home,
          ('~', '4') || ('~', '8') => Key.end,
          ('~', '5') => Key.pageUp,
          ('~', '6') => Key.pageDown,
          _ => null,
        };
        if (key != null) keys.add(KeyPress(key));
        i = j + 1;
        continue;
      }
      // Alt+key or an unknown sequence: treat as Escape and move on.
      keys.add(const KeyPress(Key.escape));
      i++;
      continue;
    }
    switch (b) {
      case 3:
        keys.add(const KeyPress(Key.ctrlC));
      case 21:
        keys.add(const KeyPress(Key.ctrlU));
      case 10 || 13:
        keys.add(const KeyPress(Key.enter));
        // CRLF arrives as two bytes; count it once.
        if (b == 13 && i + 1 < bytes.length && bytes[i + 1] == 10) i++;
      case 32:
        keys.add(const KeyPress(Key.space));
      case 8 || 127:
        keys.add(const KeyPress(Key.backspace));
      default:
        if (b >= 32) {
          // Decode one UTF-8 character.
          final len = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 1));
          final end = (i + len).clamp(0, bytes.length);
          final text = utf8.decode(bytes.sublist(i, end), allowMalformed: true);
          keys.add(KeyPress.char(text));
          i = end;
          continue;
        }
    }
    i++;
  }
  return keys;
}
