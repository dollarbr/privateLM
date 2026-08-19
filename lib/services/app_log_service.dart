import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'crash_reporting_service.dart';

class AppLogEntry {
  final DateTime timestamp;
  final String level;
  final String message;
  final String? details;

  AppLogEntry({
    required this.level,
    required this.message,
    this.details,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isImportant => level == 'ERROR' || level == 'WARNING';

  String format() {
    final buffer = StringBuffer()
      ..write('[${timestamp.toIso8601String()}] ')
      ..write('$level: $message');
    if (details != null && details!.trim().isNotEmpty) {
      buffer.write('\n$details');
    }
    return buffer.toString();
  }
}

class AppLogService extends GetxService {
  /// What the Logs screen shows. Memory only, and deliberately short.
  final entries = <AppLogEntry>[].obs;

  static const _maxEntries = 200;
  static const _maxFileBytes = 1024 * 1024;
  static const _flushInterval = Duration(seconds: 2);
  static const _nativePollInterval = Duration(seconds: 1);

  File? _logFile;
  final _pending = <String>[];
  Timer? _flushTimer;
  Timer? _nativeTimer;
  bool _flushing = false;

  /// Path of the on-disk log, once [onInit] has resolved it.
  String? get logFilePath => _logFile?.path;

  @override
  void onInit() {
    super.onInit();
    // A crash or an OOM kill takes the in-memory ring with it, which is
    // exactly the case worth investigating, so everything also goes to a file.
    unawaited(_openLogFile());
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(_flush()));
    if (!kIsWeb && Platform.isAndroid) {
      // ggml and llama.cpp log through __android_log_print, so their output
      // never reached Dart and the Logs screen could not show why a load
      // picked a backend or failed to allocate. Drain their ring instead.
      _nativeTimer =
          Timer.periodic(_nativePollInterval, (_) => unawaited(_drainNative()));
    }
  }

  @override
  void onClose() {
    _flushTimer?.cancel();
    _nativeTimer?.cancel();
    unawaited(_flush());
    super.onClose();
  }

  Future<void> _openLogFile() async {
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
          '/logs');
      await dir.create(recursive: true);
      final file = File('${dir.path}/app.log');
      if (await file.exists() && await file.length() > _maxFileBytes) {
        await file.rename('${dir.path}/app.log.1');
      }
      _logFile = file;
      _pending.insert(
        0,
        '\n===== session started ${DateTime.now().toIso8601String()} =====',
      );
      await _flush();
    } catch (e) {
      // Losing the file sink must not take the in-memory log down with it.
      debugPrint('[AppLogService] cannot open log file: $e');
    }
  }

  Future<void> _flush() async {
    final file = _logFile;
    if (file == null || _pending.isEmpty || _flushing) return;
    _flushing = true;
    final batch = List<String>.from(_pending);
    _pending.clear();
    try {
      await file.writeAsString('${batch.join('\n')}\n',
          mode: FileMode.append, flush: true);
      if (await file.length() > _maxFileBytes) {
        await file.rename('${file.parent.path}/app.log.1');
        _logFile = File('${file.parent.path}/app.log');
      }
    } catch (e) {
      debugPrint('[AppLogService] cannot write log file: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> _drainNative() async {
    try {
      final lines = await LlamaMultimodal.drainNativeLog();
      for (final line in lines) {
        final tab = line.indexOf('\t');
        final level = tab > 0 ? line.substring(0, tab) : 'INFO';
        final message = tab > 0 ? line.substring(tab + 1) : line;
        // Straight into the ring, bypassing _add: these already went to
        // logcat, and routing ggml's chatter through Crashlytics as
        // non-fatals would bury the reports that matter.
        _push(AppLogEntry(level: level, message: '[native] $message'));
      }
    } catch (_) {
      // The channel is absent before the plugin attaches; nothing to log.
    }
  }

  void _push(AppLogEntry entry) {
    entries.insert(0, entry);
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    _pending.add(entry.format());
  }

  void warning(String message, {Object? details}) {
    _add('WARNING', message, details);
  }

  void error(String message, {Object? details}) {
    _add('ERROR', message, details);
  }

  void info(String message, {Object? details}) {
    _add('INFO', message, details);
  }

  void debug(String message, {Object? details}) {
    _add('DEBUG', message, details);
  }

  void _add(String level, String message, Object? details) {
    _push(AppLogEntry(
      level: level,
      message: message,
      details: details?.toString(),
    ));
    if ((level == 'ERROR' || level == 'WARNING') &&
        Get.isRegistered<CrashReportingService>()) {
      Get.find<CrashReportingService>().recordNonFatal(
        details ?? message,
        reason: message,
        extra: {'app_log_level': level},
      );
    }
  }

  List<AppLogEntry> get importantEntries =>
      entries.where((entry) => entry.isImportant).toList();

  String get shareText {
    final selected = importantEntries.isEmpty ? entries : importantEntries;
    return selected.map((entry) => entry.format()).join('\n\n');
  }

  Future<void> copyImportantLogs() async {
    await Clipboard.setData(ClipboardData(text: shareText));
  }

  /// Hands the on-disk log to the system share sheet.
  ///
  /// The clipboard only ever carried this session's important entries; a
  /// crash report needs the full history, including the native lines and
  /// whatever the run before the crash wrote.
  ///
  /// Returns false when there is no file yet — on web, or before [onInit]
  /// has resolved the directory.
  Future<bool> shareLogFile() async {
    await _flush();
    final file = _logFile;
    if (file == null || !await file.exists()) return false;
    final previous = File('${file.parent.path}/app.log.1');
    await Share.shareXFiles(
      [
        if (await previous.exists()) XFile(previous.path),
        XFile(file.path),
      ],
      subject: 'privateLM logs',
    );
    return true;
  }

  void clear() {
    entries.clear();
  }
}
