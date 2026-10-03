// The prompt toolkit behind the menu, without a terminal.
//
//   dart run example/cli_and_ui/scripted_console.dart
//
// Console takes `readLine` and `write` callbacks, so prompts can be answered
// from a list: handy for tests and for trying the plain (numbered) mode.
import 'package:flutter_buildkit/flutter_buildkit.dart';

import '../_support/demo.dart';

Future<void> main() async {
  title('Number lists: 1,3  1-3  1 3');
  print(parseNumberList('1,3'));
  print(parseNumberList('1-3'));
  print(parseNumberList('nonsense')); // null: not a list of numbers

  title('Scripted prompts (plain mode)');
  final answers = ['2', '1,3', 'my note', 'y'];
  final console = Console(
    mode: UiMode.plain,
    readLine: () => answers.isEmpty ? null : answers.removeAt(0),
    write: (text) => print(text.trimRight()),
  );
  final mode = await console.choose(
      'Build mode', ['debug', 'profile', 'release'],
      hints: ['fast', 'fast + profiling', 'store ready']);
  final flavors =
      await console.chooseMany('Flavors', ['dev', 'staging', 'prod']);
  final note = await console.ask('Note for the ledger', defaultValue: 'none');
  final go = await console.confirm('Start the build?', defaultValue: true);
  print('\nchose mode #$mode, flavors #$flavors, note "$note", go: $go');

  title('Styled output and tables');
  console
    ..heading('Summary')
    ..kv('Mode', 'profile')
    ..success('3 builds finished')
    ..warn('symbols not uploaded yet')
    ..note('press Ctrl-C to quit');
  print(renderTable([
    'Flavor',
    'Size'
  ], [
    ['dev', formatBytes(18 * 1024 * 1024)],
    ['prod', formatBytes(21500000)],
  ]));

  title('Colors honour NO_COLOR');
  final style = Style.detect(env: const {'NO_COLOR': '1'});
  print('enabled: ${style.enabled}');
}
