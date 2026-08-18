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

  /// Soname of the vendor driver the app managed to load from the system, or
  /// empty when the driver is bundled instead — or absent altogether.
  final String systemDriver;

  /// `Build.SOC_MODEL` when the platform reports it (API 31+), else empty.
  final String soc;

  final String nativeLibraryDir;

  const NpuStatus({
    required this.available,
    this.libraries = const [],
    this.systemDriver = '',
    this.soc = '',
    this.nativeLibraryDir = '',
  });

  static Future<NpuStatus> probe() async {
    final map = await FlutterLitertLmPlatform.instance.npuStatus();
    return NpuStatus(
      available: map['available'] == true,
      libraries: (map['libraries'] as List?)?.cast<String>() ?? const [],
      systemDriver: (map['systemDriver'] as String?) ?? '',
      soc: (map['soc'] as String?) ?? '',
      nativeLibraryDir: (map['nativeLibraryDir'] as String?) ?? '',
    );
  }

  @override
  String toString() => available
      ? 'NPU available on ${soc.isEmpty ? "this SoC" : soc} via '
          '${libraries.join(", ")}'
          '${systemDriver.isEmpty ? "" : " + system driver lib$systemDriver.so"}'
      : 'NPU unavailable${soc.isEmpty ? "" : " on $soc"} — '
          '${libraries.isEmpty ? "no dispatch library bundled" : "no vendor driver reachable"}';
}
