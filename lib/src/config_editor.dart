import 'package:yaml/yaml.dart';

import 'config.dart';

/// Edits a `flutter_buildkit.yaml` text in place, keeping the comments and
/// the order of everything it does not touch.
///
/// Keys are addressed by path, e.g. `['pre_build', 'clean']` or
/// `['flavors', 'dev', 'target']`. Values are `bool`, `int`, `String`,
/// `List<String>` (written as a flow list), or null to remove the key.
/// Immutable: every change returns a new editor.
class ConfigEditor {
  ConfigEditor(String text) : text = text.replaceAll('\r\n', '\n');

  final String text;

  /// The editor for a new config file: the documented template.
  factory ConfigEditor.template() => ConfigEditor(AppConfig.template);

  /// Parses the text, throwing [ConfigException] for bad YAML or values.
  AppConfig build(String projectDir,
      {Map<String, String> env = const {}, String? configFile}) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ConfigException('Not valid YAML: ${e.message}');
    }
    if (doc != null && doc is! Map) {
      throw ConfigException('The config must be a YAML map.');
    }
    return AppConfig.fromYaml(projectDir, (doc as Map?) ?? const {},
        env: env, configFile: configFile);
  }

  /// The raw value at [path] as plain Dart (maps, lists, scalars), or null.
  Object? raw(List<String> path) {
    Object? node;
    try {
      node = loadYaml(text);
    } on YamlException {
      return null;
    }
    for (final key in path) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node;
  }

  /// Names under [path] (e.g. the configured flavors).
  List<String> keys(List<String> path) {
    final node = raw(path);
    return node is Map ? [for (final k in node.keys) '$k'] : const [];
  }

  /// Sets or (with null) removes the key at [path].
  ConfigEditor set(List<String> path, Object? value) {
    assert(path.isNotEmpty);
    final lines = text.split('\n');
    final found = _locate(lines, path);

    if (found.leaf != null) {
      final i = found.leaf!;
      final end = _blockEnd(lines, i);
      if (value == null) {
        lines.removeRange(i, end);
      } else {
        final indent = _indentOf(lines[i]);
        final comment = _comment(lines[i]);
        lines.replaceRange(i, end, [
          '${' ' * indent}${path.last}: ${_render(value)}$comment',
        ]);
      }
      return ConfigEditor(lines.join('\n'));
    }
    if (value == null) return this;

    // Walk down to the deepest parent that exists, then add the rest.
    final missing = path.length - found.depth;
    final remaining = path.sublist(path.length - missing);
    final out = <String>[];
    var indent = found.childIndent;
    for (var i = 0; i < remaining.length - 1; i++) {
      out.add('${' ' * indent}${remaining[i]}:');
      indent += 2;
    }
    out.add('${' ' * indent}${remaining.last}: ${_render(value)}');

    if (found.parent == null) {
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      lines.addAll(out);
      lines.add('');
    } else {
      final parent = found.parent!;
      // `flavors: {}` has to become a block before it can hold children.
      final head = lines[parent];
      if (RegExp(r'^\s*[^#\s][^:]*:\s*(\{\s*\}|\[\s*\]|null|~)\s*(#.*)?$')
          .hasMatch(head)) {
        lines[parent] = head.substring(0, head.indexOf(':') + 1);
      }
      lines.insertAll(found.insertAt, out);
    }
    return ConfigEditor(lines.join('\n'));
  }

  // ---- text helpers ---------------------------------------------------------

  static bool _skippable(String line) =>
      line.trim().isEmpty || line.trimLeft().startsWith('#');

  static int _indentOf(String line) => line.length - line.trimLeft().length;

  /// One past the last line belonging to the key on line [i] (its nested
  /// block, if any).
  static int _blockEnd(List<String> lines, int i) {
    final indent = _indentOf(lines[i]);
    var end = i + 1;
    var last = i;
    for (; end < lines.length; end++) {
      if (_skippable(lines[end])) continue;
      if (_indentOf(lines[end]) <= indent) break;
      last = end;
    }
    return last + 1;
  }

  /// Finds [path]. `leaf` is the line of the full path when present;
  /// otherwise `parent`/`depth`/`insertAt`/`childIndent` say where a new
  /// key goes (`depth` = how many path parts exist).
  static _Found _locate(List<String> lines, List<String> path) {
    var from = 0;
    var to = lines.length;
    var indent = 0;
    int? parent;
    var depth = 0;
    for (var level = 0; level < path.length; level++) {
      final key = path[level];
      final re = RegExp('^${' ' * indent}${RegExp.escape(key)}:(?:\\s|\$)');
      int? at;
      for (var i = from; i < to; i++) {
        if (_skippable(lines[i])) continue;
        if (_indentOf(lines[i]) < indent) break;
        if (_indentOf(lines[i]) == indent && re.hasMatch(lines[i])) {
          at = i;
          break;
        }
      }
      if (at == null) break;
      if (level == path.length - 1) return _Found(leaf: at);
      parent = at;
      depth = level + 1;
      from = at + 1;
      to = _blockEnd(lines, at);
      // Children are indented by whatever the first child uses.
      var childIndent = indent + 2;
      for (var i = from; i < to; i++) {
        if (!_skippable(lines[i])) {
          childIndent = _indentOf(lines[i]);
          break;
        }
      }
      indent = childIndent;
    }
    if (parent == null) return _Found(depth: 0, childIndent: 0);
    // Insert after the parent's last real line.
    return _Found(
        parent: parent,
        depth: depth,
        childIndent: indent,
        insertAt: _blockEnd(lines, parent));
  }

  /// The trailing ` # comment` of a line, if any, with its leading spaces.
  static String _comment(String line) {
    final colon = line.indexOf(':');
    if (colon < 0) return '';
    var rest = line.substring(colon + 1);
    final trimmed = rest.trimLeft();
    var skip = 0;
    if (trimmed.startsWith('"') || trimmed.startsWith("'")) {
      final q = trimmed[0];
      var j = 1;
      while (j < trimmed.length) {
        if (q == '"' && trimmed[j] == r'\') {
          j += 2;
          continue;
        }
        if (trimmed[j] == q) break;
        j++;
      }
      skip = rest.length - trimmed.length + j + 1;
    }
    rest = rest.substring(skip.clamp(0, rest.length));
    final m = RegExp(r'\s+#.*$').firstMatch(rest);
    return m == null ? '' : m.group(0)!;
  }

  static const _reserved = {
    'true', 'false', 'null', 'yes', 'no', 'on', 'off', 'y', 'n', '~', //
  };

  static String _render(Object value) {
    if (value is bool || value is int) return '$value';
    if (value is List) return '[${value.map(_scalar).join(', ')}]';
    return _scalar(value);
  }

  static String _scalar(Object? value) {
    final s = '$value';
    final plain = RegExp(r'^[A-Za-z_./~-][A-Za-z0-9_./~ \-]*$').hasMatch(s) &&
        !_reserved.contains(s.toLowerCase()) &&
        !s.endsWith(' ') &&
        !s.startsWith('- ') &&
        s != '-';
    if (plain) return s;
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
}

class _Found {
  _Found({
    this.leaf,
    this.parent,
    this.depth = 0,
    this.childIndent = 0,
    this.insertAt = 0,
  });

  final int? leaf;
  final int? parent;
  final int depth;
  final int childIndent;
  final int insertAt;
}
