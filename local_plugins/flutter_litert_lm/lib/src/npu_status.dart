import '../flutter_litert_lm_platform_interface.dart';

/// What the NPU tier can actually do on this device, right now.
///
/// [available] is false whenever no vendor dispatch library is bundled, even on
/// a SoC whose NPU LiteRT supports — requesting [LiteLmBackend.npu] then only
/// buys a failed engine init before the fallback chain takes over.
class NpuStatus {
  final bool available;

  /// The dispatch/driver libraries found next to the app's other native libs.
  final List<String> libraries;

  /// `Build.SOC_MODEL` when the platform reports it (API 31+), else empty.
  final String soc;

  final String nativeLibraryDir;

  const NpuStatus({
    required this.available,
    this.libraries = const [],
    this.soc = '',
    this.nativeLibraryDir = '',
  });

  static Future<NpuStatus> probe() async {
    final map = await FlutterLitertLmPlatform.instance.npuStatus();
    return NpuStatus(
      available: map['available'] == true,
      libraries: (map['libraries'] as List?)?.cast<String>() ?? const [],
      soc: (map['soc'] as String?) ?? '',
      nativeLibraryDir: (map['nativeLibraryDir'] as String?) ?? '',
    );
  }

  @override
  String toString() => available
      ? 'NPU available on ${soc.isEmpty ? "this SoC" : soc} via ${libraries.join(", ")}'
      : 'NPU unavailable${soc.isEmpty ? "" : " on $soc"} — no vendor dispatch library bundled';
}
