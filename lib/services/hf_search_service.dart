import 'package:dio/dio.dart';

/// One repository as it comes back from a Hugging Face search.
class HfRepo {
  final String id;
  final int downloads;
  final int likes;

  /// What the hub says the repo is for. Empty on the many GGUF repos that
  /// never set one — absence is not evidence of incompatibility, so those are
  /// kept rather than filtered out.
  final String pipelineTag;

  const HfRepo({
    required this.id,
    this.downloads = 0,
    this.likes = 0,
    this.pipelineTag = '',
  });

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

  /// LiteRT-LM weights rather than a GGUF. They carry their encoders inside
  /// the file, so they never pair with a projector.
  bool get isLiteRt => filename.toLowerCase().endsWith('.litertlm');

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

/// The on-device runtimes this app has, as a hub query.
///
/// Two formats rather than one because privateLM ships both llama.cpp and
/// LiteRT-LM, and a GGUF-only browser hid half of what it can actually load.
enum HfFormat {
  any('Any', ''),
  gguf('GGUF', 'gguf'),
  liteRtLm('LiteRT-LM', 'litert-lm');

  const HfFormat(this.label, this.tag);

  final String label;

  /// The hub tag that selects it. `litert-lm` and not `litert`: the latter also
  /// catches TTS, detection and image models built for the runtime.
  final String tag;
}

/// The Hugging Face facets this app can act on, as one value.
///
/// Only facets the hub's public model API honours are here — the web UI offers
/// more, but a control that quietly does nothing is worse than no control.
class HfFilters {
  const HfFilters({
    this.format = HfFormat.any,
    this.author = '',
    this.minParamsB,
    this.maxParamsB,
    this.tags = const {},
    this.pipelineTag = '',
    this.fitsDevice = true,
  });

  /// Which runtime's weights to list.
  final HfFormat format;

  /// Repo owner, e.g. `bartowski`. Empty means any.
  final String author;

  /// Parameter count in billions. Null means unbounded on that end.
  final double? minParamsB;
  final double? maxParamsB;

  /// Hub tags ANDed onto the query: `moe`, `4-bit`, `imatrix`, ...
  final Set<String> tags;

  /// A single `pipeline_tag`. Empty means "anything this app can run".
  final String pipelineTag;

  /// Hide GGUFs that cannot fit this phone's memory. Applies to the file list,
  /// where sizes are known — the repo index carries none.
  final bool fitsDevice;

  /// `num_parameters` as the hub wants it, or null when unbounded both ways.
  String? get paramRangeQuery {
    if (minParamsB == null && maxParamsB == null) return null;
    return 'min:${_b(minParamsB ?? 0)},max:${_b(maxParamsB ?? 2000)}';
  }

  static String _b(double v) =>
      '${v == v.roundToDouble() ? v.round() : v}B';

  /// How many facets are set, for the badge on the Filters button.
  /// `fitsDevice` is excluded: it is on by default, so counting it would show
  /// "1 filter" on an untouched sheet.
  int get activeCount =>
      (format == HfFormat.any ? 0 : 1) +
      (author.isEmpty ? 0 : 1) +
      (minParamsB == null ? 0 : 1) +
      (maxParamsB == null ? 0 : 1) +
      (pipelineTag.isEmpty ? 0 : 1) +
      tags.length;

  HfFilters copyWith({
    HfFormat? format,
    String? author,
    double? minParamsB,
    double? maxParamsB,
    Set<String>? tags,
    String? pipelineTag,
    bool? fitsDevice,
    bool clearMin = false,
    bool clearMax = false,
  }) {
    return HfFilters(
      format: format ?? this.format,
      author: author ?? this.author,
      minParamsB: clearMin ? null : (minParamsB ?? this.minParamsB),
      maxParamsB: clearMax ? null : (maxParamsB ?? this.maxParamsB),
      tags: tags ?? this.tags,
      pipelineTag: pipelineTag ?? this.pipelineTag,
      fitsDevice: fitsDevice ?? this.fitsDevice,
    );
  }
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

  /// One page of the index, most downloaded first.
  ///
  /// An empty [query] browses instead of searching: the hub is the catalogue
  /// here, and a search box alone made the user guess a name before seeing
  /// anything. [skip] pages through it — the hub's cursor is stateful and an
  /// offset is not, which matters when a filter changes mid-scroll.
  Future<List<HfRepo>> browseRepos({
    String query = '',
    HfFilters filters = const HfFilters(),
    int skip = 0,
    int limit = 30,
  }) async {
    if (filters.format != HfFormat.any) {
      return _page(filters.format.tag, query, filters, skip, limit);
    }

    // The hub ANDs repeated `filter` params, so "GGUF or LiteRT" cannot be one
    // request. Two, merged by downloads. Each page is ordered; the sequence
    // across pages is not perfectly interleaved, which is invisible at a
    // glance and cheaper than paging a union client-side.
    final pages = await Future.wait([
      _page(HfFormat.gguf.tag, query, filters, skip, limit),
      _page(HfFormat.liteRtLm.tag, query, filters, skip, limit),
    ]);
    final seen = <String>{};
    final merged = [
      for (final page in pages)
        for (final repo in page)
          if (seen.add(repo.id)) repo,
    ]..sort((a, b) => b.downloads.compareTo(a.downloads));
    return merged;
  }

  Future<List<HfRepo>> _page(
    String formatTag,
    String query,
    HfFilters filters,
    int skip,
    int limit,
  ) async {
    final q = query.trim();
    final range = filters.paramRangeQuery;

    final response = await _dio.get<List<dynamic>>(
      '$_base/models',
      queryParameters: {
        // Repeated `filter` params are ANDed by the hub, so the format tag
        // always survives whatever the user picked in Misc.
        'filter': [formatTag, ...filters.tags],
        'sort': 'downloads',
        'direction': -1,
        'limit': limit,
        if (skip > 0) 'skip': skip,
        if (q.isNotEmpty) 'search': q,
        if (filters.author.isNotEmpty) 'author': filters.author,
        if (filters.pipelineTag.isNotEmpty) 'pipeline_tag': filters.pipelineTag,
        if (range != null) 'num_parameters': range,
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
              pipelineTag: (raw['pipeline_tag'] ?? '').toString(),
            ))
        .where((repo) => repo.id.isNotEmpty)
        .toList();
  }

  /// Pipelines this app can actually load. The GGUF index also carries
  /// embedders, ASR and TTS weights there is no runtime for here.
  ///
  /// Applied by the caller rather than inside [browseRepos], so that a page
  /// which filters down to nothing is still distinguishable from the end of
  /// the index — otherwise paging stops on the first all-embeddings page.
  ///
  /// An empty tag passes: most GGUF repos set none, and excluding them would
  /// empty the list.
  static bool isRunnable(String pipelineTag) =>
      pipelineTag.isEmpty || runnablePipelines.contains(pipelineTag);

  static const runnablePipelines = {
    'text-generation',
    'text2text-generation',
    'image-text-to-text',
    'audio-text-to-text',
    'any-to-any',
  };

  /// Every loadable weight file in [repoId], with its size, smallest first.
  ///
  /// Split archives (`-00001-of-00003.gguf`) are dropped: this app downloads
  /// one file per model and cannot reassemble a set. So are LiteRT builds
  /// compiled for another vendor's accelerator, which would download fine and
  /// then fail to load.
  Future<List<HfFile>> listModelFiles(String repoId) async {
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
        .where((entry) {
          final lower = entry.key.toLowerCase();
          return lower.endsWith('.gguf') || lower.endsWith('.litertlm');
        })
        .where((entry) => !_isForeignBuild(entry.key))
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
              // A .litertlm carries its encoders inside, so pairing one with a
              // repo's mmproj would offer a download that does nothing.
              projectors: e.key.toLowerCase().endsWith('.litertlm')
                  ? const []
                  : projectors,
            ))
        .toList();

    files.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
    return files;
  }

  /// A LiteRT build for hardware this app will not be running on.
  ///
  /// litert-community ships one `.litertlm` per accelerator alongside the
  /// portable one — `_Google_Tensor_G5`, `_qualcomm_sm8750`, `-web`. They are
  /// several gigabytes each and load nowhere else.
  ///
  /// ponytail: a denylist of the vendors seen in the wild, not a positive match
  /// against this phone's SoC. If a MediaTek-specific build ever ships, widen
  /// this into a real check against DeviceInfoService.socHardware.
  static bool _isForeignBuild(String path) => RegExp(
        r'_(google_tensor|qualcomm|intel|amd|nvidia)[_.a-z0-9]*\.litertlm$|'
        r'-web\.litertlm$',
        caseSensitive: false,
      ).hasMatch(path);

}
