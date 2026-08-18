import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:intl/intl.dart';

import 'calculator.dart';
import 'tool_registry.dart';
import 'web_tools.dart';

/// Every tool the app can offer, offline ones first.
///
/// The offline three answer what a language model genuinely cannot know or
/// reliably compute: the wall clock, arithmetic, and the hardware it runs on.
/// The two network tools are listed here too but each one is individually
/// switchable in Settings, because turning them on is the moment a local-only
/// app starts talking to the internet. Tools needing a runtime permission
/// (location, contacts, camera) are still not wired up.
///
/// [enabled] filters by name; null means every tool. Pass the user's selection
/// so the prompt advertises exactly what will actually run — a model told about
/// a tool that then refuses to run wastes a turn arguing with itself.
ToolRegistry buildDefaultToolRegistry({
  Set<String>? enabled,
  String customSearchUrl = '',
  String customSearchToken = '',
}) =>
    ToolRegistry([
      Tool(
        name: 'get_datetime',
        description: "The device's current date and time, with its time zone.",
        run: (_) async {
          final now = DateTime.now();
          return '${DateFormat('EEEE, d MMMM y, HH:mm:ss').format(now)} '
              '(${now.timeZoneName}, UTC${now.timeZoneOffset.isNegative ? '-' : '+'}'
              '${now.timeZoneOffset.inHours.abs().toString().padLeft(2, '0')}:'
              '${(now.timeZoneOffset.inMinutes.abs() % 60).toString().padLeft(2, '0')})';
        },
      ),
      Tool(
        name: 'calculate',
        description: 'Evaluate an arithmetic expression, e.g. (12.5 * 3) / 2.',
        parameters: {'expression': 'the expression to evaluate'},
        run: (args) {
          final expression = args['expression'] ?? '';
          if (expression.trim().isEmpty) {
            return 'Error: no expression given.';
          }
          final value = Calculator.evaluate(expression);
          return value == null
              ? 'Error: "$expression" is not an expression I can evaluate.'
              : Calculator.format(value);
        },
      ),
      Tool(
        name: 'get_device_info',
        description: 'Model, manufacturer, OS version and SoC of this device.',
        run: (_) async {
          final plugin = DeviceInfoPlugin();
          if (Platform.isAndroid) {
            final a = await plugin.androidInfo;
            return '${a.manufacturer} ${a.model} — Android ${a.version.release} '
                '(API ${a.version.sdkInt}), SoC ${a.hardware}, '
                '${a.supportedAbis.join("/")}';
          }
          if (Platform.isIOS) {
            final i = await plugin.iosInfo;
            return '${i.name} ${i.model} — ${i.systemName} ${i.systemVersion}';
          }
          return 'Unknown platform: ${Platform.operatingSystem}';
        },
      ),
      Tool(
        name: 'web_search',
        description: 'Search the live web for current information — news, '
            'prices, weather, anything past the training cutoff. Returns titles, '
            'URLs and snippets; call read_url on a result for the full page.',
        parameters: {'query': 'what to search for'},
        requiresNetwork: true,
        run: (args) => webSearch(
          args['query'] ?? '',
          customSearchUrl: customSearchUrl,
          customSearchToken: customSearchToken,
        ),
      ),
      Tool(
        name: 'read_url',
        description: 'Fetch a web page and return its readable text. Use after '
            'web_search, or when the user shares a link.',
        parameters: {'url': 'full http(s) URL'},
        requiresNetwork: true,
        run: (args) => readUrl(args['url'] ?? ''),
      ),
    ].where((t) => enabled == null || enabled.contains(t.name)));
