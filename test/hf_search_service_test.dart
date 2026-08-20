import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/hf_search_service.dart';

/// Serves one canned JSON body so the parsing can be tested without network.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.body);

  final Object body;

  /// The last request served, so a test can assert on what was asked for and
  /// not only on what came back.
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

late _CannedAdapter _adapter;

HfSearchService _serving(Object body) {
  _adapter = _CannedAdapter(body);
  final dio = Dio()..httpClientAdapter = _adapter;
  return HfSearchService(dio: dio);
}

void main() {
  test('an empty query browses the index instead of returning nothing',
      () async {
    final service = _serving([
      {'id': 'unsloth/Qwen3-GGUF', 'downloads': 5},
    ]);

    expect((await service.browseRepos()).map((r) => r.id),
        ['unsloth/Qwen3-GGUF']);
    // No `search` key at all, rather than an empty one the hub would honour.
    expect(_adapter.lastRequest!.queryParameters.containsKey('search'), isFalse);
  });

  test('filters become the query the hub expects', () async {
    final service = _serving([]);

    await service.browseRepos(
      query: 'qwen',
      filters: const HfFilters(
        format: HfFormat.gguf,
        author: 'bartowski',
        minParamsB: 1,
        maxParamsB: 4,
        tags: {'moe', '4-bit'},
        pipelineTag: 'image-text-to-text',
      ),
      skip: 60,
    );

    final q = _adapter.lastRequest!.queryParameters;
    expect(q['filter'], ['gguf', 'moe', '4-bit']);
    expect(q['search'], 'qwen');
    expect(q['author'], 'bartowski');
    expect(q['pipeline_tag'], 'image-text-to-text');
    expect(q['num_parameters'], 'min:1B,max:4B');
    expect(q['skip'], 60);
  });

  test('an unbounded parameter range is left off the query', () async {
    final service = _serving([]);
    await service.browseRepos();
    expect(_adapter.lastRequest!.queryParameters.containsKey('num_parameters'),
        isFalse);
    expect(const HfFilters(maxParamsB: 4).paramRangeQuery, 'min:0B,max:4B');
  });

  test('only pipelines the app can load count as runnable', () {
    expect(HfSearchService.isRunnable(''), isTrue);
    expect(HfSearchService.isRunnable('text-generation'), isTrue);
    expect(HfSearchService.isRunnable('image-text-to-text'), isTrue);
    expect(HfSearchService.isRunnable('feature-extraction'), isFalse);
    expect(HfSearchService.isRunnable('automatic-speech-recognition'), isFalse);
    expect(HfSearchService.isRunnable('text-to-speech'), isFalse);
  });

  test('both runtimes are browsed when no format is picked', () async {
    final service = _serving([
      {'id': 'unsloth/Qwen3-GGUF', 'downloads': 5},
    ]);

    final repos = await service.browseRepos();

    // One query per format, merged and deduplicated by id.
    expect(repos.map((r) => r.id), ['unsloth/Qwen3-GGUF']);
    expect(_adapter.lastRequest!.queryParameters['filter'],
        anyOf(equals(['gguf']), equals(['litert-lm'])));
  });

  test('a LiteRT build for another vendor is not offered', () async {
    final service = _serving([
      {'type': 'file', 'path': 'gemma.litertlm', 'size': 300},
      {'type': 'file', 'path': 'gemma_Google_Tensor_G5.litertlm', 'size': 400},
      {'type': 'file', 'path': 'gemma_qualcomm_sm8750.litertlm', 'size': 500},
      {'type': 'file', 'path': 'gemma-web.litertlm', 'size': 200},
      {'type': 'file', 'path': 'mmproj-gemma.gguf', 'size': 50},
    ]);

    final files = await service.listModelFiles('litert-community/gemma');

    expect(files.map((f) => f.filename), ['gemma.litertlm']);
    // The encoders live inside a .litertlm, so a stray mmproj is not paired.
    expect(files.single.projectors, isEmpty);
    expect(files.single.isLiteRt, isTrue);
  });

  test('the filter badge ignores the on-by-default device fit', () {
    expect(const HfFilters().activeCount, 0);
    expect(const HfFilters(fitsDevice: false).activeCount, 0);
    expect(const HfFilters(author: 'unsloth', tags: {'moe'}).activeCount, 2);
    expect(const HfFilters(format: HfFormat.gguf).activeCount, 1);
  });

  test('search keeps id, downloads and likes', () async {
    final service = _serving([
      {'id': 'nvidia/Nemotron-Flash-3B-GGUF', 'downloads': 1234, 'likes': 7},
      {'modelId': 'other/repo-GGUF', 'downloads': 1},
      {'downloads': 99}, // no id at all — must be dropped
    ]);

    final repos = await service.browseRepos(query: 'nemotron');

    expect(repos.map((r) => r.id),
        ['nvidia/Nemotron-Flash-3B-GGUF', 'other/repo-GGUF']);
    expect(repos.first.owner, 'nvidia');
    expect(repos.first.name, 'Nemotron-Flash-3B-GGUF');
    expect(repos.first.downloads, 1234);
    expect(repos.first.likes, 7);
  });

  test('file listing pairs a projector, drops splits, sorts by size', () async {
    final service = _serving([
      {'type': 'file', 'path': 'README.md', 'size': 10},
      {'type': 'file', 'path': 'model-Q8_0.gguf', 'size': 800},
      {'type': 'file', 'path': 'model-Q4_K_M.gguf', 'size': 400},
      {'type': 'file', 'path': 'mmproj-model-F16.gguf', 'size': 100},
      {'type': 'file', 'path': 'mmproj-model-Q8_0.gguf', 'size': 60},
      {'type': 'file', 'path': 'big-00001-of-00003.gguf', 'size': 900},
      {'type': 'directory', 'path': 'subdir'},
    ]);

    final files = await service.listModelFiles('owner/repo');

    expect(files.map((f) => f.filename), ['model-Q4_K_M.gguf', 'model-Q8_0.gguf']);

    final small = files.first;
    expect(small.quant, 'Q4_K_M');
    expect(small.url,
        'https://huggingface.co/owner/repo/resolve/main/model-Q4_K_M.gguf');
    expect(small.isMultimodal, isTrue);

    // Both projectors are offered, smallest first, and the smallest is the one
    // recommended: on a phone RAM is the scarce thing, and the repos that ship
    // several differ only by quantisation.
    expect(small.projectors.map((p) => p.filename),
        ['mmproj-model-Q8_0.gguf', 'mmproj-model-F16.gguf']);
    expect(small.recommendedProjector!.filename, 'mmproj-model-Q8_0.gguf');
    expect(small.totalSizeLabel(small.recommendedProjector), isNot('Unknown size'));
  });

  test('a repo with no projector reports none', () async {
    final service = _serving([
      {'type': 'file', 'path': 'plain-Q4_K_M.gguf', 'size': 400},
    ]);

    final files = await service.listModelFiles('owner/repo');

    expect(files.single.isMultimodal, isFalse);
    expect(files.single.projectors, isEmpty);
    expect(files.single.recommendedProjector, isNull);
  });
}
