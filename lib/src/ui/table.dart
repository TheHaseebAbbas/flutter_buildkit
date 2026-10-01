import 'style.dart';

/// Renders [rows] as an aligned table. Cells are padded on their plain text
/// first, then [decorate] may color them, so ANSI codes never break the
/// alignment.
String renderTable(
  List<String> header,
  List<List<String>> rows, {
  Style style = Style.plain,
  String Function(int column, String paddedCell)? decorate,
}) {
  final widths = [
    for (var c = 0; c < header.length; c++)
      [header[c], ...rows.map((r) => r[c])]
          .map((s) => s.length)
          .reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells, {bool head = false}) {
    final parts = [
      for (var c = 0; c < cells.length; c++)
        () {
          final padded = cells[c].padRight(widths[c]);
          if (head) return style.bold(padded);
          return decorate == null ? padded : decorate(c, padded);
        }(),
    ];
    return parts.join('  ').trimRight();
  }

  return [
    line(header, head: true),
    style.dim([for (final w in widths) style.rule * w].join('  ')),
    ...rows.map(line),
  ].join('\n');
}

/// Formats [bytes] as a human-readable size such as `1.5 MB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
