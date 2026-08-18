import 'dart:io';

import 'package:flutter/services.dart';

/// Turn an attached audio file into something LiteRT-LM can actually read.
///
/// LiteRT-LM's audio preprocessor is miniaudio built for WAV only, so an .ogg
/// dies inside the JNI call with "Failed to initialize miniaudio decoder, error
/// code: -10". Android's MediaCodec has decoders for the rest, so the platform
/// side converts to 16 kHz mono WAV before the file ever reaches the model.
class AudioWavService {
  static const _channel = MethodChannel('com.aichat.ai_chat/media');

  /// Formats worth converting. WAV is absent on purpose — it already works, and
  /// the platform side short-circuits a 16 kHz mono one anyway.
  static const convertible = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wma'};

  static bool needsConversion(String path) =>
      convertible.contains(path.split('.').last.toLowerCase());

  /// Returns the WAV path, or the original path if conversion is unavailable.
  ///
  /// Failing soft is deliberate: passing the original through gives the user
  /// the model's own error instead of swallowing the attachment silently.
  static Future<String> ensureWav(String path) async {
    if (!Platform.isAndroid) return path;
    try {
      final wav = await _channel.invokeMethod<String>('audioToWav', {'path': path});
      return wav ?? path;
    } on PlatformException {
      return path;
    } on MissingPluginException {
      return path;
    }
  }
}
