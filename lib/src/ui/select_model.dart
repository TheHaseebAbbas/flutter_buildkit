import 'keys.dart';
import 'style.dart';

/// Parses `1,3`, `1-3` or `1 3` into the numbers they name (1-based), or null
/// when the text is not a number list.
List<int>? parseNumberList(String text) {
  final out = <int>[];
  for (final part in text.trim().split(RegExp(r'[,\s]+'))) {
    if (part.isEmpty) continue;
    final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(part);
    if (range != null) {
      final a = int.parse(range.group(1)!);
      final b = int.parse(range.group(2)!);
      if (a > b || b - a > 1000) return null;
      out.addAll([for (var n = a; n <= b; n++) n]);
    } else {
      final n = int.tryParse(part);
      if (n == null) return null;
      out.add(n);
    }
  }
  return out.isEmpty ? null : out;
}

/// One row of a selection list.
class SelectItem {
  /// Creates a row with [label], an optional dimmed [hint], and whether it is [disabled].
  const SelectItem(this.label, {this.hint, this.disabled = false});

  /// The text shown for the row.
  final String label;

  /// Dimmed text after the label.
  final String? hint;

  /// Shown but cannot be chosen or ticked (e.g. a build with nothing left
  /// to delete).
  final bool disabled;
}

/// What a key press did to a [SelectModel].
enum SelectOutcome {
  /// Keep going; nothing was decided.
  none,

  /// The user confirmed their choice.
  submit,

  /// The user backed out.
  cancel
}

/// State and key handling of an arrow-key list, single or multi select.
/// Pure and terminal-free, so it can be unit tested.
///
/// Keys: Up/Down (or k/j), PgUp/PgDn, Home/End move; Space ticks (multi) or
/// picks (single); Enter confirms; `a` ticks all, `n` none, `i` inverts
/// (multi); `/` filters by typing; Esc or `q` cancels.
///
/// Numbers always work too: type `2` (or `1,3` / `1-3` / `1 3` for several)
/// and press Enter. The numbers are the ones shown next to the rows.
class SelectModel {
  /// Creates a model over [items].
  ///
  /// [multi] allows ticking several rows. [initial] is the starting cursor row
  /// and [ticked] the rows ticked at the start.
  SelectModel(this.items, {this.multi = false, int? initial, Set<int>? ticked})
      : selected = {...?ticked} {
    final start = initial ?? 0;
    cursor = start.clamp(0, items.isEmpty ? 0 : items.length - 1);
    if (items.isNotEmpty && items[cursor].disabled) _step(1);
  }

  /// The rows of the list.
  final List<SelectItem> items;

  /// Whether several rows can be ticked (otherwise one is chosen).
  final bool multi;

  /// Index into [items] of the highlighted row.
  late int cursor;

  /// Ticked indexes into [items] (multi select).
  final Set<int> selected;

  /// The text typed after `/` to narrow the list.
  String filter = '';

  /// True while the user is typing a filter.
  bool filtering = false;

  /// Digits typed so far (`1,3`), applied on Enter.
  String entry = '';

  /// Why the last typed numbers were rejected.
  String? error;

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

  /// Applies one key press and reports whether the list is done.
  SelectOutcome handle(KeyPress k) {
    error = null;
    if (filtering) return _handleFilter(k);
    switch (k.key) {
      case Key.up:
        entry = '';
        _step(-1);
      case Key.down:
        entry = '';
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
        if (entry.isNotEmpty) {
          entry = '';
          return SelectOutcome.none;
        }
        return SelectOutcome.cancel;
      case Key.backspace:
        if (entry.isNotEmpty) entry = entry.substring(0, entry.length - 1);
      case Key.enter:
        if (entry.isNotEmpty) return _applyEntry();
        if (multi) return SelectOutcome.submit;
        if (_canPick(cursor)) {
          selected
            ..clear()
            ..add(cursor);
          return SelectOutcome.submit;
        }
      case Key.space:
        if (entry.isNotEmpty) {
          entry += ',';
        } else if (!multi) {
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
    // Digits start or extend a typed number list.
    if (RegExp(r'^[0-9]$').hasMatch(c) ||
        (entry.isNotEmpty && (c == ',' || c == '-'))) {
      entry += c;
      if (!multi) _previewEntry();
      return SelectOutcome.none;
    }
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
    }
    return SelectOutcome.none;
  }

  /// In single select, typing a number moves the cursor to that row.
  void _previewEntry() {
    final n = int.tryParse(entry);
    final v = visible;
    if (n != null && n >= 1 && n <= v.length) cursor = v[n - 1];
  }

  SelectOutcome _applyEntry() {
    final text = entry;
    entry = '';
    final numbers = parseNumberList(text);
    final v = visible;
    if (numbers == null) {
      error = 'Not a valid number list: $text';
      return SelectOutcome.none;
    }
    final bad = numbers.where((n) => n < 1 || n > v.length).toList();
    if (bad.isNotEmpty) {
      error = 'No row ${bad.first}; choose 1-${v.length}';
      return SelectOutcome.none;
    }
    final picked = [for (final n in numbers) v[n - 1]];
    final disabled = picked.where((i) => items[i].disabled).toList();
    if (disabled.isNotEmpty) {
      error = 'Row ${v.indexOf(disabled.first) + 1} is not available';
      return SelectOutcome.none;
    }
    if (!multi) {
      cursor = picked.first;
      selected
        ..clear()
        ..add(cursor);
      return SelectOutcome.submit;
    }
    selected
      ..clear()
      ..addAll(picked);
    return SelectOutcome.submit;
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
  Style style = Style.plain,
}) {
  final v = m.visible;
  final width = '${v.length}'.length;
  final lines = <String>[style.boldCyan(title)];
  if (m.filtering || m.filter.isNotEmpty) {
    lines.add('  ${style.dim('filter')} ${m.filter}${m.filtering ? '_' : ''}');
  }
  if (v.isEmpty) {
    lines.add(style.dim('  (nothing matches)'));
  } else {
    final cursorPos = v.indexOf(m.cursor).clamp(0, v.length - 1);
    var start = 0;
    if (v.length > maxRows) {
      start = (cursorPos - maxRows ~/ 2).clamp(0, v.length - maxRows);
    }
    final end = (start + maxRows).clamp(0, v.length);
    if (start > 0) lines.add(style.dim('    ... $start more above'));
    for (var p = start; p < end; p++) {
      final i = v[p];
      final item = m.items[i];
      final here = i == m.cursor;
      final num = '${p + 1}'.padLeft(width);
      final ticked = m.selected.contains(i);
      final box = m.multi
          ? (item.disabled
              ? style.dim('[-] ')
              : (ticked ? '${style.green('[x]')} ' : '[ ] '))
          : '';
      final pointer = here ? style.cyan(style.pointer) : ' ';
      var label = item.label;
      if (item.disabled) {
        label = style.dim(label);
      } else if (here) {
        label = style.bold(label);
      } else if (ticked) {
        label = style.green(label);
      }
      var text = '$pointer ${style.dim(num)}  $box$label';
      if (item.hint != null) text += '  ${style.dim(item.hint!)}';
      lines.add(text);
    }
    if (end < v.length) {
      lines.add(style.dim('    ... ${v.length - end} more below'));
    }
  }
  if (m.entry.isNotEmpty) {
    lines.add('  ${style.cyan('number')} ${m.entry}_');
  }
  if (m.error != null) lines.add('  ${style.red(m.error!)}');
  final help = m.filtering
      ? 'type to filter, Enter keep, Esc clear'
      : m.multi
          ? 'arrows move, Space tick, a all, n none, i invert, / filter; or '
              'type numbers (1,3 or 1-3) and Enter. Enter confirms '
              '(${m.selected.length} ticked), Esc cancels'
          : 'arrows move, Enter choose, / filter; or type a number and Enter. '
              'Esc goes back';
  lines.add(style.dim('  $help'));
  return lines;
}
