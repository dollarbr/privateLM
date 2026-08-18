/// Which compute tier a model load should aim at.
///
/// The ladder is NPU -> GPU -> CPU. Every tier degrades on its own: LiteRT-LM
/// falls back internally (NPU -> GPU -> CPU) and llama.cpp simply runs the
/// layers it could not offload on the CPU. So a plan is a *preference*, never a
/// promise — always report the backend that actually came back, not this one.
enum AccelTier { npu, gpu, cpu }

/// The decision for one model load.
class AccelerationPlan {
  final AccelTier tier;

  /// llama.cpp `n_gpu_layers`. 0 on the CPU tier, 99 means "all of them"
  /// (llama.cpp clamps it to the model's real layer count).
  final int gpuLayers;

  /// Why this tier — goes straight into the load log, so a device that lands on
  /// CPU says which rung it fell off of.
  final String reason;

  const AccelerationPlan(this.tier, this.gpuLayers, this.reason);

  bool get usesGpu => tier == AccelTier.gpu;
  String get backendName => tier.name;
}

/// Pick a tier for this load.
///
/// [mode] is the user's setting: `cpu_safe` and `gpu_fast` are explicit
/// overrides and are honoured as far as the hardware allows; `auto_fast` walks
/// the full ladder.
///
/// [recommendedGpuLayers] comes from the native probe, which already weighs
/// free RAM against the device-local heap. It is the number to trust — there is
/// deliberately no GPU-model allowlist here. Binning by the digits in a GPU
/// name ("Mali-G615" -> 615 -> too low, use CPU) is what kept whole vendors off
/// the GPU regardless of how much memory they actually had.
AccelerationPlan planAcceleration({
  required String mode,
  required bool vulkanSupported,
  required int recommendedGpuLayers,
  bool npuAvailable = false,
}) {
  if (mode == 'cpu_safe') {
    return const AccelerationPlan(AccelTier.cpu, 0, 'CPU — user chose CPU Safe');
  }

  if (mode == 'gpu_fast') {
    return vulkanSupported
        ? const AccelerationPlan(AccelTier.gpu, 99, 'GPU — user chose GPU Fast (full offload)')
        : const AccelerationPlan(AccelTier.cpu, 0, 'CPU — GPU Fast asked for, but no Vulkan on this device');
  }

  // auto_fast: the whole ladder.
  if (npuAvailable) {
    return const AccelerationPlan(AccelTier.npu, 0, 'NPU — vendor dispatch driver present');
  }
  if (vulkanSupported && recommendedGpuLayers > 0) {
    return AccelerationPlan(
      AccelTier.gpu,
      recommendedGpuLayers,
      'GPU — Vulkan available, $recommendedGpuLayers layers fit in memory',
    );
  }
  if (vulkanSupported) {
    return const AccelerationPlan(AccelTier.cpu, 0, 'CPU — Vulkan present but not enough free memory to offload');
  }
  return const AccelerationPlan(AccelTier.cpu, 0, 'CPU — no NPU driver and no Vulkan');
}

/// Tier for the LiteRT-LM runtime.
///
/// Kept separate from [planAcceleration] because the two runtimes do not answer
/// to the same probe: LiteRT's GPU tier rides the accelerator bundled inside the
/// litertlm AAR (libLiteRtClGlAccelerator.so — OpenCL/GL, not Vulkan), so our
/// llama.cpp Vulkan capability says nothing about it, and it has no notion of a
/// layer count. What the NPU tier *does* need is a vendor dispatch driver, which
/// is what [npuAvailable] reports.
AccelTier planLiteRtTier({required String mode, required bool npuAvailable}) {
  if (mode == 'cpu_safe') return AccelTier.cpu;
  if (npuAvailable) return AccelTier.npu;
  return AccelTier.gpu;
}
