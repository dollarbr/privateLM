import 'package:flutter/services.dart';

/// Pulls still frames out of a video so it can be attached to a chat.
///
/// No local runtime reads video, so a clip is handed to a vision model the only
/// way it can be: as a few evenly spaced stills. The decoding is done by
/// Android's own MediaMetadataRetriever (see VideoFrames.kt) rather than by a
/// bundled transcoder.
class VideoFramesService {
  static const _channel = MethodChannel('com.aichat.ai_chat/media');

  /// Extensions worth offering in the picker. Anything Android's media stack can
  /// open will work; these are the containers a phone actually produces or
  /// receives.
  static const supportedExtensions = {'mp4', 'mov', 'mkv', 'webm', '3gp', 'avi'};

  static bool isVideo(String extension) =>
      supportedExtensions.contains(extension.toLowerCase());

  /// Returns paths to the extracted JPEG frames, in playback order.
  ///
  /// [maxFrames] is deliberately small: every frame is another image the model
  /// has to encode, and on-device vision encoders are the slow part of a chat
  /// turn — four stills already cost more than the text around them.
  static Future<List<String>> extract(String path, {int maxFrames = 4}) async {
    final frames = await _channel.invokeListMethod<String>(
      'extractVideoFrames',
      {'path': path, 'maxFrames': maxFrames},
    );
    return frames ?? const [];
  }
}
