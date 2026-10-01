import 'dart:convert';

/// Character classes of a JSONC text: which characters are code (outside
/// strings and comments) and which are inside comments.
class JsoncScan {
  JsoncScan(this.text)
      : code = List.filled(text.length, false),
        comment = List.filled(text.length, false) {
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '"') {
        i++;
        while (i < text.length && text[i] != '"') {
          i += text[i] == r'\' ? 2 : 1;
        }
        i++; // closing quote
      } else if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
        while (i < text.length && text[i] != '\n') {
          comment[i++] = true;
        }
      } else if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
        final end = text.indexOf('*/', i + 2);
        final stop = end < 0 ? text.length : end + 2;
        while (i < stop) {
          comment[i++] = true;
        }
      } else {
        if (c.trim().isNotEmpty) code[i] = true;
        i++;
      }
    }
  }

  final String text;

  /// True for structural characters (`{ } [ ] , :` and bare values) outside
  /// strings and comments.
  final List<bool> code;
  final List<bool> comment;

  /// Index of the last character that is neither whitespace nor part of a
  /// comment in `[from, to)`, or -1.
  int lastSignificant(int from, int to) {
    for (var i = to - 1; i >= from; i--) {
      if (!comment[i] && text[i].trim().isNotEmpty) return i;
    }
    return -1;
  }
}

/// Removes comments and trailing commas so the text is plain JSON.
String stripJsonc(String text) {
  final scan = JsoncScan(text);
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (scan.comment[i]) continue;
    out.write(text[i]);
  }
  // Trailing commas: a comma outside strings followed only by whitespace and
  // a closing bracket.
  final plain = out.toString();
  final clean = JsoncScan(plain);
  final result = StringBuffer();
  for (var i = 0; i < plain.length; i++) {
    if (plain[i] == ',' && clean.code[i]) {
      var j = i + 1;
      while (j < plain.length && plain[j].trim().isEmpty) {
        j++;
      }
      if (j < plain.length && (plain[j] == '}' || plain[j] == ']')) continue;
    }
    result.write(plain[i]);
  }
  return result.toString();
}

/// Decodes JSONC, throwing [FormatException] when it is not valid.
Object? decodeJsonc(String text) => jsonDecode(stripJsonc(text));

/// Where the array under the top level [key] starts and ends:
/// `(open, close)` are the indexes of `[` and `]`. Null when there is none.
(int, int)? findArray(String text, String key) {
  final scan = JsoncScan(text);
  final needle = '"$key"';
  var from = 0;
  while (true) {
    final at = text.indexOf(needle, from);
    if (at < 0) return null;
    from = at + needle.length;
    // The key must be a string token, not text inside a comment.
    if (scan.comment[at]) continue;
    var i = from;
    while (i < text.length && (text[i].trim().isEmpty || scan.comment[i])) {
      i++;
    }
    if (i >= text.length || text[i] != ':') continue;
    i++;
    while (i < text.length && (text[i].trim().isEmpty || scan.comment[i])) {
      i++;
    }
    if (i >= text.length || text[i] != '[') continue;
    var depth = 0;
    for (var j = i; j < text.length; j++) {
      if (!scan.code[j]) continue;
      if (text[j] == '[' || text[j] == '{') depth++;
      if (text[j] == ']' || text[j] == '}') {
        depth--;
        if (depth == 0) return (i, j);
      }
    }
    return null;
  }
}
