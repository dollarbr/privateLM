import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/acceleration.dart';

void main() {
  group('planAcceleration', () {
    test('a Mali GPU with memory to spare goes to the GPU, not to the CPU', () {
      // The regression this whole file exists for: a Mali-G615 (Dimensity 7300)
      // used to be forced onto the CPU by a GPU-name allowlist, twice over —
      // once in Kotlin ("Mali" -> 0 layers) and once in Dart (615 < 650).
      final plan = planAcceleration(
        mode: 'auto_fast',
        vulkanSupported: true,
        recommendedGpuLayers: 99,
      );
      expect(plan.tier, AccelTier.gpu);
      expect(plan.gpuLayers, 99);
    });

    test('NPU wins over GPU when a vendor dispatch driver is present', () {
      final plan = planAcceleration(
        mode: 'auto_fast',
        vulkanSupported: true,
        recommendedGpuLayers: 99,
        npuAvailable: true,
      );
      expect(plan.tier, AccelTier.npu);
    });

    test('no Vulkan means CPU even when the probe suggested layers', () {
      final plan = planAcceleration(
        mode: 'auto_fast',
        vulkanSupported: false,
        recommendedGpuLayers: 99,
      );
      expect(plan.tier, AccelTier.cpu);
      expect(plan.gpuLayers, 0);
    });

    test('the probe deciding no layers fit keeps the load on the CPU', () {
      final plan = planAcceleration(
        mode: 'auto_fast',
        vulkanSupported: true,
        recommendedGpuLayers: 0,
      );
      expect(plan.tier, AccelTier.cpu);
    });

    test('cpu_safe overrides every capability', () {
      final plan = planAcceleration(
        mode: 'cpu_safe',
        vulkanSupported: true,
        recommendedGpuLayers: 99,
        npuAvailable: true,
      );
      expect(plan.tier, AccelTier.cpu);
      expect(plan.gpuLayers, 0);
    });

    test('gpu_fast forces a full offload, but cannot invent Vulkan', () {
      expect(
        planAcceleration(mode: 'gpu_fast', vulkanSupported: true, recommendedGpuLayers: 0).gpuLayers,
        99,
      );
      expect(
        planAcceleration(mode: 'gpu_fast', vulkanSupported: false, recommendedGpuLayers: 99).tier,
        AccelTier.cpu,
      );
    });
  });

  group('planLiteRtTier', () {
    test('NPU only when a dispatch driver is actually bundled', () {
      expect(planLiteRtTier(mode: 'auto_fast', npuAvailable: true), AccelTier.npu);
      expect(planLiteRtTier(mode: 'auto_fast', npuAvailable: false), AccelTier.gpu);
    });

    test('cpu_safe skips the whole ladder', () {
      expect(planLiteRtTier(mode: 'cpu_safe', npuAvailable: true), AccelTier.cpu);
    });
  });
}
