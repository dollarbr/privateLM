/// One tool invocation recovered from a model's output.
class ToolCall {
  final String name;
  final Map<String, String> arguments;

  /// Exactly the substring the call occupied, so the caller can strip it out of
  /// what gets shown to the user.
  final String raw;

  const ToolCall({required this.name, required this.arguments, required this.raw});

  @override
  String toString() => '$name(${arguments.entries.map((e) => '${e.key}="${e.value}"').join(', ')})';
}

/// Finds tool calls in free-form model output.
///
/// Small local models do not emit clean JSON on demand: they wander between
/// `[TOOL_CALL: name(arg="v")]`, a ```json fence, a bare `{"name": ...}` object,
/// and any of those wrapped in prose. Being strict here means a 1B model can
/// never use a tool at all, so this accepts every shape and normalises them into
/// one. Anything it cannot read is simply not a tool call — the text is left for
/// the user to see, which is the safe direction to fail in.
class ToolCallParser {
  /// `[TOOL_CALL: name(arg="value", other="value")]` — the convention
  /// PocketStrike uses, and the easiest for a small model to hit.
  static final _bracket = RegExp(
    r'\[TOOL_CALL:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)\)\s*\]',
    caseSensitive: false,
  );

  /// `<tool_call>{"name": "x", "arguments": {...}}</tool_call>` — the Qwen /
  /// Hermes convention, and what most chat templates advertise.
  static final _tagged = RegExp(
    r'<tool_call>\s*(\{.*?\})\s*</tool_call>',
    caseSensitive: false,
    dotAll: true,
  );

  /// A ```json fence or a bare object carrying a name plus arguments.
  static final _fenced = RegExp(
    r'```(?:json)?\s*(\{.*?"name".*?\})\s*```',
    dotAll: true,
  );

  /// One `key = "value"` / `"key": "value"` pair, in any of the quoting styles a
  /// model reaches for. The key may itself be quoted — JSON always quotes it.
  static final _argPair = RegExp(
    r'''["']?([a-zA-Z_][a-zA-Z0-9_]*)["']?\s*[:=]\s*(?:"([^"]*)"|'([^']*)'|([^,\s)}]+))''',
  );

  /// Every call found, in the order they appear.
  static List<ToolCall> parse(String text) {
    final calls = <ToolCall>[];

    for (final m in _bracket.allMatches(text)) {
      calls.add(ToolCall(
        name: m.group(1)!,
        arguments: _parseArgs(m.group(2) ?? ''),
        raw: m.group(0)!,
      ));
    }

    for (final pattern in [_tagged, _fenced]) {
      for (final m in pattern.allMatches(text)) {
        final call = _fromJsonish(m.group(1)!, m.group(0)!);
        if (call != null) calls.add(call);
      }
    }

    return calls;
  }

  /// The first call, or null. Most turns carry at most one.
  static ToolCall? parseFirst(String text) {
    final calls = parse(text);
    return calls.isEmpty ? null : calls.first;
  }

  static Map<String, String> _parseArgs(String source) {
    final args = <String, String>{};
    for (final m in _argPair.allMatches(source)) {
      args[m.group(1)!] = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
    }
    return args;
  }

  /// Reads `{"name": "x", "arguments": {...}}` without a JSON parser: the object
  /// is frequently malformed (trailing commas, single quotes, an unclosed
  /// brace), and the same permissive pair-scan handles all of it.
  static ToolCall? _fromJsonish(String source, String raw) {
    final nameMatch = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(source);
    if (nameMatch == null) return null;

    final argsStart = RegExp(r'"(?:arguments|parameters|args)"\s*:\s*\{').firstMatch(source);
    var argSource = '';
    if (argsStart != null) {
      // Take to the matching brace so a nested object does not truncate the scan.
      var depth = 1;
      final buffer = StringBuffer();
      for (var i = argsStart.end; i < source.length && depth > 0; i++) {
        final ch = source[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) break;
        }
        buffer.write(ch);
      }
      argSource = buffer.toString();
    }

    return ToolCall(
      name: nameMatch.group(1)!,
      arguments: _parseArgs(argSource),
      raw: raw,
    );
  }
}
