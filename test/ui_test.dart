import 'dart:io';
import 'package:flutter_buildkit/flutter_buildkit.dart';
import 'package:flutter_buildkit/src/ui/windows_console.dart';
import 'package:test/test.dart';

List<int> b(String s) => s.codeUnits;

void main() {
  windowsTests();
  group('parseKeys', () {
    test('arrows, CSI and SS3', () {
      expect(parseKeys([27, 91, 65]), [const KeyPress(Key.up)]);
      expect(parseKeys([27, 91, 66]), [const KeyPress(Key.down)]);
      expect(parseKeys([27, 79, 67]), [const KeyPress(Key.right)]);
      expect(parseKeys([27, 91, 68]), [const KeyPress(Key.left)]);
    });

    test('home/end/page keys', () {
      expect(parseKeys([27, 91, 72]), [const KeyPress(Key.home)]);
      expect(parseKeys([27, 91, 70]), [const KeyPress(Key.end)]);
      expect(parseKeys([27, 91, 53, 126]), [const KeyPress(Key.pageUp)]);
      expect(parseKeys([27, 91, 54, 126]), [const KeyPress(Key.pageDown)]);
    });

    test('lone ESC is Escape; Enter, Space, Backspace, Ctrl-C', () {
      expect(parseKeys([27]), [const KeyPress(Key.escape)]);
      expect(parseKeys([13]), [const KeyPress(Key.enter)]);
      expect(parseKeys([13, 10]), [const KeyPress(Key.enter)]);
      expect(parseKeys([32]), [const KeyPress(Key.space)]);
      expect(parseKeys([127]), [const KeyPress(Key.backspace)]);
      expect(parseKeys([3]), [const KeyPress(Key.ctrlC)]);
    });

    test('typed and pasted text, including UTF-8', () {
      expect(parseKeys(b('ab')),
          [const KeyPress.char('a'), const KeyPress.char('b')]);
      expect(parseKeys('é'.codeUnits.length == 1 ? [0xC3, 0xA9] : [0xC3, 0xA9]),
          [const KeyPress.char('é')]);
    });
  });

  group('SelectModel (multi)', () {
    SelectModel model({Set<int>? ticked, List<SelectItem>? items}) =>
        SelectModel(
          items ??
              const [
                SelectItem('dev'),
                SelectItem('staging'),
                SelectItem('prod'),
              ],
          multi: true,
          ticked: ticked,
        );

    test('arrows move, space toggles', () {
      final m = model();
      m.handle(const KeyPress(Key.down));
      m.handle(const KeyPress(Key.space));
      expect(m.result, [1]);
      m.handle(const KeyPress(Key.space));
      expect(m.result, isEmpty);
    });

    test('movement clamps at the ends', () {
      final m = model();
      m.handle(const KeyPress(Key.up));
      expect(m.cursor, 0);
      for (var i = 0; i < 5; i++) {
        m.handle(const KeyPress(Key.down));
      }
      expect(m.cursor, 2);
    });

    test('a ticks all, n none, i inverts', () {
      final m = model(ticked: {0});
      m.handle(const KeyPress.char('a'));
      expect(m.result, [0, 1, 2]);
      m.handle(const KeyPress.char('n'));
      expect(m.result, isEmpty);
      m.handle(const KeyPress.char('i'));
      expect(m.result, [0, 1, 2]);
    });

    test('Enter submits, Esc cancels', () {
      final m = model();
      expect(m.handle(const KeyPress(Key.enter)), SelectOutcome.submit);
      expect(m.handle(const KeyPress(Key.escape)), SelectOutcome.cancel);
    });

    test('disabled rows are skipped and never ticked', () {
      final m = model(items: const [
        SelectItem('a', disabled: true),
        SelectItem('b'),
        SelectItem('c', disabled: true),
        SelectItem('d'),
      ]);
      expect(m.cursor, 1, reason: 'starts on the first enabled row');
      m.handle(const KeyPress(Key.down));
      expect(m.cursor, 3);
      m.handle(const KeyPress.char('a'));
      expect(m.result, [1, 3]);
      m.handle(const KeyPress(Key.home));
      expect(m.cursor, 1);
    });

    test('filter narrows rows and select-all only ticks visible ones', () {
      final m = model();
      m.handle(const KeyPress.char('/'));
      for (final c in 'pro'.split('')) {
        m.handle(KeyPress.char(c));
      }
      expect(m.visible, [2]);
      expect(m.cursor, 2);
      m.handle(const KeyPress(Key.enter)); // keep filter, leave typing mode
      m.handle(const KeyPress.char('a'));
      expect(m.result, [2]);
      m.handle(const KeyPress.char('/'));
      m.handle(const KeyPress(Key.escape)); // clears the filter
      expect(m.visible, [0, 1, 2]);
    });

    test('typed letters while filtering do not trigger shortcuts', () {
      final m = model();
      m.handle(const KeyPress.char('/'));
      m.handle(const KeyPress.char('a'));
      m.handle(const KeyPress.char('q'));
      expect(m.filter, 'aq');
      expect(m.result, isEmpty);
    });
  });

  group('SelectModel (single)', () {
    test('Enter and Space pick the highlighted row', () {
      final m = SelectModel(const [SelectItem('a'), SelectItem('b')]);
      m.handle(const KeyPress(Key.down));
      expect(m.handle(const KeyPress(Key.enter)), SelectOutcome.submit);
      expect(m.result, [1]);
    });

    test('q cancels', () {
      expect(
          SelectModel(const [SelectItem('a')]).handle(const KeyPress.char('q')),
          SelectOutcome.cancel);
    });

    test('a typed number moves the cursor; Enter picks it', () {
      final m = SelectModel([for (var i = 0; i < 12; i++) SelectItem('r$i')]);
      m.handle(const KeyPress.char('1'));
      m.handle(const KeyPress.char('1'));
      expect(m.entry, '11');
      expect(m.cursor, 10);
      expect(m.handle(const KeyPress(Key.enter)), SelectOutcome.submit);
      expect(m.result, [10]);
    });

    test('a bad number shows an error and keeps the list open', () {
      final m = SelectModel(const [SelectItem('a'), SelectItem('b')]);
      m.handle(const KeyPress.char('9'));
      expect(m.handle(const KeyPress(Key.enter)), SelectOutcome.none);
      expect(m.error, contains('choose 1-2'));
      expect(m.entry, isEmpty);
    });

    test('a disabled row cannot be picked by number', () {
      final m = SelectModel(const [
        SelectItem('a', disabled: true),
        SelectItem('b'),
      ]);
      m.handle(const KeyPress.char('1'));
      expect(m.handle(const KeyPress(Key.enter)), SelectOutcome.none);
      expect(m.error, contains('not available'));
    });

    test('Esc clears typed digits before it cancels', () {
      final m = SelectModel(const [SelectItem('a'), SelectItem('b')]);
      m.handle(const KeyPress.char('2'));
      expect(m.handle(const KeyPress(Key.escape)), SelectOutcome.none);
      expect(m.entry, isEmpty);
      expect(m.handle(const KeyPress(Key.escape)), SelectOutcome.cancel);
    });
  });

  group('SelectModel typed numbers (multi)', () {
    SelectModel m() =>
        SelectModel([for (var i = 0; i < 6; i++) SelectItem('r$i')],
            multi: true, ticked: {5});

    SelectOutcome type(SelectModel model, String text) {
      for (final c in text.split('')) {
        model.handle(c == ' ' ? const KeyPress(Key.space) : KeyPress.char(c));
      }
      return model.handle(const KeyPress(Key.enter));
    }

    test('1,3 selects rows 1 and 3 and replaces earlier ticks', () {
      final model = m();
      expect(type(model, '1,3'), SelectOutcome.submit);
      expect(model.result, [0, 2]);
    });

    test('1-3 is a range', () {
      final model = m();
      type(model, '1-3');
      expect(model.result, [0, 1, 2]);
    });

    test('Space between numbers works as a separator', () {
      final model = m();
      type(model, '2 4');
      expect(model.result, [1, 3]);
    });

    test('an out-of-range number is rejected', () {
      final model = m();
      expect(type(model, '1,9'), SelectOutcome.none);
      expect(model.error, isNotNull);
      expect(model.result, [5], reason: 'ticks are untouched on error');
    });

    test('Backspace edits the typed numbers', () {
      final model = m();
      model.handle(const KeyPress.char('1'));
      model.handle(const KeyPress.char('2'));
      model.handle(const KeyPress(Key.backspace));
      expect(model.entry, '1');
    });
  });

  test('parseNumberList', () {
    expect(parseNumberList('1,3'), [1, 3]);
    expect(parseNumberList('1-3'), [1, 2, 3]);
    expect(parseNumberList(' 2  4 '), [2, 4]);
    expect(parseNumberList('3-1'), isNull);
    expect(parseNumberList('x'), isNull);
    expect(parseNumberList(''), isNull);
  });

  test('endsInIncompleteSequence waits for split arrow keys', () {
    expect(endsInIncompleteSequence([27]), isTrue);
    expect(endsInIncompleteSequence([27, 91]), isTrue);
    expect(endsInIncompleteSequence([27, 91, 49, 59]), isTrue);
    expect(endsInIncompleteSequence([27, 91, 65]), isFalse);
    expect(endsInIncompleteSequence([97]), isFalse);
    expect(endsInIncompleteSequence([97, 27]), isTrue);
    // The pieces parse as an arrow once joined.
    expect(parseKeys([27, 91, 65]), [const KeyPress(Key.up)]);
  });

  test('renderSelect shows boxes, cursor and a scroll window', () {
    final m = SelectModel(
      [for (var i = 0; i < 30; i++) SelectItem('row $i')],
      multi: true,
      ticked: {0},
    );
    for (var i = 0; i < 15; i++) {
      m.handle(const KeyPress(Key.down));
    }
    final lines = renderSelect('Pick', m, maxRows: 5, style: Style.plain);
    expect(lines.first, 'Pick');
    expect(
        lines.any((l) => RegExp(r'^> +16 +\[ \] row 15').hasMatch(l)), isTrue);
    expect(lines.any((l) => l.contains('more above')), isTrue);
    expect(lines.any((l) => l.contains('more below')), isTrue);
    expect(lines.length, lessThanOrEqualTo(5 + 4));
  });

  group('list windowing', () {
    test('a list that fits shows every item and no indicator', () {
      expect(selectWindow(10, 4, 10), (0, 10));
      expect(selectWindow(3, 0, 12), (0, 3));
      final m = SelectModel([for (var i = 0; i < 10; i++) SelectItem('r$i')]);
      final lines = renderSelect('Menu', m, maxRows: 10);
      expect(lines.any((l) => l.contains('more')), isFalse);
      expect(lines.where((l) => l.contains(' r')).length, 10);
    });

    test('indicators take part of the budget and only when needed', () {
      // At the top only "below" is needed, so budget-1 items show.
      expect(selectWindow(14, 0, 8), (0, 7));
      // At the bottom only "above".
      expect(selectWindow(14, 13, 8), (7, 14));
      // In the middle both, so budget-2 items.
      final (s, e) = selectWindow(30, 15, 8);
      expect(e - s, 6);
      expect(s <= 15 && 15 < e, isTrue);
    });

    test('rendered list never exceeds its row budget and keeps the cursor', () {
      for (final total in [5, 8, 9, 14, 40]) {
        for (final budget in [3, 4, 7, 8, 20]) {
          final m = SelectModel(
              [for (var i = 0; i < total; i++) SelectItem('item $i')]);
          for (var step = 0; step < total; step++) {
            final lines = renderSelect('T', m, maxRows: budget);
            final list = lines.length - 2; // title and help
            expect(list, lessThanOrEqualTo(budget < 3 ? 3 : budget));
            expect(lines.any((l) => l.contains('> ')), isTrue,
                reason: 'cursor visible: total $total budget $budget');
            m.handle(const KeyPress(Key.down));
          }
        }
      }
    });

    test('selectListRows uses the terminal height', () {
      final m = SelectModel([for (var i = 0; i < 12; i++) SelectItem('x$i')]);
      // title + help + cursor row are reserved.
      expect(selectListRows(40, m), 37);
      expect(selectListRows(24, m), 21);
      expect(selectListRows(6, m), 3);
      expect(selectListRows(2, m), 3);
      m.handle(const KeyPress(Key.char, '/'));
      expect(selectListRows(40, m), 36, reason: 'filter line reserved');
    });

    test('a 12 item menu fits a 24 row terminal without indicators', () {
      final m = SelectModel([for (var i = 0; i < 12; i++) SelectItem('x$i')]);
      final lines =
          renderSelect('Main menu', m, maxRows: selectListRows(24, m));
      expect(lines.any((l) => l.contains('more')), isFalse);
      expect(lines.length, lessThan(24));
    });
  });

  test('renderSelect with a width never produces a line that could wrap', () {
    final m = SelectModel(
      [for (var i = 0; i < 6; i++) SelectItem('row $i', hint: 'h' * 100)],
      multi: true,
    );
    final lines = renderSelect('Flavors to build', m, width: 60);
    final help = renderSelect('Flavors to build', m).last;
    expect(help.length, greaterThan(60), reason: 'help text is long');
    expect(lines.length, renderSelect('Flavors to build', m).length);
    for (final l in lines) {
      expect(l.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '').length,
          lessThanOrEqualTo(60));
    }
  });

  test('fitLine keeps escapes, cuts visible text, resets colour', () {
    const red = '\x1b[31m';
    expect(fitLine('abcdef', 4), 'abcd');
    expect(fitLine('abc', 10), 'abc');
    expect(fitLine('${red}abcdef\x1b[0m', 3), '${red}abc\x1b[0m');
    expect(fitLine('abc', 0), '');
  });

  group('Console plain fallback (no terminal)', () {
    Console feed(List<String?> lines, List<String> out) {
      final it = lines.iterator;
      return Console(
        readLine: () => it.moveNext() ? it.current : null,
        write: out.add,
      );
    }

    test('choose returns the index; 0 goes back', () async {
      final out = <String>[];
      expect(await feed(['2'], out).choose('T', ['a', 'b']), 1);
      expect(await feed(['0'], out).choose('T', ['a', 'b']), isNull);
    });

    test('chooseMany: numbers, all, none and cancel', () async {
      final out = <String>[];
      expect(await feed(['1,3'], out).chooseMany('T', ['a', 'b', 'c']), [0, 2]);
      expect(await feed(['a'], out).chooseMany('T', ['a', 'b']), [0, 1]);
      expect(await feed(['none'], out).chooseMany('T', ['a', 'b']), isEmpty);
      expect(await feed([''], out).chooseMany('T', ['a', 'b']), isNull);
    });

    test('chooseMany accepts ranges and mixed lists', () async {
      final out = <String>[];
      expect(await feed(['1-3'], out).chooseMany('T', ['a', 'b', 'c', 'd']),
          [0, 1, 2]);
      expect(await feed(['4, 2'], out).chooseMany('T', ['a', 'b', 'c', 'd']),
          [1, 3]);
    });

    test('chooseMany Enter keeps pre-ticked rows', () async {
      final out = <String>[];
      expect(
          await feed([''], out).chooseMany('T', ['a', 'b'], ticked: {1}), [1]);
    });

    test('options can be typed by name instead of number', () async {
      final out = <String>[];
      expect(
          await feed(['staging'], out).choose('T', ['dev', 'staging', 'prod']),
          1);
      expect(
          await feed(['pr'], out).choose('T', ['dev', 'staging', 'prod']), 2);
      expect(
          await feed(['dev, prod'], out)
              .chooseMany('T', ['dev', 'staging', 'prod']),
          [0, 2]);
    });

    test('a bad answer asks again', () async {
      final out = <String>[];
      expect(await feed(['9', 'x', '2'], out).choose('T', ['a', 'b']), 1);
      expect(out.join(), contains('Type a number'));
    });

    test('chooseMany skips disabled rows for "all"', () async {
      final out = <String>[];
      expect(
          await feed(['a'], out)
              .chooseMany('T', ['a', 'b', 'c'], disabled: {1}),
          [0, 2]);
    });

    test('ask uses the default on empty input; askInt retries', () async {
      final out = <String>[];
      expect(await feed([''], out).ask('Q', defaultValue: 'x'), 'x');
      expect(await feed(['x', '7'], out).askInt('N'), 7);
    });

    test('confirm retries on junk', () async {
      final out = <String>[];
      expect(await feed(['maybe', 'y'], out).confirm('OK?'), isTrue);
      expect(await feed([''], out).confirm('OK?', defaultValue: true), isTrue);
    });

    test('readLines stops at the end marker', () async {
      final out = <String>[];
      final c = feed(['#00 a', '#01 b', '.', 'ignored'], out);
      expect(await c.readLines('paste'), '#00 a\n#01 b');
    });
  });
}

void windowsTests() {
  test('WindowsConsole is a harmless no-op away from a Windows console', () {
    final w = WindowsConsole.enable();
    if (!Platform.isWindows) expect(w.ready, isFalse);
    w.restore(); // must not throw
  });

  test('plain Style has no escape codes and ASCII glyphs', () {
    const s = Style.plain;
    expect(s.bold('x'), 'x');
    expect(s.ok('done'), '+ done');
    expect(s.err('bad'), 'x bad');
    expect(s.pointer, '>');
  });

  test('colored Style wraps text and uses unicode glyphs', () {
    const s = Style(true);
    expect(s.green('x'), '\x1b[32mx\x1b[0m');
    expect(s.ok('done'), contains('✔'));
  });
}
