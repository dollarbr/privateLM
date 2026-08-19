import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/hf_search_service.dart';

/// Serves one canned JSON body so the parsing can be tested without network.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.body);

  final Object body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

HfSearchService _serving(Object body) {
  final dio = Dio()..httpClientAdapter = _CannedAdapter(body);
  return HfSearchService(dio: dio);
}

void main() {
  test('an empty query does not hit the network', () async {
    final service = _serving([]);
    expect(await service.searchRepos('   '), isEmpty);
  });

  test('search keeps id, downloads and likes', () async {
    final service = _serving([
      {'id': 'nvidia/Nemotron-Flash-3B-GGUF', 'downloads': 1234, 'likes': 7},
      {'modelId': 'other/repo-GGUF', 'downloads': 1},
      {'downloads': 99}, // no id at all — must be dropped
    ]);

    final repos = await service.searchRepos('nemotron');

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

    final files = await service.listGgufFiles('owner/repo');

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

    final files = await service.listGgufFiles('owner/repo');

    expect(files.single.isMultimodal, isFalse);
    expect(files.single.projectors, isEmpty);
    expect(files.single.recommendedProjector, isNull);
  });
}
