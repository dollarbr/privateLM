import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../services/device_info_service.dart';
import '../services/hf_search_service.dart';

/// Browse Hugging Face for a GGUF and add it to the local catalogue.
///
/// Opens on the index rather than on an empty box: the hub is the catalogue
/// here, and a search field alone made the user guess a name before seeing
/// anything. Two steps rather than one flat list, because a repo holds the same
/// weights at a dozen quantisations and which one fits a phone is the whole
/// decision.
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
  static const _pageSize = 30;

  final _search = HfSearchService();
  final _field = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  HfFilters _filters = const HfFilters();
  List<HfRepo> _repos = [];
  int _skip = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  HfRepo? _openRepo;
  List<HfFile> _files = [];
  HfFile? _pickingProjectorFor;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_openRepo != null || !_hasMore || _loadingMore || _busy) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _load();
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 450), () => _load(reset: true));
  }

  /// Fetch one page. [reset] starts over — a new query or a changed filter
  /// invalidates the offset, so paging on top of it would interleave two lists.
  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _debounce?.cancel();
      setState(() {
        _skip = 0;
        _hasMore = true;
        _repos = [];
        _openRepo = null;
        _busy = true;
        _error = '';
      });
    } else {
      setState(() => _loadingMore = true);
    }

    final skip = reset ? 0 : _skip;
    try {
      final page = await _search.browseRepos(
        query: _field.text,
        filters: _filters,
        skip: skip,
        limit: _pageSize,
      );
      if (!mounted) return;
      final usable = _filters.pipelineTag.isNotEmpty
          ? page
          : page
              .where((r) => HfSearchService.isRunnable(r.pipelineTag))
              .toList();
      setState(() {
        _busy = false;
        _loadingMore = false;
        _skip = skip + _pageSize;
        // A short page means the end of the index. A full page that filtered
        // down to nothing does not, which is why the test is on the raw count.
        _hasMore = page.length == _pageSize;
        _repos = reset ? usable : [..._repos, ...usable];
        if (_repos.isEmpty && !_hasMore) {
          _error = 'Nothing matches. Loosen a filter or try another name.';
        }
      });
      // Keep pulling when a whole page was embedders or ASR weights: no new
      // rows means no new scroll extent, so the scroll listener would never
      // fire again and the list would look finished at zero.
      if (mounted && usable.isEmpty && _hasMore) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _loadingMore = false;
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
      final files = await _search.listModelFiles(repo.id);
      if (!mounted) return;
      setState(() {
        _files = files;
        _busy = false;
        if (files.isEmpty) {
          _error = 'Nothing loadable in this repo. Split archives and '
              'LiteRT builds for other vendors\' accelerators are skipped.';
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

  /// The weights this phone has the memory to load, given the current filter.
  List<HfFile> get _visibleFiles {
    if (!_filters.fitsDevice) return _files;
    final budget = _maxBytes;
    if (budget <= 0) return _files;
    return _files
        .where((f) =>
            f.sizeBytes + (f.recommendedProjector?.sizeBytes ?? 0) <= budget)
        .toList();
  }

  int get _maxBytes {
    final device = Get.isRegistered<DeviceInfoService>()
        ? Get.find<DeviceInfoService>()
        : null;
    return device?.maxModelBytes ?? 0;
  }

  Future<void> _openFilters() async {
    final next = await showModalBottomSheet<HfFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FiltersSheet(initial: _filters),
    );
    if (next == null || !mounted) return;
    setState(() => _filters = next);
    _load(reset: true);
  }

  String _templateFor(String filename) {
    final lower = filename.toLowerCase();
    // LiteRT-LM carries its own prompt format; the GGUF templates do not apply.
    if (lower.endsWith('.litertlm')) return 'litert';
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
          '${projector != null ? ' — needs a ${projector.sizeLabel} '
              'projector (${projector.filename})' : ''}',
      template: _templateFor(file.filename),
      // Weights only, not weights+projector: the catalogue convention is that
      // `size` describes the one file `filename` names, and the completeness
      // guard in ModelController compares that file's bytes against it. A
      // combined figure here makes a fully downloaded model look truncated.
      size: file.sizeLabel,
      // Only read for LiteRT: a GGUF's vision comes from the projector, which
      // ModelController infers from mmprojFilename below.
      isVision: file.isLiteRt &&
          const {'image-text-to-text', 'any-to-any'}
              .contains(_openRepo?.pipelineTag),
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
    final browsing = _openRepo == null;
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
              if (!browsing)
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
                      'Hugging Face',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (browsing) _buildFiltersButton(theme),
            ],
          ),
          const SizedBox(height: 12),
          if (browsing)
            TextField(
              controller: _field,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _load(reset: true),
              decoration: InputDecoration(
                hintText: 'Search the GGUF index',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _field.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _field.clear();
                          _load(reset: true);
                        },
                      ),
                border: const OutlineInputBorder(),
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
              child:
                  Text(_error, style: TextStyle(color: theme.colorScheme.error)),
            ),
          Flexible(
            child: _busy
                ? const SizedBox.shrink()
                : browsing
                    ? _buildRepoList()
                    : _pickingProjectorFor != null
                        ? _buildProjectorList(_pickingProjectorFor!)
                        : _buildFileList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersButton(ThemeData theme) {
    final count = _filters.activeCount;
    return TextButton.icon(
      onPressed: _openFilters,
      icon: const Icon(Icons.tune, size: 18),
      label: Text(count == 0 ? 'Filters' : 'Filters ($count)'),
      style: TextButton.styleFrom(
        foregroundColor: count == 0 ? null : theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildRepoList() {
    return ListView.builder(
      controller: _scroll,
      shrinkWrap: true,
      itemCount: _repos.length + (_loadingMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _repos.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
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
    final theme = Theme.of(context);
    final visible = _visibleFiles;
    final hidden = _files.length - visible.length;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: visible.length + (hidden > 0 ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= visible.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '$hidden file${hidden == 1 ? '' : 's'} hidden — larger than this '
              'phone can load. Turn off "Fits my device" in Filters to see '
              'them.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
          );
        }
        final file = visible[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title:
              Text(file.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// Everything the hub's model API lets us narrow by, in one sheet.
class _FiltersSheet extends StatefulWidget {
  const _FiltersSheet({required this.initial});

  final HfFilters initial;

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  /// Parameter counts offered as steps rather than a free field: a slider over
  /// four orders of magnitude is unusable on a phone, and these are the sizes
  /// GGUF repos actually come in.
  static const _paramSteps = <double>[0.5, 1, 2, 3, 4, 7, 8, 13, 20, 30, 70];

  static const _pipelines = <String, String>{
    '': 'Any',
    'text-generation': 'Text',
    'image-text-to-text': 'Vision',
    'audio-text-to-text': 'Audio',
    'any-to-any': 'Omni',
  };

  /// The hub's "Misc" facets, limited to the ones a GGUF repo actually carries.
  static const _misc = <String, String>{
    'moe': 'Mixture of Experts',
    '4-bit': '4-bit precision',
    '8-bit': '8-bit precision',
    '16-bit': '16-bit precision',
    'imatrix': 'Importance matrix',
    'merge': 'Merge',
    'mergekit': 'Made with mergekit',
    'custom_code': 'Custom code',
    'conversational': 'Conversational',
  };

  /// Quantisers whose repos make up most of the index.
  static const _authors = <String>[
    'unsloth',
    'bartowski',
    'ggml-org',
    'lmstudio-community',
    'mradermacher',
    'TheBloke',
    'Qwen',
    'google',
    'microsoft',
  ];

  late HfFilters _f = widget.initial;
  late final TextEditingController _author =
      TextEditingController(text: widget.initial.author);

  @override
  void dispose() {
    _author.dispose();
    super.dispose();
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
              Expanded(
                child: Text('Filters', style: theme.textTheme.titleMedium),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _f = const HfFilters());
                  _author.clear();
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _label(theme, 'FORMAT'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final f in HfFormat.values)
                      ChoiceChip(
                        label: Text(f.label),
                        selected: _f.format == f,
                        onSelected: (_) =>
                            setState(() => _f = _f.copyWith(format: f)),
                      ),
                  ],
                ),
                _label(theme, 'MODALITY'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in _pipelines.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _f.pipelineTag == e.key,
                        onSelected: (_) =>
                            setState(() => _f = _f.copyWith(pipelineTag: e.key)),
                      ),
                  ],
                ),
                _label(theme, 'PARAMETERS'),
                Row(
                  children: [
                    Expanded(
                      child: _paramDropdown(
                        hint: 'Min',
                        value: _f.minParamsB,
                        onChanged: (v) => setState(() => _f = v == null
                            ? _f.copyWith(clearMin: true)
                            : _f.copyWith(minParamsB: v)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _paramDropdown(
                        hint: 'Max',
                        value: _f.maxParamsB,
                        onChanged: (v) => setState(() => _f = v == null
                            ? _f.copyWith(clearMax: true)
                            : _f.copyWith(maxParamsB: v)),
                      ),
                    ),
                  ],
                ),
                _label(theme, 'PROVIDER'),
                TextField(
                  controller: _author,
                  decoration: const InputDecoration(
                    hintText: 'Any — or an owner, e.g. bartowski',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      setState(() => _f = _f.copyWith(author: v.trim())),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final a in _authors)
                      ChoiceChip(
                        label: Text(a),
                        selected: _f.author == a,
                        onSelected: (on) {
                          final next = on ? a : '';
                          _author.text = next;
                          setState(() => _f = _f.copyWith(author: next));
                        },
                      ),
                  ],
                ),
                _label(theme, 'MISC'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final e in _misc.entries)
                      FilterChip(
                        label: Text(e.value),
                        selected: _f.tags.contains(e.key),
                        onSelected: (on) => setState(() {
                          final tags = {..._f.tags};
                          if (on) {
                            tags.add(e.key);
                          } else {
                            tags.remove(e.key);
                          }
                          _f = _f.copyWith(tags: tags);
                        }),
                      ),
                  ],
                ),
                _label(theme, 'THIS DEVICE'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _f.fitsDevice,
                  onChanged: (v) =>
                      setState(() => _f = _f.copyWith(fitsDevice: v)),
                  title: const Text('Fits my device'),
                  subtitle: const Text(
                      'Hide GGUFs too large for this phone\'s memory'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_f),
              child: const Text('Apply'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paramDropdown({
    required String hint,
    required double? value,
    required ValueChanged<double?> onChanged,
  }) {
    return DropdownButtonFormField<double?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<double?>(value: null, child: Text('Any')),
        for (final step in _paramSteps)
          DropdownMenuItem<double?>(
            value: step,
            child: Text(
                '${step == step.roundToDouble() ? step.round() : step}B'),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.hintColor,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}
