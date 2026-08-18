import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/tools/calculator.dart';
import 'package:privatelm/services/tools/tool_call_parser.dart';
import 'package:privatelm/services/tools/tool_registry.dart';

void main() {
  group('ToolCallParser', () {
    test('reads the bracket convention', () {
      final call = ToolCallParser.parseFirst(
        'Sure, let me check. [TOOL_CALL: get_weather(city="Porto Alegre", unit="c")]',
      )!;
      expect(call.name, 'get_weather');
      expect(call.arguments['city'], 'Porto Alegre');
      expect(call.arguments['unit'], 'c');
    });

    test('reads a <tool_call> JSON block', () {
      final call = ToolCallParser.parseFirst(
        '<tool_call>{"name": "calculate", "arguments": {"expression": "2+2"}}</tool_call>',
      )!;
      expect(call.name, 'calculate');
      expect(call.arguments['expression'], '2+2');
    });

    test('reads a fenced JSON block', () {
      final call = ToolCallParser.parseFirst(
        'I will use a tool:\n```json\n{"name": "get_datetime", "arguments": {}}\n```',
      )!;
      expect(call.name, 'get_datetime');
      expect(call.arguments, isEmpty);
    });

    test('survives the malformed JSON small models emit', () {
      // Single quotes, a trailing comma, and no closing fence — all seen in the
      // wild from sub-2B models.
      final call = ToolCallParser.parseFirst(
        '''<tool_call>{"name": "calculate", "arguments": {'expression': '5*5',}}</tool_call>''',
      )!;
      expect(call.name, 'calculate');
      expect(call.arguments['expression'], '5*5');
    });

    test('plain prose is not a tool call', () {
      expect(ToolCallParser.parseFirst('I think the answer is 42.'), isNull);
      expect(ToolCallParser.parseFirst('Use [TOOL_CALL] carefully.'), isNull);
    });

    test('raw text is exact, so the call can be stripped from the reply', () {
      const reply = 'One moment. [TOOL_CALL: get_datetime()] Checking.';
      final call = ToolCallParser.parseFirst(reply)!;
      expect(reply.replaceAll(call.raw, '').trim(), 'One moment.  Checking.'.trim());
    });
  });

  group('Calculator', () {
    test('respects precedence and parentheses', () {
      expect(Calculator.evaluate('2 + 3 * 4'), 14);
      expect(Calculator.evaluate('(2 + 3) * 4'), 20);
      expect(Calculator.evaluate('12.5 * 3 / 2'), 18.75);
    });

    test('handles unary minus and the symbols people type', () {
      expect(Calculator.evaluate('-5 + 3'), -2);
      expect(Calculator.evaluate('2 × 3'), 6);
      expect(Calculator.evaluate('10 ÷ 4'), 2.5);
    });

    test('exponentiation is right-associative', () {
      expect(Calculator.evaluate('2^3^2'), 512);
    });

    test('rejects malformed input instead of guessing', () {
      expect(Calculator.evaluate('(2 + 3'), isNull);
      expect(Calculator.evaluate('2 +'), isNull);
      expect(Calculator.evaluate('rm -rf /'), isNull);
      expect(Calculator.evaluate(''), isNull);
    });

    test('division by zero is not a result', () {
      expect(Calculator.evaluate('1/0'), isNull);
    });

    test('whole results lose the trailing .0', () {
      expect(Calculator.format(4.0), '4');
      expect(Calculator.format(2.5), '2.5');
    });
  });

  group('ToolRegistry', () {
    final registry = ToolRegistry([
      Tool(
        name: 'echo',
        description: 'Give back what it was given.',
        parameters: {'text': 'anything'},
        run: (args) => args['text'] ?? '',
      ),
      Tool(
        name: 'boom',
        description: 'Always fails.',
        run: (_) => throw StateError('nope'),
      ),
    ]);

    test('executes a known tool', () async {
      expect(await registry.execute('echo', {'text': 'hi'}), 'hi');
    });

    test('an unknown tool answers with the catalogue, it does not throw', () async {
      final result = await registry.execute('nope', {});
      expect(result, contains('no tool named'));
      expect(result, contains('echo'));
    });

    test('a throwing tool becomes an error message the model can read', () async {
      expect(await registry.execute('boom', {}), contains('boom failed'));
    });

    test('the prompt section advertises one call format and every tool', () {
      final prompt = registry.promptSection;
      expect(prompt, contains('[TOOL_CALL: name(arg="value")]'));
      expect(prompt, contains('echo(text="...")'));
      expect(prompt, contains('boom()'));
    });
  });
}
