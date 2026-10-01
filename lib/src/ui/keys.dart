import 'dart:convert';

/// A key the terminal can report to a prompt.
enum Key {
  /// Up arrow.
  up,

  /// Down arrow.
  down,

  /// Left arrow.
  left,

  /// Right arrow.
  right,

  /// Home key.
  home,

  /// End key.
  end,

  /// Page Up key.
  pageUp,

  /// Page Down key.
  pageDown,

  /// Enter or Return (CR, LF or CRLF).
  enter,

  /// Space bar.
  space,

  /// Backspace or Delete.
  backspace,

  /// Escape key.
  escape,

  /// Ctrl-C.
  ctrlC,

  /// Ctrl-U, which clears a typed line.
  ctrlU,

  /// A printable character; see [KeyPress.char].
  char,
}

/// One key press: a [Key] plus, for [Key.char], the typed character.
class KeyPress {
  /// Creates a press of [key], with the typed [char] if any.
  const KeyPress(this.key, [this.char = '']);

  /// Creates a [Key.char] press for the character [c].
  const KeyPress.char(String c) : this(Key.char, c);

  /// Which key was pressed.
  final Key key;

  /// The typed character when [key] is [Key.char].
  final String char;

  /// Whether this is a printable-character press of exactly [c].
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

/// True when [bytes] ends in the middle of an escape sequence (a lone ESC, or
/// `ESC [` without its final byte). Terminals normally deliver a whole
/// sequence at once, but over a slow link the rest can arrive in a later
/// read, so the caller should wait briefly for more bytes before deciding.
bool endsInIncompleteSequence(List<int> bytes) {
  final i = bytes.lastIndexOf(27);
  if (i < 0) return false;
  final tail = bytes.sublist(i);
  if (tail.length == 1) return true;
  if (tail[1] != 91 && tail[1] != 79) return false;
  if (tail.length == 2) return true;
  // CSI parameters (digits and ;) without the final letter.
  return tail.skip(2).every((b) => b >= 0x30 && b <= 0x3F);
}
