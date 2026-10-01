/// Renders [rows] as an aligned plain-text table.
String renderTable(List<String> header, List<List<String>> rows) {
  final widths = [
    for (var c = 0; c < header.length; c++)
      [header[c], ...rows.map((r) => r[c])]
          .map((s) => s.length)
          .reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
        for (var c = 0; c < cells.length; c++) cells[c].padRight(widths[c]),
      ].join('  ').trimRight();
  return [
    line(header),
    line([for (final w in widths) '-' * w]),
    ...rows.map(line),
  ].join('\n');
}

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
