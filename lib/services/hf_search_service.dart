import 'package:dio/dio.dart';

/// One repository as it comes back from a Hugging Face search.
class HfRepo {
  final String id;
  final int downloads;
  final int likes;

  const HfRepo({required this.id, this.downloads = 0, this.likes = 0});

  String get owner => id.contains('/') ? id.split('/').first : '';
  String get name => id.contains('/') ? id.split('/').last : id;
}

/// A vision or audio projector shipped alongside the weights.
class HfProjector {
  final String repoId;
  final String path;
  final int sizeBytes;

  const HfProjector({
    required this.repoId,
    required this.path,
    required this.sizeBytes,
  });

  String get filename => path.split('/').last;
  String get url => 'https://huggingface.co/$repoId/resolve/main/$path';
  String get sizeLabel => _formatBytes(sizeBytes);
  String get quant => _quantOf(filename);
}

/// One downloadable GGUF inside a repository.
///
/// A repo usually holds the same weights at half a dozen quantisation levels,
/// so the file — not the repo — is what a user actually picks.
class HfFile {
  final String repoId;
  final String path;
  final int sizeBytes;

  /// The repo's projectors, smallest first. A multimodal GGUF is useless
  /// without one, so they travel with the file rather than as separate entries
  /// the user has to know to match up.
  final List<HfProjector> projectors;

  const HfFile({
    required this.repoId,
    required this.path,
    required this.sizeBytes,
    this.projectors = const [],
  });

  String get filename => path.split('/').last;
  String get url => 'https://huggingface.co/$repoId/resolve/main/$path';
  bool get isMultimodal => projectors.isNotEmpty;

  /// The projector to offer first: the smallest one.
  ///
  /// Repos that ship several differ only by quantisation, and on a phone the
  /// F16 encoder can cost more RAM than the model it serves (LFM2.5-VL: 856 MB
  /// against 583 MB for the Q8_0) for a quality difference nobody sees.
  HfProjector? get recommendedProjector =>
      projectors.isEmpty ? null : projectors.first;

  /// Quantisation as written in the filename ("Q4_K_M"), or an empty string
  /// when the name does not follow the convention.
  String get quant => _quantOf(filename);

  String get sizeLabel => _formatBytes(sizeBytes);

  /// Weights plus [projector], which is what the download actually costs.
  String totalSizeLabel([HfProjector? projector]) =>
      _formatBytes(sizeBytes + (projector?.sizeBytes ?? 0));
}

String _quantOf(String filename) {
  final match =
      RegExp(r'(IQ|Q)\d+(_[A-Z0-9]+)*|BF16|F16|F32', caseSensitive: false)
          .firstMatch(filename);
  return match?.group(0)?.toUpperCase() ?? '';
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return 'Unknown size';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  return '${(bytes / mb).round()} MB';
}

/// Search Hugging Face for GGUF models and list what a repo actually holds.
///
/// Anonymous access only: the public model API needs no token, and asking the
/// user for one to browse a public index would be a worse trade than the lower
/// rate limit it buys.
class HfSearchService {
  HfSearchService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _base = 'https://huggingface.co/api';
  static const _timeout = Duration(seconds: 20);

  /// Repositories matching [query] that carry GGUF files, most downloaded
  /// first. An empty query returns nothing rather than the whole index.
  Future<List<HfRepo>> searchRepos(String query, {int limit = 25}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final response = await _dio.get<List<dynamic>>(
      '$_base/models',
      queryParameters: {
        'search': q,
        'filter': 'gguf',
        'sort': 'downloads',
        'direction': -1,
        'limit': limit,
      },
      options: Options(
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        responseType: ResponseType.json,
      ),
    );

    return (response.data ?? [])
        .whereType<Map>()
        .map((raw) => HfRepo(
              id: (raw['id'] ?? raw['modelId'] ?? '').toString(),
              downloads: (raw['downloads'] as num?)?.toInt() ?? 0,
              likes: (raw['likes'] as num?)?.toInt() ?? 0,
            ))
        .where((repo) => repo.id.isNotEmpty)
        .toList();
  }

  /// Every GGUF in [repoId], with its size, sorted smallest first.
  ///
  /// Split archives (`-00001-of-00003.gguf`) are dropped: this app downloads
  /// one file per model and cannot reassemble a set.
  Future<List<HfFile>> listGgufFiles(String repoId) async {
    final response = await _dio.get<List<dynamic>>(
      '$_base/models/$repoId/tree/main',
      queryParameters: {'recursive': true},
      options: Options(
        receiveTimeout: _timeout,
        sendTimeout: _timeout,
        responseType: ResponseType.json,
      ),
    );

    final entries = (response.data ?? [])
        .whereType<Map>()
        .where((raw) => raw['type'] == 'file')
        .map((raw) => MapEntry(
              (raw['path'] ?? '').toString(),
              (raw['size'] as num?)?.toInt() ?? 0,
            ))
        .where((entry) => entry.key.toLowerCase().endsWith('.gguf'))
        .toList();

    bool isProjector(String path) =>
        path.split('/').last.toLowerCase().startsWith('mmproj');

    final projectors = entries.where((e) => isProjector(e.key)).map((e) =>
        HfProjector(repoId: repoId, path: e.key, sizeBytes: e.value)).toList()
      ..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));

    final files = entries
        .where((e) =>
            !isProjector(e.key) &&
            !RegExp(r'-\d{5}-of-\d{5}\.gguf$', caseSensitive: false)
                .hasMatch(e.key))
        .map((e) => HfFile(
              repoId: repoId,
              path: e.key,
              sizeBytes: e.value,
              projectors: projectors,
            ))
        .toList();

    files.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    return files;
  }
}
