class AiModel {
  static const runtimeLlama = 'llama';
  static const runtimeLiteRt = 'litert';
  static const runtimeSd = 'sd';

  static bool hasVisionMarker(String value) {
    final lower = value.toLowerCase();
    return lower.contains('vl-') ||
        lower.contains('-vl') ||
        lower.contains('llava') ||
        lower.contains('vision');
  }

  final String name;
  final String filename;
  final String url;
  final String size;
  final String description;
  final String template;
  final String runtime;
  final bool isVision;

  /// Multimodal projector for GGUF models: the second file that turns pixels
  /// or audio samples into embeddings. Empty for models that have none, and
  /// always empty for LiteRT, which carries its encoders inside the .litertlm.
  final String mmprojUrl;
  final String mmprojFilename;
  final bool isImported;
  final bool isCustom;

  AiModel({
    required this.name,
    required this.filename,
    required this.url,
    required this.size,
    required this.description,
    required this.template,
    String? runtime,
    this.isVision = false,
    this.isImported = false,
    this.isCustom = false,
    this.mmprojUrl = '',
    this.mmprojFilename = '',
  }) : runtime = runtime ?? runtimeFromFilename(filename, template: template);

  factory AiModel.fromMap(Map<String, String> map) => AiModel(
        name: map['name'] ?? '',
        filename: map['filename'] ?? '',
        url: map['url'] ?? '',
        size: map['size'] ?? '',
        description: map['description'] ?? '',
        template: map['template'] ?? 'chatml',
        runtime: map['runtime'],
        isVision: map['vision'] == 'true',
        isImported: map['imported'] == 'true',
        isCustom: map['custom'] == 'true',
        mmprojUrl: map['mmprojUrl'] ?? '',
        mmprojFilename: map['mmprojFilename'] ?? '',
      );

  Map<String, String> toMap() => {
        'name': name,
        'filename': filename,
        'url': url,
        'size': size,
        'description': description,
        'template': template,
        'runtime': runtime,
        if (isVision) 'vision': 'true',
        if (isImported) 'imported': 'true',
        if (isCustom) 'custom': 'true',
        if (mmprojUrl.isNotEmpty) 'mmprojUrl': mmprojUrl,
        if (mmprojFilename.isNotEmpty) 'mmprojFilename': mmprojFilename,
      };

  /// True when this model needs a projector alongside the weights.
  bool get needsMmproj => mmprojFilename.isNotEmpty;

  static String runtimeFromFilename(String filename, {String? template}) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.litertlm')) return runtimeLiteRt;
    if (lower.endsWith('.safetensors') || template == runtimeSd) {
      return runtimeSd;
    }
    return runtimeLlama;
  }

  AiModel copyWith({
    String? name,
    String? filename,
    String? url,
    String? size,
    String? description,
    String? template,
    String? runtime,
    bool? isVision,
    bool? isImported,
    bool? isCustom,
    String? mmprojUrl,
    String? mmprojFilename,
  }) {
    return AiModel(
      name: name ?? this.name,
      filename: filename ?? this.filename,
      url: url ?? this.url,
      size: size ?? this.size,
      description: description ?? this.description,
      template: template ?? this.template,
      runtime: runtime ?? this.runtime,
      isVision: isVision ?? this.isVision,
      isImported: isImported ?? this.isImported,
      isCustom: isCustom ?? this.isCustom,
      mmprojUrl: mmprojUrl ?? this.mmprojUrl,
      mmprojFilename: mmprojFilename ?? this.mmprojFilename,
    );
  }
}
