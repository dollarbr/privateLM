import 'package:flutter/services.dart';

/// What a projector can actually do, as reported by libmtmd after loading it.
class MultimodalSupport {
  const MultimodalSupport({
    required this.vision,
    required this.audio,
    required this.audioSampleRate,
  });

  final bool vision;
  final bool audio;

  /// Sample rate the audio encoder was trained on, in Hz (0 when there is no
  /// audio support). Audio handed to [LlamaMultimodal.setMedia] must already
  /// be at this rate.
  final int audioSampleRate;

  bool get any => vision || audio;

  @override
  String toString() => 'MultimodalSupport(vision: $vision, audio: $audio, '
      'audioSampleRate: $audioSampleRate)';
}

/// Vision and audio input for GGUF models, backed by libmtmd.
///
/// A multimodal GGUF model comes as two files: the language model and a
/// separate projector (`mmproj-*.gguf`) that turns pixels or samples into
/// embeddings the model can read. Load the model first, then its projector.
class LlamaMultimodal {
  static const _channel = MethodChannel('llama_flutter_android/mtmd');

  /// The token sequence that marks where media belongs in a prompt.
  ///
  /// Put one per attachment, in order, inside the user's turn. If the prompt
  /// carries the wrong number of them the native side rewrites the prompt with
  /// the markers up front rather than failing the request.
  static Future<String> mediaMarker() async =>
      await _channel.invokeMethod<String>('mediaMarker') ?? '<__media__>';

  /// Takes everything ggml and llama.cpp have logged since the last call.
  ///
  /// Each line is `LEVEL\tmessage`. The native side buffers into a ring and
  /// hands it over on request rather than pushing, because its log callback
  /// runs on llama.cpp worker threads mid-inference. Empty before the native
  /// library is loaded.
  static Future<List<String>> drainNativeLog() async =>
      await _channel.invokeListMethod<String>('drainNativeLog') ?? const [];

  /// Loads the projector that pairs with the currently loaded model.
  ///
  /// Returns null when the file cannot be used — a projector built for a
  /// different architecture is the usual reason.
  static Future<MultimodalSupport?> loadProjector(
    String path, {
    bool useGpu = true,
    int nThreads = 4,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'loadMmproj',
        {'path': path, 'useGpu': useGpu, 'nThreads': nThreads},
      );
      if (result == null) return null;
      return MultimodalSupport(
        vision: result['vision'] as bool? ?? false,
        audio: result['audio'] as bool? ?? false,
        audioSampleRate: result['audioSampleRate'] as int? ?? 0,
      );
    } on PlatformException {
      return null;
    }
  }

  static Future<void> freeProjector() async {
    try {
      await _channel.invokeMethod<void>('freeMmproj');
    } on PlatformException {
      // Nothing loaded, or the model is already gone: either way there is no
      // projector left to free, which is the outcome asked for.
    }
  }

  /// Queues attachments for the next generation.
  ///
  /// Consumed by the generate call that follows, then cleared — media does not
  /// carry over to a later turn, though its embeddings stay in the KV cache
  /// like any other context.
  static Future<void> setMedia(List<String> paths) async {
    await _channel.invokeMethod<void>('setMedia', {'paths': paths});
  }
}
