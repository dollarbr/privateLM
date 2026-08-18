import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../core/constants.dart';
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../services/local_image_service.dart';
import '../services/device_info_service.dart';
import '../services/tools/builtin_tools.dart';
import '../services/device_info_native.dart' as platform_info;
import '../ffi/sd_ffi_bindings.dart';
import 'log_view.dart';

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
        title: Text('Settings',
            style:
                GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 34)),
        toolbarHeight: 56,
      ),
      body: Obx(() => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              const SizedBox(height: 8),
              _sectionLabel(context, 'APPEARANCE'),
              _appleGroupedCard(context, isDark, children: [
                for (final mode in [
                  ThemeMode.light,
                  ThemeMode.dark,
                  ThemeMode.system
                ])
                  _appleListTile(
                    context,
                    isDark,
                    leading: Icon(_themeModeIcon(mode),
                        size: 20, color: Theme.of(context).hintColor),
                    title: _themeModeName(mode),
                    trailing: controller.themeMode.value == mode
                        ? Icon(Icons.check,
                            size: 18,
                            color: isDark
                                ? const Color(0xFF0A84FF)
                                : AppColors.primary)
                        : null,
                    showDivider: mode != ThemeMode.system,
                    onTap: () => controller.setThemeMode(mode),
                  ),
              ]),
              const SizedBox(height: 16),
              Obx(() => _buildFontSizeCard(context, isDark)),
              const SizedBox(height: 24),
              _sectionLabel(context, 'DIAGNOSTICS'),
              _appleGroupedCard(context, isDark, children: [
                _appleListTile(
                  context,
                  isDark,
                  leading:
                      _iconBox(const Color(0xFF5AC8FA), Icons.article_outlined),
                  title: 'Logs',
                  subtitle: 'View errors, warnings, and debug details',
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  showDivider: false,
                  onTap: () => Get.to(() => const LogView()),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'DEVICE'),
              _buildDeviceCard(context, isDark),
              const SizedBox(height: 24),
              _sectionLabel(context, 'INFERENCE MODE'),
              _appleGroupedCard(context, isDark, children: [
                _appleListTile(
                  context,
                  isDark,
                  leading:
                      _iconBox(AppColors.success, Icons.phone_iphone_rounded),
                  title: 'Local (On-Device)',
                  subtitle: _localSubtitle(),
                  trailing: controller.inferenceMode.value == 'local'
                      ? Icon(Icons.check,
                          size: 18,
                          color: isDark
                              ? const Color(0xFF0A84FF)
                              : AppColors.primary)
                      : null,
                  showDivider: true,
                  onTap: () => controller.setInferenceMode('local'),
                ),
                _appleListTile(
                  context,
                  isDark,
                  leading: _iconBox(AppColors.secondary, Icons.cloud_outlined),
                  title: 'Cloud API',
                  subtitle: controller.cloudProvider.value.toUpperCase(),
                  trailing: controller.inferenceMode.value == 'cloud'
                      ? Icon(Icons.check,
                          size: 18,
                          color: isDark
                              ? const Color(0xFF0A84FF)
                              : AppColors.primary)
                      : null,
                  showDivider: false,
                  onTap: () => controller.setInferenceMode('cloud'),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'SYSTEM PROMPT'),
              _appleGroupedCard(context, isDark, children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Applies to local and cloud models',
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color: Theme.of(context).hintColor)),
                        const SizedBox(height: 10),
                        TextField(
                          controller: controller.globalSystemPromptController,
                          minLines: 3,
                          maxLines: 6,
                          style: GoogleFonts.inter(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: AppConstants.systemPrompt,
                            suffixIcon: IconButton(
                                icon: const Icon(Icons.check_circle_outline,
                                    size: 20),
                                onPressed: () =>
                                    controller.setGlobalSystemPrompt(controller
                                        .globalSystemPromptController.text)),
                          ),
                          onSubmitted: (v) =>
                              controller.setGlobalSystemPrompt(v),
                        ),
                      ]),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'MODEL PARAMETERS'),
              _buildLiteRtCard(context, isDark),
              const SizedBox(height: 10),
              if (Platform.isAndroid) ...[
                _buildNpuCard(context, isDark),
                const SizedBox(height: 10),
              ],
              _buildThinkingCard(context, isDark),
              const SizedBox(height: 10),
              _buildToolsCard(context, isDark),
              const SizedBox(height: 10),
              _buildModelParametersCard(context, isDark),
              const SizedBox(height: 24),
              _sectionLabel(context, 'IMAGE GENERATION PARAMETERS'),
              _buildImageGenerationCard(context, isDark),
              const SizedBox(height: 24),
              _sectionLabel(context, 'ABOUT'),
              _appleGroupedCard(context, isDark, children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              isDark
                                  ? const Color(0xFF0A84FF)
                                  : AppColors.primary,
                              AppColors.secondary
                            ]),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.auto_awesome_rounded,
                            color: Colors.white, size: 22)),
                    const SizedBox(width: 14),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('PrivateLM',
                              style: GoogleFonts.inter(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                              controller.appVersion.value.isEmpty
                                  ? 'Version unavailable · by orailnoor'
                                  : 'v${controller.appVersion.value} · by orailnoor',
                              style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: Theme.of(context).hintColor)),
                        ]),
                  ]),
                ),
              ]),
              const SizedBox(height: 40),
            ],
          )),
    );
  }

  // ── Apple grouped card container ──
  Widget _appleGroupedCard(BuildContext context, bool isDark,
      {required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  // ── Apple-style list tile ──
  Widget _appleListTile(
    BuildContext context,
    bool isDark, {
    Widget? leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    bool showDivider = true,
    VoidCallback? onTap,
  }) {
    return Column(children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            if (leading != null) ...[leading, const SizedBox(width: 14)],
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  Text(title,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: isDark ? Colors.white : Colors.black)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: GoogleFonts.inter(
                            fontSize: 13, color: Theme.of(context).hintColor))
                  ],
                ])),
            if (trailing != null) trailing,
          ]),
        ),
      ),
      if (showDivider)
        Divider(
            height: 0.5,
            indent: leading != null ? 58 : 16,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06)),
    ]);
  }

  Widget _iconBox(Color color, IconData icon) {
    return Container(
        width: 30,
        height: 30,
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 17, color: Colors.white));
  }

  Widget _sectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Text(title,
          style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).hintColor)),
    );
  }

  String _localSubtitle() {
    final inf = Get.find<InferenceService>();
    final localImage = Get.find<LocalImageService>();
    if (inf.isModelLoaded.value) {
      return 'Active: ${inf.loadedModelName.value}';
    } else if (localImage.isModelLoaded.value) {
      return 'Active: ${localImage.loadedModelName.value}';
    }
    return 'No model loaded';
  }

  Widget _buildDeviceCard(BuildContext context, bool isDark) {
    return Obx(() {
      final device = Get.find<DeviceInfoService>();
      Color tierColor;
      IconData tierIcon;
      switch (device.deviceTier.value) {
        case 'low':
          tierColor = AppColors.error;
          tierIcon = Icons.battery_alert;
          break;
        case 'mid':
          tierColor = AppColors.warning;
          tierIcon = Icons.phone_android;
          break;
        case 'high':
          tierColor = AppColors.success;
          tierIcon = Icons.smartphone;
          break;
        case 'ultra':
          tierColor = AppColors.primary;
          tierIcon = Icons.rocket_launch;
          break;
        default:
          tierColor = Theme.of(context).hintColor;
          tierIcon = Icons.phone_android;
      }

      final soc = device.socFamily.value;
      final quantWarning = soc.quantWarning;

      return _appleGroupedCard(context, isDark, children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              _iconBox(tierColor, tierIcon),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(device.tierDescription,
                        style: GoogleFonts.inter(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                        'Available: ${device.availableRamGB.value.toStringAsFixed(1)}GB · Context: ${device.recommendedContextSize} · Tokens: ${device.recommendedMaxTokens}',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: Theme.of(context).hintColor)),
                  ])),
            ])),
        // SoC + quantization recommendation
        if (soc != platform_info.SocFamily.unknown) ...[
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              _iconBox(const Color(0xFF5856D6), Icons.memory_outlined),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(soc.displayName,
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text('Recommended: ${soc.recommendedQuant}',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: quantWarning != null
                                ? const Color(0xFFFF9500)
                                : Theme.of(context).hintColor)),
                  ],
                ),
              ),
            ]),
          ),
        ],
        // Warning banner for problematic SoCs
        if (quantWarning != null) ...[
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFF9500).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Color(0xFFFF9500)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(quantWarning,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFFFF9500),
                        fontWeight: FontWeight.w500,
                      )),
                ),
              ],
            ),
          ),
        ],
      ]);
    });
  }

  /// Master switch plus one row per tool.
  ///
  /// The per-tool rows only appear once the master switch is on, and they are
  /// what the prompt is built from — a tool the user unticked is never
  /// advertised to the model, so it cannot be called and then refused.
  ///
  /// The catalogue is read from [buildDefaultToolRegistry] with no filter, so a
  /// tool added there shows up here without touching this file.
  Widget _buildToolsCard(BuildContext context, bool isDark) {
    final enabled = controller.toolsEnabled.value;
    final accent = isDark ? const Color(0xFF0A84FF) : AppColors.primary;
    final catalogue = buildDefaultToolRegistry().all.toList();
    final on = controller.enabledTools;

    return _appleGroupedCard(context, isDark, children: [
      _appleListTile(
        context,
        isDark,
        leading: _iconBox(accent, Icons.handyman_rounded),
        title: 'Tools',
        subtitle: enabled
            ? '${on.length} of ${catalogue.length} enabled'
            : 'Off — the tool list is kept out of the prompt',
        trailing: enabled ? Icon(Icons.check, size: 18, color: accent) : null,
        showDivider: enabled,
        onTap: () => controller.setToolsEnabled(!enabled),
      ),
      if (enabled)
        for (var i = 0; i < catalogue.length; i++)
          _appleListTile(
            context,
            isDark,
            leading: _iconBox(
                catalogue[i].requiresNetwork ? AppColors.warning : accent,
                catalogue[i].requiresNetwork
                    ? Icons.public_rounded
                    : Icons.offline_bolt_rounded),
            title: catalogue[i].name,
            subtitle: catalogue[i].requiresNetwork
                ? 'Needs internet — ${catalogue[i].description}'
                : catalogue[i].description,
            trailing: on.contains(catalogue[i].name)
                ? Icon(Icons.check, size: 18, color: accent)
                : null,
            showDivider: i < catalogue.length - 1,
            onTap: () => controller.toggleTool(
                catalogue[i].name, !on.contains(catalogue[i].name)),
          ),
      if (enabled && on.contains('web_search'))
        _buildCustomSearchFields(context, isDark),
    ]);
  }

  /// Optional search endpoint for web_search.
  ///
  /// Only shown once web_search is ticked, since it configures nothing else.
  /// Left empty, search falls back to scraping Brave, then Startpage, then
  /// DuckDuckGo — which works but breaks whenever one of them redesigns. A URL
  /// here points at something with an actual contract: a SearXNG instance
  /// (no token, plain GET) or a service like Tavily (token, JSON POST).
  Widget _buildCustomSearchFields(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Optional. Empty means Brave → Startpage → DuckDuckGo.',
          style: GoogleFonts.inter(
              fontSize: 12, color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller.customSearchUrlController,
          style: GoogleFonts.inter(fontSize: 14),
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Custom search API URL',
            hintText: 'https://searx.example.org/search',
            suffixIcon: IconButton(
              icon: const Icon(Icons.check_circle_outline, size: 20),
              onPressed: () => controller
                  .setCustomSearchUrl(controller.customSearchUrlController.text),
            ),
          ),
          onSubmitted: controller.setCustomSearchUrl,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller.customSearchTokenController,
          style: GoogleFonts.inter(fontSize: 14),
          autocorrect: false,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Custom search API token',
            hintText: 'leave empty for SearXNG',
            suffixIcon: IconButton(
              icon: const Icon(Icons.check_circle_outline, size: 20),
              onPressed: () => controller.setCustomSearchToken(
                  controller.customSearchTokenController.text),
            ),
          ),
          onSubmitted: controller.setCustomSearchToken,
        ),
        const SizedBox(height: 6),
        Text(
          controller.customSearchUrl.value.isEmpty
              ? 'Using the scrape chain.'
              : 'Using ${controller.customSearchUrl.value}'
                  '${controller.customSearchToken.value.isEmpty ? " (GET, no auth)" : " (POST, bearer token)"}'
                  ' first, scrapes as fallback.',
          style: GoogleFonts.inter(
              fontSize: 11, color: Theme.of(context).hintColor),
        ),
      ]),
    );
  }

  Widget _buildThinkingCard(BuildContext context, bool isDark) {
    // Reasoning models take a literal `/think` / `/no_think` in the prompt.
    // Default is Auto — a model that never learned the token should not be sent
    // one on every turn.
    final modes = [
      (
        value: 'auto',
        title: 'Thinking: Auto',
        subtitle: "Send nothing — the model's own default",
        icon: Icons.auto_awesome_rounded
      ),
      (
        value: 'on',
        title: 'Thinking: On',
        subtitle: 'Ask for reasoning before the answer (/think)',
        icon: Icons.psychology_rounded
      ),
      (
        value: 'off',
        title: 'Thinking: Off',
        subtitle: 'Answer directly, no reasoning (/no_think)',
        icon: Icons.bolt_rounded
      ),
    ];
    return _appleGroupedCard(context, isDark, children: [
      for (var i = 0; i < modes.length; i++)
        _appleListTile(
          context,
          isDark,
          leading: _iconBox(
              isDark ? const Color(0xFF0A84FF) : AppColors.primary,
              modes[i].icon),
          title: modes[i].title,
          subtitle: modes[i].subtitle,
          trailing: controller.thinkingMode.value == modes[i].value
              ? Icon(Icons.check,
                  size: 18,
                  color: isDark ? const Color(0xFF0A84FF) : AppColors.primary)
              : null,
          showDivider: i < modes.length - 1,
          onTap: () => controller.setThinkingMode(modes[i].value),
        ),
    ]);
  }

  /// Read-only report on the NPU rung.
  ///
  /// Both halves have to be there — the dispatch library we ship and the
  /// vendor driver the device exposes — so the useful thing to show is what
  /// the probe actually found, not a yes/no. Probed on build rather than
  /// cached: it costs a directory listing plus a dlopen, and the answer can
  /// change between installs.
  Widget _buildNpuCard(BuildContext context, bool isDark) {
    return FutureBuilder<NpuStatus>(
      future: NpuStatus.probe(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        final subtitle = switch ((snapshot.connectionState, status)) {
          (ConnectionState.done, final s?) => s.toString(),
          (ConnectionState.done, null) => 'Probe failed: ${snapshot.error}',
          _ => 'Checking…',
        };
        return _appleGroupedCard(context, isDark, children: [
          _appleListTile(
            context,
            isDark,
            leading: _iconBox(
                status?.available == true
                    ? AppColors.success
                    : (isDark ? const Color(0xFF0A84FF) : AppColors.primary),
                Icons.memory_rounded),
            title: 'NPU',
            subtitle: subtitle,
            showDivider: false,
          ),
        ]);
      },
    );
  }

  Widget _buildLiteRtCard(BuildContext context, bool isDark) {
    final modes = [
      (
        value: 'auto_fast',
        title: 'Auto Fast',
        subtitle: 'Try GPU first, then CPU fallback',
        icon: Icons.auto_awesome_rounded
      ),
      (
        value: 'gpu_fast',
        title: 'GPU Fast',
        subtitle: 'Maximum speed, may crash on some devices',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU Safe',
        subtitle: 'Stable mode with lower speed',
        icon: Icons.shield_outlined
      ),
    ];
    return _appleGroupedCard(context, isDark, children: [
      for (var i = 0; i < modes.length; i++)
        _appleListTile(
          context,
          isDark,
          leading: _iconBox(
              isDark ? const Color(0xFF0A84FF) : AppColors.primary,
              modes[i].icon),
          title: modes[i].title,
          subtitle: modes[i].subtitle,
          trailing: controller.liteRtPerformanceMode.value == modes[i].value
              ? Icon(Icons.check,
                  size: 18,
                  color: isDark ? const Color(0xFF0A84FF) : AppColors.primary)
              : null,
          showDivider: i < modes.length - 1,
          onTap: () => controller.setLiteRtPerformanceMode(modes[i].value),
        ),
    ]);
  }

  Widget _buildModelParametersCard(BuildContext context, bool isDark) {
    return _appleGroupedCard(context, isDark, children: [
      _modelParameterSlider(
        context,
        isDark,
        label: 'Temperature',
        value: controller.temperature.value,
        min: 0.0,
        max: 2.0,
        divisions: 20,
        safeMax: 1.0,
        onChanged: (v) => controller.setTemperature(v),
        icon: Icons.thermostat_rounded,
        warning: 'High temperature = unpredictable output!',
      ),
      _parameterDivider(isDark),
      _modelParameterSlider(
        context,
        isDark,
        label: 'Max Tokens',
        value: controller.maxTokens.value.toDouble(),
        min: 64,
        max: 4096,
        divisions: 63,
        safeMax: Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
        onChanged: (v) => controller.setMaxTokens(v.toInt()),
        displayValue: controller.maxTokens.value.toString(),
        icon: Icons.tag_rounded,
        warning: 'Your phone may crash with this value!',
        onTapValue: () {
          SettingsController.showManualEntryDialog(
            context: context,
            field: 'maxTokens',
            label: 'Max Tokens',
            currentValue: controller.maxTokens.value,
            min: 64,
            max: SettingsController.maxManualMaxTokens,
            warningThreshold: SettingsController.memoryWarningThreshold,
            warningMessage:
                'Warning: values above 8192 may cause your device to run out of memory. Continue only if your device has sufficient RAM.',
            controller: controller,
            onApplied: () {},
          );
        },
      ),
      _parameterDivider(isDark),
      (() {
        final inference = Get.find<InferenceService>();
        final savedRuntime = Get.find<HiveService>()
                .getSetting<String>(AppConstants.keyLocalModelRuntime) ??
            '';
        final isLiteRtActive = (inference.isModelLoaded.value &&
                inference.loadedModelRuntime.value == 'litert') ||
            (!inference.isModelLoaded.value &&
                savedRuntime.toLowerCase() == 'litert');
        final saved = controller.contextSize.value.toDouble();
        // LiteRT caps hard at 4096 (driver OOM). For llama the slider tops at
        // 8192, but a manually entered value above that is honored, not clamped.
        final maxContext =
            isLiteRtActive ? 4096.0 : (saved > 8192.0 ? saved : 8192.0);
        final divisions = isLiteRtActive ? 7 : (maxContext ~/ 512) - 1;
        final currentValue = saved.clamp(512.0, maxContext);

        if (isLiteRtActive && currentValue != saved) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.setContextSize(currentValue.toInt());
          });
        }

        return _modelParameterSlider(
          context,
          isDark,
          label: 'Context Size',
          value: currentValue,
          min: 512,
          max: maxContext,
          divisions: divisions,
          safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
          onChanged: (v) => controller.setContextSize(v.toInt()),
          displayValue: currentValue.toInt().toString(),
          icon: Icons.memory_rounded,
          warning: isLiteRtActive
              ? 'Context capped at 4096 to prevent driver memory crash for LiteRT models.'
              : 'Context this large will eat all your RAM!',
          onTapValue: () {
            SettingsController.showManualEntryDialog(
              context: context,
              field: 'contextSize',
              label: 'Context Size',
              currentValue: controller.contextSize.value,
              min: 512,
              max: SettingsController.maxManualContextSize,
              warningThreshold: SettingsController.memoryWarningThreshold,
              warningMessage:
                  'Warning: values above 8192 may cause your device to run out of memory. Continue only if your device has sufficient RAM.',
              controller: controller,
              onApplied: () {},
            );
          },
        );
      })(),
    ]);
  }

  Widget _buildImageGenerationCard(BuildContext context, bool isDark) {
    final stepsValue = controller.imageSteps.value.toDouble();
    const safeMax = 8.0;
    final isOver = stepsValue > safeMax;
    final accent = isOver
        ? AppColors.warning
        : (isDark ? const Color(0xFF0A84FF) : AppColors.primary);
    final selectedBackend = controller.imageGenBackend.value;
    final gpuBackend = controller.recommendedImageGpuBackend();
    final gpuAvailable = gpuBackend != Backend.cpu;

    return _appleGroupedCard(context, isDark, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.image_rounded, size: 16, color: accent),
            const SizedBox(width: 8),
            Text('Image Gen Steps',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w400)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(controller.imageSteps.value.toString(),
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color: accent,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Recommended max: 8',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Theme.of(context).hintColor))),
          Slider(
              value: stepsValue.clamp(1, 20),
              min: 1,
              max: 20,
              divisions: 19,
              activeColor: accent,
              onChanged: (v) => controller.setImageSteps(v.toInt())),
          if (isOver)
            Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 14, color: accent),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(
                          'More steps = better quality but MUCH slower!',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: accent,
                              fontWeight: FontWeight.w400))),
                ])),
        ]),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.photo_size_select_large_rounded,
                size: 16,
                color: isDark ? const Color(0xFF0A84FF) : AppColors.primary),
            const SizedBox(width: 8),
            Text('Image Size',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w400)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: (isDark ? const Color(0xFF0A84FF) : AppColors.primary)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                  controller.imageGenSize.value == 0
                      ? 'Auto'
                      : '${controller.imageGenSize.value}px',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color:
                          isDark ? const Color(0xFF0A84FF) : AppColors.primary,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Text(
                  'Auto recommended. Bigger size = better detail, but much slower and more memory use.',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Theme.of(context).hintColor))),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const [
                (value: 0, label: 'Auto'),
                (value: 256, label: '256'),
                (value: 320, label: '320'),
                (value: 384, label: '384'),
                (value: 512, label: '512'),
              ])
                ChoiceChip(
                  label: Text(option.label),
                  selected: controller.imageGenSize.value == option.value,
                  onSelected: (_) => controller.setImageGenSize(option.value),
                  visualDensity: VisualDensity.compact,
                  labelStyle: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: controller.imageGenSize.value == option.value
                        ? Colors.white
                        : Theme.of(context).hintColor,
                  ),
                  selectedColor:
                      isDark ? const Color(0xFF0A84FF) : AppColors.primary,
                  backgroundColor: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  side: BorderSide(
                    color: controller.imageGenSize.value == option.value
                        ? Colors.transparent
                        : Theme.of(context).dividerColor.withValues(alpha: 0.3),
                  ),
                  showCheckmark: false,
                ),
            ],
          ),
          if (controller.imageGenSize.value >= 512)
            Container(
                margin: const EdgeInsets.only(top: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 14, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(
                          '512 gives more detail but can be MUCH slower, heat the phone, and may fail on some devices.',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.warning,
                              fontWeight: FontWeight.w400))),
                ])),
        ]),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.shield_outlined,
                size: 16,
                color: isDark ? const Color(0xFF0A84FF) : AppColors.primary),
            const SizedBox(width: 8),
            Text('GPU Safety',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w400)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: (isDark ? const Color(0xFF0A84FF) : AppColors.primary)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                  controller.imageGenGpuGuardMb.value <= 0
                      ? 'Off'
                      : '${controller.imageGenGpuGuardMb.value} MB',
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color:
                          isDark ? const Color(0xFF0A84FF) : AppColors.primary,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Models at or above this size use CPU. Smaller models can use GPU Experimental.',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Theme.of(context).hintColor))),
          Slider(
              value:
                  controller.imageGenGpuGuardMb.value.toDouble().clamp(0, 4096),
              min: 0,
              max: 4096,
              divisions: 16,
              activeColor: isDark ? const Color(0xFF0A84FF) : AppColors.primary,
              onChanged: (v) => controller.setImageGenGpuGuardMb(v.toInt())),
          if (controller.imageGenGpuGuardMb.value <= 0 ||
              controller.imageGenGpuGuardMb.value >= 2048)
            Container(
                margin: const EdgeInsets.only(top: 2, bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 14, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(
                          controller.imageGenGpuGuardMb.value <= 0
                              ? 'GPU Safety is off. Large models may crash or freeze on GPU.'
                              : 'High GPU Safety allows larger models on GPU and may crash, freeze, or overheat some phones.',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.warning,
                              fontWeight: FontWeight.w400))),
                ])),
        ]),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconBox(
                isDark ? const Color(0xFF0A84FF) : AppColors.primary,
                selectedBackend == Backend.cpu
                    ? Icons.memory_rounded
                    : Icons.bolt_rounded),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Image Backend',
                        style: GoogleFonts.inter(
                            fontSize: 15, fontWeight: FontWeight.w400)),
                    const SizedBox(height: 3),
                    Text(controller.imageGpuLabel(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: Theme.of(context).hintColor)),
                  ]),
            ),
          ]),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              segments: [
                const ButtonSegment(
                    value: false,
                    icon: Icon(Icons.memory_rounded, size: 16),
                    label: Text('CPU')),
                ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(
                      'GPU',
                      style: TextStyle(
                        color: selectedBackend == Backend.cpu
                            ? const Color(0xFFFF6B6B)
                            : Colors.white,
                      ),
                    )),
              ],
              selected: {selectedBackend != Backend.cpu},
              onSelectionChanged: (values) {
                final useGpu = values.first;
                if (useGpu && !gpuAvailable) return;
                controller.setImageBackendMode(useGpu);
              },
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll(GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w500)),
              ),
            ),
          ),
          if (selectedBackend != Backend.cpu) ...[
            const SizedBox(height: 6),
            Text('GPU is experimental and only used below GPU Safety size.',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: const Color(0xFFFF6B6B),
                    fontWeight: FontWeight.w500)),
          ],
        ]),
      ),
    ]);
  }

  Widget _buildFontSizeCard(BuildContext context, bool isDark) {
    const min = 0.8;
    const max = 1.4;
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);

    String scaleLabel(double v) {
      if (v <= 0.85) return 'XS';
      if (v <= 0.95) return 'Small';
      if (v <= 1.05) return 'Recommended';
      if (v <= 1.15) return 'Large';
      if (v <= 1.25) return 'XL';
      return 'XXL';
    }

    return _appleGroupedCard(context, isDark, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.format_size_rounded, size: 16, color: accent),
            const SizedBox(width: 8),
            Text('Font Size',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w400)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(scaleLabel(controller.fontScale.value),
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color: accent,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('Small (0.95x) is the default size',
              style: GoogleFonts.inter(
                  fontSize: 12, color: Theme.of(context).hintColor)),
          Slider(
            value: controller.fontScale.value.clamp(min, max),
            min: min,
            max: max,
            divisions: 12,
            activeColor: accent,
            onChanged: (v) => controller.setFontScale(v),
          ),
          // Scale markers
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('XS',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: Theme.of(context).hintColor)),
                Text('Small',
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        color: controller.fontScale.value >= 0.9 &&
                                controller.fontScale.value <= 0.95
                            ? accent
                            : Theme.of(context).hintColor,
                        fontWeight: controller.fontScale.value >= 0.9 &&
                                controller.fontScale.value <= 0.95
                            ? FontWeight.w600
                            : FontWeight.w400)),
                Text('Large',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _parameterDivider(bool isDark) {
    return Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.06),
    );
  }

  Widget _modelParameterSlider(
    BuildContext context,
    bool isDark, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required IconData icon,
    required String warning,
    String? displayValue,
    VoidCallback? onTapValue,
  }) {
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final accent = isOver
        ? Color.lerp(AppColors.warning, AppColors.error, danger)!
        : (isDark ? const Color(0xFF0A84FF) : AppColors.primary);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 8),
          Text(label,
              style:
                  GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w400)),
          GestureDetector(
            onTap: onTapValue,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(displayValue ?? value.toStringAsFixed(2),
                  style: GoogleFonts.inter(
                      fontSize: 13, color: accent, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        if (safeMax < max)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Theme.of(context).hintColor))),
        Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: accent,
            onChanged: (v) {
              if (v > safeMax && value <= safeMax) {
                HapticFeedback.heavyImpact();
                Get.snackbar('âš ï¸ Warning', warning,
                    snackPosition: SnackPosition.BOTTOM,
                    backgroundColor: AppColors.error.withValues(alpha: 0.9),
                    colorText: Colors.white,
                    duration: const Duration(seconds: 3),
                    margin: const EdgeInsets.all(12));
              } else if (v > safeMax) {
                HapticFeedback.mediumImpact();
              }
              onChanged(v);
            }),
        if (isOver)
          Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: accent),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(warning,
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: accent,
                            fontWeight: FontWeight.w400))),
              ])),
      ]),
    );
  }

  Widget _buildSlider(
    BuildContext context,
    bool isDark, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required IconData icon,
    required String warning,
    String? displayValue,
  }) {
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final accent = isOver
        ? Color.lerp(AppColors.warning, AppColors.error, danger)!
        : (isDark ? const Color(0xFF0A84FF) : AppColors.primary);

    return _appleGroupedCard(context, isDark, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w400)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(displayValue ?? value.toStringAsFixed(2),
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        color: accent,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            if (safeMax < max)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Theme.of(context).hintColor))),
            Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: accent,
                onChanged: (v) {
                  if (v > safeMax && value <= safeMax) {
                    HapticFeedback.heavyImpact();
                    Get.snackbar('⚠️ Warning', warning,
                        snackPosition: SnackPosition.BOTTOM,
                        backgroundColor: AppColors.error.withValues(alpha: 0.9),
                        colorText: Colors.white,
                        duration: const Duration(seconds: 3),
                        margin: const EdgeInsets.all(12));
                  } else if (v > safeMax) {
                    HapticFeedback.mediumImpact();
                  }
                  onChanged(v);
                }),
            if (isOver)
              Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(warning,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: accent,
                                fontWeight: FontWeight.w400))),
                  ])),
          ])),
    ]);
  }

  String _themeModeName(ThemeMode m) => m == ThemeMode.light
      ? 'Light'
      : m == ThemeMode.dark
          ? 'Dark'
          : 'System Default';
  IconData _themeModeIcon(ThemeMode m) => m == ThemeMode.light
      ? Icons.wb_sunny_outlined
      : m == ThemeMode.dark
          ? Icons.dark_mode_outlined
          : Icons.brightness_auto_outlined;
}
