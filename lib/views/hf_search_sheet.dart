import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../services/hf_search_service.dart';

/// Search Hugging Face for a GGUF and add it to the local catalogue.
///
/// Two steps rather than one flat list: a repo holds the same weights at a
/// dozen quantisations, and which one fits a phone is the whole decision.
class HfSearchSheet extends StatefulWidget {
  const HfSearchSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const HfSearchSheet(),
    );
  }

  @override
  State<HfSearchSheet> createState() => _HfSearchSheetState();
}

class _HfSearchSheetState extends State<HfSearchSheet> {
  final _search = HfSearchService();
  final _field = TextEditingController();
  Timer? _debounce;

  List<HfRepo> _repos = [];
  HfRepo? _openRepo;
  List<HfFile> _files = [];
  HfFile? _pickingProjectorFor;
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _runSearch(value));
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _repos = [];
        _openRepo = null;
        _error = '';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _openRepo = null;
    });
    try {
      final repos = await _search.searchRepos(query);
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Search failed: $e';
      });
    }
  }

  Future<void> _openFiles(HfRepo repo) async {
    setState(() {
      _busy = true;
      _error = '';
      _openRepo = repo;
      _files = [];
      _pickingProjectorFor = null;
    });
    try {
      final files = await _search.listGgufFiles(repo.id);
      if (!mounted) return;
      setState(() {
        _files = files;
        _busy = false;
        if (files.isEmpty) {
          _error = 'No single-file GGUF in this repo (split archives are '
              'skipped — this app downloads one file per model).';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not list files: $e';
      });
    }
  }

  String _templateFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains('gemma')) return 'gemma';
    if (lower.contains('llama3') || lower.contains('llama-3')) return 'llama3';
    if (lower.contains('phi3') || lower.contains('phi-3')) return 'phi3';
    return 'chatml';
  }

  Future<void> _add(HfFile file, {HfProjector? projector}) async {
    final controller = Get.find<ModelController>();
    await controller.addModelFromUrl(
      name: '${_openRepo?.name ?? file.repoId} ${file.quant}'.trim(),
      url: file.url,
      filename: file.filename,
      description: 'From Hugging Face: ${file.repoId}'
          '${projector != null ? ' \u2014 needs a ${projector.sizeLabel} '
              'projector (${projector.filename})' : ''}',
      template: _templateFor(file.filename),
      // Weights only, not weights+projector: the catalogue convention is that
      // `size` describes the one file `filename` names, and the completeness
      // guard in ModelController compares that file's bytes against it. A
      // combined figure here makes a fully downloaded model look truncated.
      size: file.sizeLabel,
      mmprojUrl: projector?.url ?? '',
      mmprojFilename: projector?.filename ?? '',
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    Get.snackbar(
      'Added',
      '${file.filename} is in your model list.',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_openRepo != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () => setState(() {
                    if (_pickingProjectorFor != null) {
                      _pickingProjectorFor = null;
                    } else {
                      _openRepo = null;
                    }
                  }),
                ),
              Expanded(
                child: Text(
                  _pickingProjectorFor?.filename ??
                      _openRepo?.id ??
                      'Search Hugging Face',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_openRepo == null)
            TextField(
              controller: _field,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: _runSearch,
              decoration: const InputDecoration(
                hintText: 'Model name, e.g. Nemotron-Flash',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error.isNotEmpty && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error, style: TextStyle(color: theme.colorScheme.error)),
            ),
          Flexible(
            child: _busy
                ? const SizedBox.shrink()
                : _openRepo == null
                    ? _buildRepoList()
                    : _pickingProjectorFor != null
                        ? _buildProjectorList(_pickingProjectorFor!)
                        : _buildFileList(),
          ),
        ],
      ),
    );
  }

  Widget _buildRepoList() {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _repos.length,
      itemBuilder: (_, i) {
        final repo = _repos[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(repo.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${repo.owner} · ${_compact(repo.downloads)} downloads',
            maxLines: 1,
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _openFiles(repo),
        );
      },
    );
  }

  Widget _buildFileList() {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _files.length,
      itemBuilder: (_, i) {
        final file = _files[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(file.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            file.isMultimodal
                ? '${file.sizeLabel} · ${file.projectors.length} projector'
                    '${file.projectors.length == 1 ? '' : 's'}'
                : file.sizeLabel,
          ),
          trailing: Icon(
            file.isMultimodal ? Icons.chevron_right : Icons.add_circle_outline,
            size: file.isMultimodal ? 18 : 20,
          ),
          onTap: () => file.isMultimodal
              ? setState(() => _pickingProjectorFor = file)
              : _add(file),
        );
      },
    );
  }

  /// Pick the encoder that comes with a multimodal model.
  ///
  /// Shown rather than decided silently: the projectors in one repo can differ
  /// by hundreds of megabytes, and on a phone that is the difference between a
  /// model that loads and one that does not.
  Widget _buildProjectorList(HfFile file) {
    final theme = Theme.of(context);
    final recommended = file.recommendedProjector;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: file.projectors.length,
      itemBuilder: (_, i) {
        final projector = file.projectors[i];
        final isRecommended = identical(projector, recommended);
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isRecommended
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
              width: isRecommended ? 1.5 : 1,
            ),
            color: isRecommended
                ? theme.colorScheme.primary.withValues(alpha: 0.06)
                : null,
          ),
          child: ListTile(
            dense: true,
            title: Row(
              children: [
                Flexible(
                  child: Text(projector.filename,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (isRecommended) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'RECOMMENDED',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              '${projector.sizeLabel} · '
              '${file.totalSizeLabel(projector)} with the model',
            ),
            trailing: const Icon(Icons.add_circle_outline, size: 20),
            onTap: () => _add(file, projector: projector),
          ),
        );
      },
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).round()}k';
    return '$n';
  }
}
