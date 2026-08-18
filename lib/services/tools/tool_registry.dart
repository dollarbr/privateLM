import 'dart:async';

/// One thing the model can ask the app to do.
class Tool {
  final String name;
  final String description;

  /// Argument name -> what it means. Used to build the prompt the model reads,
  /// so keep the wording as short as it can be and still be unambiguous.
  final Map<String, String> parameters;

  final FutureOr<String> Function(Map<String, String> args) run;

  /// Shown in Settings so the user knows which tools leave the device.
  final bool requiresNetwork;

  const Tool({
    required this.name,
    required this.description,
    this.parameters = const {},
    required this.run,
    this.requiresNetwork = false,
  });

  String get signature => parameters.isEmpty
      ? '$name()'
      : '$name(${parameters.keys.map((k) => '$k="..."').join(', ')})';
}

/// The catalogue, plus the prompt that tells the model it exists.
///
/// Deliberately not the meta-tool (`list_tools` / `search_tools`) design
/// PocketStrike uses: that pattern earns its keep at 42 tools, where listing
/// them all would swamp the context. With a handful, the whole catalogue costs
/// less than the two meta-tools plus the extra round trip needed to discover
/// anything. Revisit when this list grows past roughly a dozen entries.
class ToolRegistry {
  ToolRegistry(Iterable<Tool> tools)
      : _tools = {for (final t in tools) t.name: t};

  final Map<String, Tool> _tools;

  Iterable<Tool> get all => _tools.values;

  Tool? byName(String name) => _tools[name.toLowerCase().trim()];

  /// Appended to the system prompt when tools are on.
  ///
  /// One call format is advertised, not three, even though the parser accepts
  /// several: a small model given options picks badly. The parser's tolerance is
  /// there to catch a model that ignores the instruction, not to invite it.
  String get promptSection {
    if (_tools.isEmpty) return '';
    final lines = _tools.values
        .map((t) => '- ${t.signature} — ${t.description}')
        .join('\n');
    return '''
You can call tools. To call one, reply with ONLY this line and nothing else:
[TOOL_CALL: name(arg="value")]

The result comes back to you in the next turn; answer the user with it then.
Call a tool only when you cannot answer without it.

Available tools:
$lines''';
  }

  /// Run a call and return what should be fed back to the model.
  ///
  /// A failing tool returns its error as a normal result rather than throwing:
  /// the model can then say what went wrong, which beats the turn dying.
  Future<String> execute(String name, Map<String, String> args) async {
    final tool = byName(name);
    if (tool == null) {
      return 'Error: no tool named "$name". Available: ${_tools.keys.join(", ")}.';
    }
    try {
      return await tool.run(args);
    } catch (e) {
      return 'Error: $name failed — $e';
    }
  }
}
