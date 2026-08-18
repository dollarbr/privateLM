import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:intl/intl.dart';

import 'calculator.dart';
import 'tool_registry.dart';

/// The tools that need no permission and no network.
///
/// Everything here answers something a language model genuinely cannot know or
/// reliably compute on its own: the wall clock, arithmetic, and what hardware it
/// is running on. Tools that need a runtime permission (location, contacts,
/// camera) or the network belong behind an explicit user opt-in and are not
/// wired up here.
ToolRegistry buildDefaultToolRegistry() => ToolRegistry([
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
    ]);
