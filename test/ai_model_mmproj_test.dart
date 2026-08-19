import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/ai_model.dart';

void main() {
  group('mmproj companion', () {
    final withProjector = AiModel(
      name: 'Qwen2.5-VL 3B Instruct (GGUF)',
      filename: 'Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf',
      url: 'https://example.invalid/model.gguf',
      size: '1.80 GB',
      description: 'Vision',
      template: 'chatml',
      isVision: true,
      mmprojUrl: 'https://example.invalid/mmproj.gguf',
      mmprojFilename: 'mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf',
    );

    test('a model without a projector does not claim to need one', () {
      final plain = AiModel(
        name: 'Llama',
        filename: 'llama.gguf',
        url: 'https://example.invalid/llama.gguf',
        size: '1 GB',
        description: '',
        template: 'chatml',
      );
      expect(plain.needsMmproj, isFalse);
      expect(plain.mmprojFilename, isEmpty);
    });

    test('survives the round trip through the stored map', () {
      final restored = AiModel.fromMap(withProjector.toMap());
      expect(restored.needsMmproj, isTrue);
      expect(restored.mmprojFilename, withProjector.mmprojFilename);
      expect(restored.mmprojUrl, withProjector.mmprojUrl);
    });

    test('the map stays clean when there is no projector', () {
      final map = AiModel(
        name: 'Llama',
        filename: 'llama.gguf',
        url: 'u',
        size: '1 GB',
        description: '',
        template: 'chatml',
      ).toMap();
      expect(map.containsKey('mmprojUrl'), isFalse);
      expect(map.containsKey('mmprojFilename'), isFalse);
    });

    test('copyWith carries the projector across', () {
      final renamed = withProjector.copyWith(name: 'Renamed');
      expect(renamed.needsMmproj, isTrue);
      expect(renamed.mmprojFilename, withProjector.mmprojFilename);
    });
  });
}
