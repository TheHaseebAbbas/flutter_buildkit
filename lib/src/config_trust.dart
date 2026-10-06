import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// Remembers which project configs the user agreed to run.
///
/// A cloned repo's `flutter_buildkit.yaml` can name the executables the tool
/// launches (`flutter`, `sentry.cli`, ...), like a Makefile. The first time a
/// config names any, the front ends show them and ask; the answer is stored
/// per project and per set of commands, so a changed command asks again.
class ConfigTrust {
  /// Uses [file] as the store; defaults to `~/.flutter_buildkit/trusted.json`.
  ConfigTrust({File? file}) : file = file ?? _defaultFile();

  /// The JSON file holding `{projectDir: [hash, ...]}`.
  final File file;

  static File _defaultFile() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
    return File(p.join(home, '.flutter_buildkit', 'trusted.json'));
  }

  /// Stable hash of the commands [config] takes from the shared file.
  static String hashOf(AppConfig config) {
    final keys = config.sharedCommands.keys.toList()..sort();
    final text =
        [for (final k in keys) '$k=${config.sharedCommands[k]}'].join('\n');
    return sha256.convert(utf8.encode(text)).toString();
  }

  /// True when [config] runs no shared-file commands, or the user approved
  /// exactly these.
  bool isTrusted(AppConfig config) {
    if (config.sharedCommands.isEmpty) return true;
    return _read()[_key(config)]?.contains(hashOf(config)) ?? false;
  }

  /// Records approval of [config]'s current commands.
  void trust(AppConfig config) {
    final all = _read();
    final hashes = all[_key(config)] ?? [];
    if (!hashes.contains(hashOf(config))) hashes.add(hashOf(config));
    all[_key(config)] = hashes;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(all));
  }

  /// The commands as `key = command` lines for the prompt.
  static List<String> describe(AppConfig config) => [
        for (final e in config.sharedCommands.entries) '${e.key} = ${e.value}',
      ];

  String _key(AppConfig config) => p.normalize(p.absolute(config.projectDir));

  Map<String, List<String>> _read() {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      return {
        for (final e in json.entries)
          '${e.key}': [for (final h in e.value as List) '$h'],
      };
    } on Object {
      return {};
    }
  }
}
