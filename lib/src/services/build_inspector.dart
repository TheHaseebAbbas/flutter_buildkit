import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../model/build_record.dart';
import 'process_runner.dart';

/// The GNU build id of an ELF file as lower case hex, or null when [file] is
/// not an ELF file with one.
///
/// Dart writes this id into each AOT snapshot and each `--split-debug-info`
/// symbols file; a crash report prints it as `build_id: '...'`.
String? readElfBuildId(File file) {
  try {
    return elfBuildId(file.readAsBytesSync());
  } on Object {
    return null;
  }
}

/// [readElfBuildId] for bytes already in memory.
String? elfBuildId(Uint8List bytes) {
  if (bytes.length < 64 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 || // E
      bytes[2] != 0x4c || // L
      bytes[3] != 0x46) {
    // F
    return null;
  }
  final is64 = bytes[4] == 2;
  final endian = bytes[5] == 2 ? Endian.big : Endian.little;
  final data = ByteData.sublistView(bytes);
  int u16(int o) => data.getUint16(o, endian);
  int u32(int o) => data.getUint32(o, endian);
  int word(int o) => is64 ? data.getUint64(o, endian) : u32(o);

  final shoff = word(is64 ? 0x28 : 0x20);
  final shentsize = u16(is64 ? 0x3a : 0x2e);
  final shnum = u16(is64 ? 0x3c : 0x30);
  for (var i = 0; i < shnum; i++) {
    final h = shoff + i * shentsize;
    if (h + shentsize > bytes.length) return null;
    if (u32(h + 4) != 7) continue; // SHT_NOTE
    var o = word(h + (is64 ? 0x18 : 0x10));
    final end = o + word(h + (is64 ? 0x20 : 0x14));
    while (o + 12 <= end && end <= bytes.length) {
      final nameSize = u32(o);
      final descSize = u32(o + 4);
      final type = u32(o + 8);
      final nameAt = o + 12;
      final descAt = nameAt + ((nameSize + 3) & ~3);
      if (descAt + descSize > bytes.length) break;
      final name = String.fromCharCodes(
          bytes.sublist(nameAt, nameAt + (nameSize > 0 ? nameSize - 1 : 0)));
      if (name == 'GNU' && type == 3) {
        return [
          for (final b in bytes.sublist(descAt, descAt + descSize))
            b.toRadixString(16).padLeft(2, '0'),
        ].join();
      }
      o = descAt + ((descSize + 3) & ~3);
    }
  }
  return null;
}

/// Build ids of the Dart symbols files in [dir] (`app.android-arm64.symbols`
/// and so on), by file name.
Map<String, String> dartBuildIds(Directory dir) {
  if (!dir.existsSync()) return const {};
  final out = <String, String>{};
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.symbols')) continue;
    final id = readElfBuildId(f);
    if (id != null) out[p.basename(f.path)] = id;
  }
  return out;
}

/// Reads the signing certificate of an APK or AAB with `apksigner` or
/// `keytool`. Both are optional: without them [inspect] returns null.
class SigningInspector {
  /// Creates an inspector that runs tools through [runner]. [env] is
  /// consulted for the Android SDK location.
  SigningInspector(this.runner, {Map<String, String>? env})
      : env = env ?? Platform.environment;

  /// Runs the tools.
  final ProcessRunner runner;

  /// Environment with `ANDROID_HOME` or `ANDROID_SDK_ROOT`.
  final Map<String, String> env;

  /// The certificate [file] is signed with, or null when it cannot be read.
  Future<BuildSigning?> inspect(File file) async {
    final isApk = file.path.toLowerCase().endsWith('.apk');
    if (isApk) {
      final apksigner = _apksigner();
      if (apksigner != null) {
        final out =
            await _run([apksigner, 'verify', '--print-certs', file.path]);
        final parsed = out == null ? null : parseApksigner(out);
        if (parsed != null) return parsed;
      }
    }
    final out = await _run(['keytool', '-printcert', '-jarfile', file.path]);
    return out == null ? null : parseKeytool(out);
  }

  Future<String?> _run(List<String> command) async {
    try {
      final r = await runner.run(command);
      if (r.exitCode != 0) return null;
      return '${r.stdout}\n${r.stderr}';
    } on Object {
      return null;
    }
  }

  /// The newest `apksigner` in the Android SDK's build-tools, else the one on
  /// the PATH, else null.
  String? _apksigner() {
    final sdk = env['ANDROID_HOME'] ?? env['ANDROID_SDK_ROOT'];
    final name = Platform.isWindows ? 'apksigner.bat' : 'apksigner';
    if (sdk != null) {
      final tools = Directory(p.join(sdk, 'build-tools'));
      if (tools.existsSync()) {
        final versions = tools.listSync().whereType<Directory>().toList()
          ..sort((a, b) =>
              _compareVersions(p.basename(b.path), p.basename(a.path)));
        for (final v in versions) {
          final candidate = p.join(v.path, name);
          if (File(candidate).existsSync()) return candidate;
        }
      }
    }
    return 'apksigner';
  }

  static int _compareVersions(String a, String b) {
    final x = a.split(RegExp(r'[.\-]')).map((s) => int.tryParse(s) ?? 0);
    final y = b.split(RegExp(r'[.\-]')).map((s) => int.tryParse(s) ?? 0);
    final xs = x.toList(), ys = y.toList();
    for (var i = 0; i < xs.length || i < ys.length; i++) {
      final d = (i < xs.length ? xs[i] : 0) - (i < ys.length ? ys[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  /// Reads `apksigner verify --print-certs` output.
  static BuildSigning? parseApksigner(String out) {
    final sha = RegExp(r'certificate SHA-256 digest:\s*([0-9a-fA-F:]+)')
        .firstMatch(out)
        ?.group(1);
    if (sha == null) return null;
    final dn = RegExp(r'certificate DN:\s*(.+)').firstMatch(out)?.group(1);
    return BuildSigning(
      sha256: _hex(sha),
      subject: dn?.trim(),
      debugKey: dn?.contains('Android Debug') ?? false,
      tool: 'apksigner',
    );
  }

  /// Reads `keytool -printcert -jarfile` output.
  static BuildSigning? parseKeytool(String out) {
    final sha =
        RegExp(r'SHA-?256:\s*([0-9a-fA-F:]+)').firstMatch(out)?.group(1);
    if (sha == null) return null;
    final owner = RegExp(r'Owner:\s*(.+)').firstMatch(out)?.group(1);
    return BuildSigning(
      sha256: _hex(sha),
      subject: owner?.trim(),
      debugKey: owner?.contains('Android Debug') ?? false,
      tool: 'keytool',
    );
  }

  static String _hex(String s) => s.replaceAll(':', '').toLowerCase();
}
