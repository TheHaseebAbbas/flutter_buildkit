import 'keys.dart';

class SelectItem {
  const SelectItem(this.label, {this.hint, this.disabled = false});

  final String label;

  /// Dimmed text after the label.
  final String? hint;

  /// Shown but cannot be chosen or ticked (e.g. a protected build).
  final bool disabled;
}

enum SelectOutcome { none, submit, cancel }

/// State and key handling of an arrow-key list, single or multi select.
/// Pure and terminal-free, so it can be unit tested.
///
/// Keys: Up/Down (or k/j), PgUp/PgDn, Home/End move; Space ticks (multi) or
/// picks (single); Enter confirms; `a` ticks all, `n` none, `i` inverts
/// (multi); `/` filters by typing; Esc or `q` cancels.
class SelectModel {
  SelectModel(this.items, {this.multi = false, int? initial, Set<int>? ticked})
      : selected = {...?ticked} {
    final start = initial ?? 0;
    cursor = start.clamp(0, items.isEmpty ? 0 : items.length - 1);
    if (items.isNotEmpty && items[cursor].disabled) _step(1);
  }

  final List<SelectItem> items;
  final bool multi;

  /// Index into [items] of the highlighted row.
  late int cursor;

  /// Ticked indexes into [items] (multi select).
  final Set<int> selected;

  String filter = '';
  bool filtering = false;

  /// Indexes of [items] that match the filter.
  List<int> get visible => [
        for (var i = 0; i < items.length; i++)
          if (filter.isEmpty ||
              items[i].label.toLowerCase().contains(filter.toLowerCase()))
            i,
      ];

  List<int> get _enabledVisible => [
        for (final i in visible)
          if (!items[i].disabled) i
      ];

  /// Sorted ticked indexes.
  List<int> get result => selected.toList()..sort();

  SelectOutcome handle(KeyPress k) {
    if (filtering) return _handleFilter(k);
    switch (k.key) {
      case Key.up:
        _step(-1);
      case Key.down:
        _step(1);
      case Key.pageUp:
        _step(-8);
      case Key.pageDown:
        _step(8);
      case Key.home:
        _jump(first: true);
      case Key.end:
        _jump(first: false);
      case Key.escape:
        return SelectOutcome.cancel;
      case Key.enter:
        if (multi) return SelectOutcome.submit;
        if (_canPick(cursor)) {
          selected
            ..clear()
            ..add(cursor);
          return SelectOutcome.submit;
        }
      case Key.space:
        if (!multi) {
          if (_canPick(cursor)) {
            selected
              ..clear()
              ..add(cursor);
            return SelectOutcome.submit;
          }
        } else if (_canPick(cursor)) {
          if (!selected.remove(cursor)) selected.add(cursor);
        }
      case Key.char:
        return _handleChar(k.char);
      default:
        break;
    }
    return SelectOutcome.none;
  }

  SelectOutcome _handleChar(String c) {
    switch (c) {
      case 'k':
        _step(-1);
      case 'j':
        _step(1);
      case 'q':
        return SelectOutcome.cancel;
      case '/':
        filtering = true;
      case 'a' when multi:
        selected.addAll(_enabledVisible);
      case 'n' when multi:
        selected.removeAll(visible);
      case 'i' when multi:
        for (final i in _enabledVisible) {
          if (!selected.remove(i)) selected.add(i);
        }
      default:
        // 1-9 jump to that row; in single mode they also pick it.
        final n = int.tryParse(c);
        if (n != null && n >= 1 && n <= visible.length) {
          cursor = visible[n - 1];
          if (!multi && _canPick(cursor)) {
            selected
              ..clear()
              ..add(cursor);
            return SelectOutcome.submit;
          }
        }
    }
    return SelectOutcome.none;
  }

  SelectOutcome _handleFilter(KeyPress k) {
    switch (k.key) {
      case Key.escape:
        filter = '';
        filtering = false;
      case Key.enter:
        filtering = false;
      case Key.backspace:
        if (filter.isEmpty) {
          filtering = false;
        } else {
          filter = filter.substring(0, filter.length - 1);
        }
      case Key.ctrlU:
        filter = '';
      case Key.space:
        filter += ' ';
      case Key.char:
        filter += k.char;
      case Key.up:
        _step(-1);
      case Key.down:
        _step(1);
      default:
        break;
    }
    _keepCursorVisible();
    return SelectOutcome.none;
  }

  bool _canPick(int index) => visible.contains(index) && !items[index].disabled;

  void _keepCursorVisible() {
    final v = visible;
    if (v.isNotEmpty && !v.contains(cursor)) cursor = v.first;
  }

  /// Moves [delta] rows through the visible, enabled rows, clamping at the
  /// ends.
  void _step(int delta) {
    final v = visible;
    if (v.isEmpty) return;
    var pos = v.indexOf(cursor);
    if (pos < 0) pos = 0;
    final dir = delta < 0 ? -1 : 1;
    var remaining = delta.abs();
    var best = pos;
    var i = pos;
    while (remaining > 0) {
      i += dir;
      if (i < 0 || i >= v.length) break;
      if (items[v[i]].disabled) continue;
      best = i;
      remaining--;
    }
    if (items[v[best]].disabled) return;
    cursor = v[best];
  }

  void _jump({required bool first}) {
    final e = _enabledVisible;
    if (e.isNotEmpty) cursor = first ? e.first : e.last;
  }
}

/// Renders [model] as lines of text. [maxRows] limits how many items show
/// at once; the list scrolls to keep the cursor in view.
List<String> renderSelect(
  String title,
  SelectModel m, {
  int maxRows = 12,
  bool color = true,
}) {
  String dim(String s) => color ? '\x1b[2m$s\x1b[0m' : s;
  String bold(String s) => color ? '\x1b[1m$s\x1b[0m' : s;
  String cyan(String s) => color ? '\x1b[36m$s\x1b[0m' : s;

  final v = m.visible;
  final lines = <String>[bold(title)];
  if (m.filtering || m.filter.isNotEmpty) {
    lines.add('  Filter: ${m.filter}${m.filtering ? '_' : ''}');
  }
  if (v.isEmpty) {
    lines.add(dim('  (nothing matches)'));
  } else {
    final cursorPos = v.indexOf(m.cursor).clamp(0, v.length - 1);
    var start = 0;
    if (v.length > maxRows) {
      start = (cursorPos - maxRows ~/ 2).clamp(0, v.length - maxRows);
    }
    final end = (start + maxRows).clamp(0, v.length);
    if (start > 0) lines.add(dim('  ... $start more above'));
    for (var p = start; p < end; p++) {
      final i = v[p];
      final item = m.items[i];
      final here = i == m.cursor;
      final box = m.multi
          ? (item.disabled
              ? '[-] '
              : (m.selected.contains(i) ? '[x] ' : '[ ] '))
          : '';
      var text = '${here ? '>' : ' '} $box${item.label}';
      if (item.hint != null) text += '  ${dim(item.hint!)}';
      if (item.disabled) {
        text = dim(text);
      } else if (here) {
        text = cyan(text);
      }
      lines.add(text);
    }
    if (end < v.length) lines.add(dim('  ... ${v.length - end} more below'));
  }
  final help = m.filtering
      ? 'type to filter, Enter keep, Esc clear'
      : m.multi
          ? 'Up/Down move, Space tick, a all, n none, i invert, / filter, '
              'Enter confirm (${m.selected.length} ticked), Esc cancel'
          : 'Up/Down move, Enter choose, / filter, Esc back';
  lines.add(dim('  $help'));
  return lines;
}
