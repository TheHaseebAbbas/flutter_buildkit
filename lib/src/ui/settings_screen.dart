import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../config_editor.dart';
import '../flutter_project.dart';
import '../settings.dart';
import 'console.dart';

/// Interactive editor for `flutter_buildkit.yaml`.
///
/// Every change is validated and previewed before it is applied to an
/// in-memory copy of the file (comments are kept). Nothing is written until
/// "Save", which creates the file from the documented template when the
/// project has none yet.
class SettingsScreen {
  SettingsScreen({
    required this.console,
    required this.project,
    this.configFile,
    Map<String, String>? env,
  }) : env = env ?? Platform.environment {
    final existing = configFile != null && File(configFile!).existsSync();
    original = existing
        ? ConfigEditor(File(configFile!).readAsStringSync())
        : ConfigEditor.template();
    editor = original;
  }

  final Console console;
  final FlutterProject project;

  /// The file to edit; null when the project has none (it is created).
  final String? configFile;
  final Map<String, String> env;

  late ConfigEditor original;
  late ConfigEditor editor;

  String get savePath =>
      configFile ?? p.join(project.dir, AppConfig.fileNames.first);

  bool get dirty => editor.text != original.text;

  AppConfig _build(ConfigEditor e) =>
      e.build(project.dir, env: env, configFile: savePath);

  PreviewContext get _context {
    final v = project.version;
    final flavors = project.flavors;
    return PreviewContext(
      appName: project.appName,
      versionName: v.name,
      versionCode: v.code,
      flavor: flavors.isEmpty ? null : flavors.first,
    );
  }

  /// Runs until the user saves (returns the saved path) or closes (null).
  Future<String?> run() async {
    console.heading('Settings');
    console.note(File(savePath).existsSync()
        ? 'Editing $savePath'
        : 'No config file '
            'yet; $savePath is created when you save.');
    console.note('Changes are previewed first and only written on "Save".');
    final defs = globalSettings();
    while (true) {
      AppConfig config;
      try {
        config = _build(editor);
      } on ConfigException catch (e) {
        console.error('$e');
        return null;
      }
      final options = [
        for (final d in defs) d.key,
        'Flavors',
        'Review changes',
        dirty ? 'Save and reload' : 'Save and reload (no changes)',
      ];
      final hints = [
        for (final d in defs)
          '${_changed(d) ? '* ' : ''}${d.current(config)}  ${d.summary}',
        'target, dart defines, package name, Firebase, Sentry per flavor',
        'what differs from the file on disk',
        savePath,
      ];
      final choice = await console.choose('Settings', options,
          hints: hints, backLabel: 'Close');
      if (choice == null) {
        if (!dirty ||
            console.inputEnded ||
            await console.confirm('Discard unsaved changes?')) {
          return null;
        }
        continue;
      }
      if (choice < defs.length) {
        await _edit(defs[choice]);
      } else if (choice == defs.length) {
        await _flavors();
      } else if (choice == defs.length + 1) {
        _review();
      } else {
        if (await _save()) return savePath;
      }
    }
  }

  bool _changed(SettingDef d) =>
      '${editor.raw(d.path)}' != '${original.raw(d.path)}';

  // ---- editing one setting --------------------------------------------------

  Future<void> _edit(SettingDef def) async {
    final ctx = _context;
    console
      ..heading(def.key)
      ..out(def.summary);
    final now = _build(editor);
    console.kv('Now', def.current(now), labelWidth: 8);
    for (final line in def.preview(now, ctx).skip(1)) {
      console.note('         $line');
    }
    if (def.hint != null) console.note(def.hint!);

    /// Applies [value] to a copy; null with an error message when invalid.
    ConfigEditor? tryValue(Object? value) {
      try {
        final next = editor.set(def.path, value);
        _build(next);
        return next;
      } on ConfigException catch (e) {
        console.error('$e');
        return null;
      }
    }

    String previewOf(Object? value) {
      try {
        final c = _build(editor.set(def.path, value));
        return def.preview(c, ctx).first;
      } on ConfigException catch (e) {
        return 'invalid: $e';
      }
    }

    ConfigEditor? next;
    switch (def.kind) {
      case SettingKind.boolean:
        final values = [true, false];
        final currentIndex = def.current(now) == 'true' ? 0 : 1;
        final pick = await console.choose(
          def.key,
          ['true', 'false', 'Remove from file (use the default)'],
          defaultIndex: currentIndex,
          hints: [
            previewOf(true),
            previewOf(false),
            previewOf(null),
          ],
        );
        if (pick == null) return;
        next = tryValue(pick < 2 ? values[pick] : null);
      case SettingKind.choice:
        final labels = [
          for (final c in def.choices) c.value,
          if (def.custom) 'Custom value...',
          'Remove from file (use the default)',
        ];
        final hints = [
          for (final c in def.choices)
            '${c.note == null ? '' : '${c.note}  =>  '}${previewOf(c.value)}',
          if (def.custom) 'type your own',
          previewOf(null),
        ];
        final pick = await console.choose(def.key, labels, hints: hints);
        if (pick == null) return;
        if (pick < def.choices.length) {
          next = tryValue(def.choices[pick].value);
        } else if (def.custom && pick == def.choices.length) {
          final text = await console.ask('Value for ${def.key}');
          if (text == null) return;
          next = tryValue(text);
        } else {
          next = tryValue(null);
        }
      case SettingKind.text || SettingKind.list:
        final isList = def.kind == SettingKind.list;
        final shown = def.current(now);
        final text = await console.ask(
          '${def.key} (- removes it)',
          defaultValue: shown.startsWith('(') ? null : shown,
        );
        if (text == null) return;
        final value = text == '-'
            ? null
            : isList
                ? text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
                : text;
        next = tryValue(value);
    }
    if (next == null) return;

    final draft = _build(next);
    console.out('');
    console.out(console.style.bold('Preview'));
    for (final line in def.preview(draft, ctx)) {
      console.out('  $line');
    }
    if (def.kind == SettingKind.text || def.kind == SettingKind.list) {
      if (!await console.confirm('Use this value?', defaultValue: true)) {
        return;
      }
    }
    editor = next;
    console.success('${def.key} set (not saved yet)');
  }

  // ---- flavors -----------------------------------------------------------------

  Future<void> _flavors() async {
    while (true) {
      final names = {
        ...project.flavors,
        ...editor.keys(['flavors'])
      }.toList()
        ..sort();
      final choice = await console.choose(
        'Flavors',
        [...names, 'Add a flavor...'],
        hints: [
          for (final n in names)
            editor.keys(['flavors']).contains(n)
                ? 'configured'
                : 'detected, nothing set',
          'a name that is not detected from Gradle/Xcode',
        ],
      );
      if (choice == null) return;
      String name;
      if (choice < names.length) {
        name = names[choice];
      } else {
        final text = await console.ask('Flavor name');
        if (text == null) return;
        if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(text)) {
          console.error('Use letters, digits, "_" or "-", starting with a '
              'letter.');
          continue;
        }
        name = text;
      }
      await _flavor(name);
    }
  }

  Future<void> _flavor(String name) async {
    final defs = flavorSettings(name);
    while (true) {
      final config = _build(editor);
      final choice = await console.choose(
        'Flavor $name',
        [for (final d in defs) d.path.last],
        hints: [
          for (final d in defs)
            '${_changed(d) ? '* ' : ''}${d.current(config)}  ${d.summary}',
        ],
      );
      if (choice == null) return;
      await _edit(defs[choice]);
    }
  }

  // ---- review and save ----------------------------------------------------------

  /// `key: before => after` for everything that differs from the file.
  List<String> changes() {
    final flavorNames = {
      ...original.keys(['flavors']),
      ...editor.keys(['flavors']),
    };
    final defs = [
      ...globalSettings(),
      for (final f in flavorNames) ...flavorSettings(f),
    ];
    String show(Object? v) => v == null ? '(not set)' : '$v';
    return [
      for (final d in defs)
        if (_changed(d))
          '${d.key}: ${show(original.raw(d.path))}  =>  '
              '${show(editor.raw(d.path))}',
    ];
  }

  void _review() {
    final list = changes();
    console.heading('Changes');
    if (list.isEmpty) {
      console.out('Nothing changed.');
      return;
    }
    for (final line in list) {
      console.out('  ${console.style.cyan(console.style.bullet)} $line');
    }
  }

  Future<bool> _save() async {
    if (!dirty && File(savePath).existsSync()) {
      console.out('Nothing to save.');
      return false;
    }
    _review();
    if (!await console.confirm('Write $savePath and reload?',
        defaultValue: true)) {
      return false;
    }
    try {
      _build(editor);
      final tmp = File('$savePath.tmp');
      await tmp.writeAsString(editor.text);
      await tmp.rename(savePath);
    } on Object catch (e) {
      console.error('Could not save: $e');
      return false;
    }
    original = editor;
    console.success('Saved $savePath');
    return true;
  }
}
