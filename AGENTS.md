# Repository Guidelines

## Project Overview

PrivateLM is a cross-platform AI chat client built with Flutter (Dart). It unifies local on-device LLM inference (Android/iOS via llama.cpp / LiteRT-LM / stable-diffusion.cpp) with cloud API access (OpenAI, Anthropic, Google Gemini, Kimi, OpenRouter, DeepSeek, NVIDIA, Stability, and custom OpenAI-compatible endpoints). All conversations, tasks, and settings persist locally via Hive — nothing leaves the device unless cloud mode is explicitly selected.

- **Framework:** Flutter 3.x (Dart SDK >3.3.0)
- **State Management:** GetX (service locator + reactive `Rx` observables)
- **Local Storage:** Hive (4 boxes: sessions, messages, tasks, settings)
- **Platforms:** Android, iOS, Web (local inference is Android/iOS only; web is cloud-only)

## Architecture & Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / TaskView / ModelView / ServerView /           │
│   SettingsView / LogView                                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · TaskController · ModelController         │
│   SettingsController · HomeController · ServerController    │
│   CloudModelController                                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services (GetxService)                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (9 cloud APIs)  │  │ (model dl)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ExecutionSvc │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (CMD: exec) │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │LocalImageService│  │  AppLogService  │  │CrashReport  │ │
│  │  (StableDiffus) │  │  (logging)      │  │ (Crashtly)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              Platform-Specific Conditional Imports           │
│  inference_android.dart (llama_flutter_android + litert)    │
│  inference_stub.dart  (web — no local inference)            │
│  download_native.dart / download_web.dart                   │
│  device_info_native.dart / device_info_web.dart              │
│  openai_server_service_io.dart / _stub.dart                 │
└─────────────────────────────────────────────────────────────┘
```

**Key architectural decisions:**

- **Conditional imports** (`dart.library.html` / `dart.library.io`) gate platform-specific behavior. The same Dart API class (`InferenceEngine`, `InferenceService`, `CloudService`, etc.) is aliased through import prefixes so callers don't need `kIsWeb` checks everywhere.
- **Services are registered globally** via `Get.putAsync()` in `main.dart` before `runApp()`. Controllers are lazily injected per route via `BindingsBuilder` in `GetPage` definitions.
- **Model loading** is mediated by `InferenceService` which wraps `InferenceEngine` (platform-specific). The engine supports two native runtimes: `llama` (GGUF via `llama_flutter_android`) and `litert` (LiteRT-LM `.litertlm`). The service reads settings from Hive (context size, temperature, max tokens, LiteRT performance mode) and auto-configures them on first launch based on device RAM tier.
- **Token streaming** flows from the engine's `onToken` callback through `InferenceService.generate()` → `ChatController` → `ChatView`. For LiteRT, tokens are buffered (60ms flush) to reduce UI rebuilds; for llama runtime, tokens pass through directly.
- **Image generation** uses a separate isolate (`SdIsolateProcessor`) with FFI bindings to stable-diffusion.cpp. The `LocalImageService` orchestrates this, using `Backend` and `QuantizationType` enums from `sd_ffi_bindings.dart`.
- **CMD: execution** is parsed by `ExecutionService` from LLM output — the first line must be exactly `CMD: <adb_command>`. Command execution is currently disabled (stub returns an informational string).

## Key Directories

| Directory | Purpose |
|---|---|
| `lib/main.dart` | Entry point. Registers Hive, services, controllers, sets up error/crash handling, applies system UI. |
| `lib/controllers/` | GetX controllers: `chat_controller.dart`, `cloud_model_controller.dart`, `home_controller.dart`, `model_controller.dart`, `server_controller.dart`, `settings_controller.dart`, `task_controller.dart` |
| `lib/services/` | GetX services: `inference_service.dart`, `cloud_service.dart`, `hive_service.dart`, `download_service.dart`, `device_info_service.dart`, `local_image_service.dart`, `execution_service.dart`, `app_log_service.dart`, `crash_reporting_service.dart`, `document_extractor_service.dart`, `image_generation_notification_service.dart`, plus platform-specific files (`inference_android.dart`, `inference_stub.dart`, `download_native.dart`, `download_web.dart`, `device_info_native.dart`, `device_info_web.dart`) |
| `lib/ffi/` | FFI bindings for native stable-diffusion.cpp: `sd_ffi_bindings.dart` (enums, callbacks, typedefs, `SdFfiBindings` class) |
| `lib/models/` | Data models: `ai_model.dart`, `chat_message.dart`, `chat_session.dart`, `task_model.dart` |
| `lib/core/` | Constants (`constants.dart`), routes (`routes.dart`), theme (`theme.dart`), colors (`colors.dart`) |
| `lib/views/` | UI screens: `chat_view.dart`, `home_view.dart`, `task_view.dart`, `model_view.dart`, `server_view.dart`, `settings_view.dart`, `log_view.dart` |
| `lib/widgets/` | Reusable UI: `chat_bubble.dart`, `attachment_preview.dart`, `image_viewer.dart`, `thought_disclosure.dart`, `typing_indicator.dart` |
| `lib/utils/` | Utilities: `thought_parser.dart` (parses ` thinking ` tags from LLM output) |
| `local_plugins/` | Local Flutter plugins (path dependencies): `llama_flutter_android`, `sd_flutter_android`, `flutter_litert_lm` |
| `test/` | Tests: `ai_model_test.dart` (unit test for `AiModel.hasVisionMarker`) |
| `android/` | Native Android project (Gradle Kotlin DSL, minSdk 28, Kotlin, Java 17) |
| `ios/` | Native iOS project |
| `web/` | Web target (`index.html`, `manifest.json`, icons) |
| `assets/` | Static assets (icons, `webgpu_engine.html`) |

## Development Commands

### Install dependencies
```bash
flutter pub get
```

### Run in debug mode
```bash
# Default (hot reload)
flutter run

# Specific platform
flutter run -d android
flutter run -d ios --release
flutter run -d chrome
```

### Build for release
```bash
# Android (per-ABI split for smaller APKs)
flutter build apk --release --split-per-abi

# iOS (requires CocoaPods)
cd ios && pod install && cd ..
flutter build ios --release

# Web (deployed to Firebase Hosting)
flutter build web --release
```

### Analyze and lint
```bash
flutter analyze             # All linting rules from analysis_options.yaml
dart format lib/            # Format Dart code
```

### Run tests
```bash
flutter test                    # Run all tests
flutter test test/ai_model_test.dart  # Specific test file
```

### Deploy
```bash
# Web to Firebase Hosting
flutter build web --release
firebase deploy

# Android release requires signing key — see Build Configuration section below
```

### Clean
```bash
flutter clean
```

## Code Conventions & Common Patterns

### GetX State Management
- Services extend `GetxService` and are registered with `Get.putAsync(() => Service().init())` in `main.dart`.
- Controllers extend `GetxController` and are injected via `BindingsBuilder` in route definitions.
- Dependencies are resolved with `Get.find<Service>()` — never `new` a service directly.
- Reactive state uses `.obs` (RxBool, RxString, RxInt, RxDouble, RxList, Rxn). Always observe in UI with `Obx(() => …)`.

### Conditional Imports (Platform Abstraction)
The standard pattern for platform-specific code:

```dart
// In the common file
import 'inference_android.dart' if (dart.library.html) 'inference_stub.dart'
    as platform;

// Usage — caller doesn't know which platform implementation is active
final engine = platform.InferenceEngine();
```

Files that use this pattern:
- `inference_android.dart` / `inference_stub.dart` — local inference engine
- `download_native.dart` / `download_web.dart` — model downloads
- `device_info_native.dart` / `device_info_web.dart` — device capability detection
- `openai_server_service_io.dart` / `openai_server_service_stub.dart` — local OpenAI-compatible server

### Hive Persistence
- `HiveService` opens 4 boxes in `init()`: `chat_sessions`, `chat_messages`, `tasks`, `settings`.
- Settings are read with typed `getSetting<T>(key)` and written with `setSetting(key, value)`.
- All setting keys are `static const String` in `AppConstants` (`lib/core/constants.dart`).
- Models (`AiModel`, `ChatMessage`, `ChatSession`, `TaskModel`) implement `toMap()` / `fromMap()` for Hive storage.

### Observability Conventions
- `InferenceService` exposes many `.obs` fields: `isModelLoaded`, `isGenerating`, `tokenCount`, `tokensPerSecond`, `contextTokensUsed`, `contextTokensTotal`, `gpuName`, `gpuLayersUsed`, `isGpuAccelerated`, `loadedModelRuntime`, `loadedBackend`, etc.
- `LocalImageService` exposes: `isModelLoaded`, `isLoadingModel`, `isGenerating`, `progress`, `loadedModelName`, `gpuVendor`, `isUsingGpu`, `currentBackend`, `currentQuantization`.
- `DownloadService` exposes: `activeDownloads` (RxMap), `isDownloadingAny`, `supportsDownload`, `modelsDir`.

### Error Handling
- `main()` wraps `runApp` in `runZonedGuarded` to catch uncaught async errors.
- `FlutterError.onError` and `PlatformDispatcher.instance.onError` route to both `AppLogService` and `CrashReportingService`.
- `AppLogService` buffers pre-service prints, caps at 200 entries, logs warnings/errors to Crashlytics.
- Service methods return error strings (e.g., `'ERROR: No API key configured for $_provider'`) rather than throwing — the UI displays these verbatim to the user.

### Async Patterns
- Long-running operations (model loading, downloads, generation) set loading flags before starting and in `finally`/`catch` clear them on failure.
- `compute()` from `flutter/foundation` is used for CPU-intensive background isolate work (e.g., `_resizeVisionImageBytes` in `chat_controller.dart`).
- Image generation runs in a background isolate (`SdIsolateProcessor`) communicating via `SendPort`.

### Naming Conventions
- Controllers: `*Controller` (e.g., `ChatController`, `ModelController`)
- Services: `*Service` (e.g., `InferenceService`, `CloudService`)
- Models: no suffix (e.g., `ChatMessage`, `TaskModel`, `AiModel`)
- Constants class: `AppConstants` (utility class with private constructor `AppConstants._()`)
- Observability fields: `final x = false.obs`, `final name = ''.obs`
- Private fields prefixed with `_`

## Important Files

| File | Purpose |
|---|---|
| `lib/main.dart` | App bootstrap — service registration, Hive init, error handling, theme setup |
| `lib/core/constants.dart` | `AppConstants`: box names, setting keys, default values, system prompts, cloud endpoints, available model list, cloud provider IDs |
| `lib/core/routes.dart` | GetX router: `/`, `/chat`, `/task` with lazy controller injection |
| `lib/core/theme.dart` | `AppTheme` — dark/light `ThemeData` with dynamic color scheme |
| `lib/core/colors.dart` | `AppColors` — Apple system color palette, bubble colors, semantic colors |
| `lib/services/inference_service.dart` | Cross-platform local inference — wraps `InferenceEngine`, manages model loading, token streaming, context info |
| `lib/services/cloud_service.dart` | 9-provider cloud API client — normalizes OpenAI, Anthropic, Google, Kimi, Stability, NVIDIA, OpenRouter, DeepSeek, custom |
| `lib/services/hive_service.dart` | 4-box persistence layer with typed getters/setters |
| `lib/services/download_service.dart` | GGUF/safetensors model download with progress, pause, Android DownloadManager integration |
| `lib/services/local_image_service.dart` | Stable Diffusion image generation via FFI + isolate |
| `lib/ffi/sd_ffi_bindings.dart` | FFI bindings to stable-diffusion.cpp — enums, callbacks, native typedefs, `SdFfiBindings` singleton |
| `lib/models/ai_model.dart` | `AiModel` data class with runtime detection (`llama`/`litert`/`sd`), vision detection, copyWith |
| `lib/controllers/chat_controller.dart` | Chat session management, message handling, image attachment, speech-to-text, CMD execution, token streaming |
| `lib/controllers/model_controller.dart` | Model download/load/unload, quantization selection, SoC-specific recommendations, backend preference |
| `lib/controllers/settings_controller.dart` | Theme mode, font scale, inference mode, cloud API keys/models, LiteRT options, server settings |
| `pubspec.yaml` | Dependencies, assets, local plugin path overrides |
| `analysis_options.yaml` | Linting rules (extends `flutter_lints/flutter.yaml`, enables const constructors) |

## Runtime / Tooling Preferences

- **SDK:** Dart SDK >=3.10.3 <4.0.0 (required by `sd_flutter_android` plugin); Flutter 3.24.0+; beta channel used for newer Dart features
- **Package Manager:** `flutter pub` (no alternative)
- **Local Plugins:** Three path-based plugins in `local_plugins/`:
  - `llama_flutter_android` — llama.cpp Flutter plugin (GGUF inference, Pigeon-generated bridge, Vulkan GPU detection)
  - `sd_flutter_android` — stable-diffusion.cpp Flutter plugin (FFI-based image generation)
  - `flutter_litert_lm` — LiteRT-LM plugin (Google's on-device inference with CPU/GPU/NPU acceleration)
- **Dart FFI:** Used for stable-diffusion.cpp bindings (`sd_ffi_bindings.dart`). Isolate-based processor for image generation.
- **Conditional compilation:** `dart.library.html` vs `dart.library.io` for platform-specific implementations
- **Android minSdk:** 28 (Android 8.0); targetSdk follows Flutter default; NDK r27+ for 16KB page support
- **Java/Kotlin:** JDK 17; Kotlin for Android native code
- **IDE:** VS Code with Dart/Flutter extensions (`.vscode/launch.json` has configs for main app and local plugins)
- **Key ignored files:** `google-services.json`, `GoogleService-Info.plist`, `firebase_options.dart`, `lib/firebase_options.dart`, `key.properties`, `android/key.properties` — these are generated locally and never committed

### Local Plugin Development
The launch.json includes configurations for running each local plugin individually:
- `local_plugins/flutter_litert_lm/` — `flutter run` from this directory
- `local_plugins/llama_flutter_android/` — `flutter run` from this directory
- `local_plugins/sd_flutter_android/` — `flutter run` from this directory

## Testing & QA

- **Framework:** `flutter_test` (standard Flutter test framework)
- **Test command:** `flutter test` (runs all tests in `test/`)
- **Test file:** `test/ai_model_test.dart` — unit tests for `AiModel.hasVisionMarker()` covering vision model detection edge cases
- **Linting:** `flutter analyze` — uses `flutter_lints` package with `analysis_options.yaml` extending `package:flutter_lints/flutter.yaml`
- **Lint rules:** `prefer_const_constructors`, `prefer_const_declarations` enabled; `avoid_print` disabled (allows print for debugging)
- **Format:** `dart format lib/` for code formatting
- **No CI/CD config** found in repository (no `.github/workflows/`, no `.gitlab-ci.yml`, no `fastlane/`). Release builds are performed manually or via GitHub Actions not committed to the repo.
- **Firebase:** Project `privatelm-20260518141323` configured in `.firebaserc`. Web hosting deploys to `build/web/` (see `firebase.json`). Crashlytics is integrated but Firebase initialization is currently commented out in `main.dart`.

## Build Configuration

### Android Release Signing
Release APKs require a signing key. Copy the example and fill in values:
```bash
cp android/key.properties.example android/key.properties
```
The `build.gradle.kts` enforces this: release builds without a keystore are rejected unless `PRIVATELM_ALLOW_DEBUG_RELEASE_SIGNING=true`. The signing key must never be rotated between releases (APKs won't upgrade otherwise). The build number in `pubspec.yaml` must increment with each release.

### Web Deployment
```bash
flutter build web --release
firebase deploy
```
Firebase hosting serves from `build/web/` with SPA rewrites to `/index.html`.

### iOS
```bash
cd ios && pod install && cd ..
flutter build ios --release
```
iPhone support is experimental; iPad is the recommended iOS target due to RAM requirements for local models.

## Child DOX Index

This project is the top-level DOX root. Child AGENTS.md files should be created under:
- `local_plugins/` — Flutter plugin development conventions
- `android/` — Android native build and signing rules
- `ios/` — iOS native build rules
- `test/` — Test conventions and patterns