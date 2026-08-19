#include <jni.h>
#include <string>
#include <vector>
#include <atomic>
#include <ctime>
#include <cstring>
#include <cstdarg>
#include <fstream>
#include <chrono>
#include <mutex>
#include <deque>
#include <android/log.h>
#include "llama.cpp/include/llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#define LOG_TAG "LlamaJNI"

static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static const llama_vocab* g_vocab = nullptr;
static llama_sampler* g_sampler = nullptr;
static std::atomic<bool> g_stop_flag{false};
// Serialises generation against teardown.
//
// nativeGenerate blocks inside llama_decode for as long as a prefill takes,
// and the Kotlin side frees the model from the main thread when the Flutter
// engine detaches. Coroutine cancellation cannot interrupt a JNI call that is
// already running, so without this the free ran underneath a live decode:
// "Scudo ERROR: invalid chunk state when deallocating" in llama_free.
static std::mutex g_ctx_mutex;
static int g_n_past = 0;  // Track the number of tokens already in KV cache
static std::mutex g_load_log_mutex;
static std::string g_load_error;
static bool g_capture_load_error = false;

// Multimodal state. g_mtmd holds the projector (the mmproj GGUF); it is a
// separate model from g_model and is loaded on its own.
static mtmd_context* g_mtmd = nullptr;

// Media queued by nativeSetMedia and consumed by the next nativeGenerate.
// Passing the paths through a global rather than widening nativeGenerate's
// already 18-argument signature -- the generation entry point is stateful
// anyway (g_model, g_ctx, g_n_past), so this follows the file's own grain.
static std::vector<std::string> g_pending_media;

// Everything ggml and llama.cpp print, kept for the Dart side to drain.
//
// The in-app log only ever saw Dart `print()`, so the layer that actually
// explains a bad load -- backend selection, layer offload, buffer allocation,
// Vulkan errors -- was invisible without a cable. This ring makes it
// reachable. It is polled rather than pushed because androidLlamaLog runs on
// llama.cpp worker threads, and attaching those to the JVM to call back into
// Dart mid-inference is a far worse trade than a 1s poll.
static std::mutex g_log_ring_mutex;
static std::deque<std::string> g_log_ring;
static constexpr size_t kLogRingMax = 600;

static void pushLogRing(ggml_log_level level, const char* text) {
    const char* tag = level >= GGML_LOG_LEVEL_ERROR
        ? "ERROR"
        : level == GGML_LOG_LEVEL_WARN ? "WARNING" : "INFO";
    std::string line;
    line.reserve(16 + strlen(text));
    // GGML_LOG_LEVEL_CONT continues the previous line, so glue it on instead
    // of emitting a fragment with its own level tag.
    std::lock_guard<std::mutex> lock(g_log_ring_mutex);
    if (level == GGML_LOG_LEVEL_CONT && !g_log_ring.empty()) {
        g_log_ring.back().append(text);
    } else {
        line.append(tag).append("\t").append(text);
        g_log_ring.push_back(std::move(line));
    }
    std::string& last = g_log_ring.back();
    while (!last.empty() && (last.back() == '\n' || last.back() == '\r')) {
        last.pop_back();
    }
    // A bare newline leaves nothing but the tag and its separator: drop it
    // rather than pad the log with blank lines.
    const size_t tab = last.find('\t');
    if (tab == std::string::npos || tab + 1 >= last.size()) {
        g_log_ring.pop_back();
    }
    while (g_log_ring.size() > kLogRingMax) g_log_ring.pop_front();
}

// This wrapper's own messages -- GPU detection, model and projector paths,
// load outcome -- used to exist only in logcat, which is exactly the set the
// in-app log most needs. Route them through the ring as well.
static void logRingf(ggml_log_level level, int priority, const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    __android_log_write(priority, LOG_TAG, buf);
    pushLogRing(level, buf);
}

#define LOGI(...) logRingf(GGML_LOG_LEVEL_INFO, ANDROID_LOG_INFO, __VA_ARGS__)
#define LOGE(...) logRingf(GGML_LOG_LEVEL_ERROR, ANDROID_LOG_ERROR, __VA_ARGS__)

static void androidLlamaLog(ggml_log_level level, const char* text, void*) {
    if (!text) return;
    pushLogRing(level, text);

    const int priority = level >= GGML_LOG_LEVEL_ERROR
        ? ANDROID_LOG_ERROR
        : level == GGML_LOG_LEVEL_WARN
            ? ANDROID_LOG_WARN
            : level == GGML_LOG_LEVEL_DEBUG
                ? ANDROID_LOG_DEBUG
                : ANDROID_LOG_INFO;
    __android_log_write(priority, LOG_TAG, text);

    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    if (!g_capture_load_error) return;
    if (level == GGML_LOG_LEVEL_ERROR) {
        g_load_error.assign(text);
    } else if (level == GGML_LOG_LEVEL_CONT && !g_load_error.empty()) {
        g_load_error.append(text);
    }
    if (g_load_error.size() > 4096) {
        g_load_error.erase(0, g_load_error.size() - 4096);
    }
}

static std::string consumeLoadError() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    g_capture_load_error = false;
    while (!g_load_error.empty() &&
           (g_load_error.back() == '\n' || g_load_error.back() == '\r')) {
        g_load_error.pop_back();
    }
    return g_load_error;
}

static void throwLoadError(JNIEnv* env, const std::string& message) {
    LOGE("%s", message.c_str());
    jclass exception = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(exception, message.c_str());
}

// Helper function to validate UTF-8 strings
static bool isValidUTF8(const char* str, size_t len) {
    if (!str) return false;
    
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    
    while (i < len) {
        unsigned char c = bytes[i];
        
        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            i++;
            continue;
        }
        
        // Multi-byte sequence start (110xxxxx, 1110xxxx, or 11110xxx)
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2; // 110xxxxx
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3; // 1110xxxx
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4; // 11110xxx
        } else {
            // Invalid first byte
            return false;
        }
        
        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            return false;
        }
        
        // Check continuation bytes (10xxxxxx)
        for (int j = 1; j < num_bytes; j++) {
            if ((bytes[i + j] & 0xC0) != 0x80) {
                return false;
            }
        }
        
        // Check for overlong encodings and invalid code points
        if (num_bytes == 2) {
            // Overlong encoding of ASCII character
            if ((c & 0x1E) == 0) return false;
        } else if (num_bytes == 3) {
            // Invalid surrogate halves (U+D800-U+DFFF)
            if (c == 0xED && (bytes[i + 1] & 0x20) == 0x20) return false;
            // Overlong encoding
            if (c == 0xE0 && (bytes[i + 1] & 0x20) == 0) return false;
        } else if (num_bytes == 4) {
            // Out of Unicode range (> U+10FFFF)
            if (c > 0xF4) return false;
            // Overlong encoding
            if (c == 0xF0 && (bytes[i + 1] & 0x30) == 0) return false;
            // Invalid code points (> U+10FFFF)
            if (c == 0xF4 && bytes[i + 1] > 0x8F) return false;
        }
        
        i += num_bytes;
    }
    
    return true;
}

// Helper function to sanitize UTF-8 strings
static std::string sanitizeUTF8(const char* str, size_t len) {
    if (!str || len == 0) return "";
    
    // First try to validate as-is
    if (isValidUTF8(str, len)) {
        return std::string(str, len);
    }
    
    // If invalid, create a sanitized version
    std::string result;
    result.reserve(len);
    
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;
    
    while (i < len) {
        unsigned char c = bytes[i];
        
        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            result += c;
            i++;
            continue;
        }
        
        // Multi-byte sequence start
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2;
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3;
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4;
        } else {
            // Invalid first byte, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
            i++;
            continue;
        }
        
        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            result += "\xEF\xBF\xBD"; // 
            break;
        }
        
        // Extract the sequence
        std::string seq(reinterpret_cast<const char*>(bytes + i), num_bytes);
        
        // Validate the sequence
        if (isValidUTF8(seq.c_str(), num_bytes)) {
            result += seq;
        } else {
            // Invalid sequence, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
        }
        
        i += num_bytes;
    }
    
    return result;
}

// Installed here rather than in nativeLoadModel so that everything ggml says
// before the first load -- backend registration, device enumeration, the
// Vulkan probe in nativeDetectGpu -- reaches the ring too. Those lines are
// what explain a bad accelerator choice, and they were being lost.
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    llama_log_set(androidLlamaLog, nullptr);
    (void)vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeDetectGpu(
        JNIEnv* env, jobject /* this */, jlongArray outStats) {

    // Zero out output array as safe default (-1 = unknown)
    jlong defaults[2] = {-1L, -1L};
    env->SetLongArrayRegion(outStats, 0, 2, defaults);

    // Ask ggml what it actually registered rather than opening a Vulkan
    // instance of our own: the backend that will run the layers is the only
    // authority on whether the offload is possible, and a device ggml did not
    // register is one llama_model_load could not use even if Vulkan answered.
    // Backends may be dynamically loaded shared objects rather than statically
    // registered; without this the registry can be empty on the first call and
    // only fills in later, when llama_model_load does it for us.
    ggml_backend_load_all();

    const size_t n_devices = ggml_backend_dev_count();
    LOGI("nativeDetectGpu: %zu device(s) registered", n_devices);
    for (size_t i = 0; i < n_devices; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (!dev) {
            continue;
        }
        const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
        LOGI("nativeDetectGpu:   device %zu: %s (type %d)", i,
             ggml_backend_dev_name(dev), (int)type);
        // IGPU is not a lesser GPU, it is the only kind a phone has: ggml sorts
        // the Mali here because it shares system memory rather than owning a
        // heap. Accepting only _GPU rejects every Android device there is.
        if (type != GGML_BACKEND_DEVICE_TYPE_GPU &&
            type != GGML_BACKEND_DEVICE_TYPE_IGPU) {
            continue;
        }

        size_t free_mem = 0;
        size_t total_mem = 0;
        ggml_backend_dev_memory(dev, &free_mem, &total_mem);

        // outStats[0] stays -1: ggml does not expose the Vulkan API version and
        // nothing downstream reads it. outStats[1] is what sizes the offload --
        // on a UMA phone that is system memory, not a private heap.
        jlong stats[2] = {-1L, (jlong)total_mem};
        env->SetLongArrayRegion(outStats, 0, 2, stats);

        const char* name = ggml_backend_dev_description(dev);
        LOGI("nativeDetectGpu: %s, %zu MiB total", name ? name : "GPU",
             total_mem / (1024 * 1024));
        return env->NewStringUTF(name ? name : "GPU");
    }

    LOGI("nativeDetectGpu: no GPU backend registered");
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadModel(
    JNIEnv* env, jobject thiz,
    jstring path, jlong n_threads, jlong ctx_size, jlong n_gpu_layers,
    jobject progress_callback) {
    
    if (!path) {
        throwLoadError(env, "GGUF model path is missing");
        return;
    }

    const char* model_path = env->GetStringUTFChars(path, nullptr);
    if (!model_path) {
        throwLoadError(env, "Could not read the GGUF model path");
        return;
    }
    LOGI("Loading model: %s", model_path);

    std::ifstream model_file(model_path, std::ios::binary | std::ios::ate);
    if (!model_file) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "GGUF model file is missing or unreadable");
        return;
    }
    const std::streamsize model_size = model_file.tellg();
    if (model_size < 4) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "GGUF model file is empty or incomplete");
        return;
    }
    model_file.seekg(0, std::ios::beg);
    char magic[4] = {};
    model_file.read(magic, sizeof(magic));
    if (!model_file || std::memcmp(magic, "GGUF", sizeof(magic)) != 0) {
        env->ReleaseStringUTFChars(path, model_path);
        throwLoadError(env, "Invalid GGUF model header");
        return;
    }
    model_file.close();

    // Same hazard as teardown: replacing g_model/g_ctx while a generation
    // still holds them is a use-after-free.
    g_stop_flag = true;
    std::lock_guard<std::mutex> ctx_lock(g_ctx_mutex);
    g_stop_flag = false;

    // Model parameters
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = n_gpu_layers;

    llama_log_set(androidLlamaLog, nullptr);
    {
        std::lock_guard<std::mutex> lock(g_load_log_mutex);
        g_load_error.clear();
        g_capture_load_error = true;
    }
    
    // Load model
    g_model = llama_model_load_from_file(model_path, model_params);
    env->ReleaseStringUTFChars(path, model_path);
    
    if (!g_model) {
        const std::string detail = consumeLoadError();
        const std::string message = detail.empty()
            ? "Failed to load GGUF model; check model compatibility and available RAM"
            : "Failed to load GGUF model: " + detail;
        throwLoadError(env, message);
        return;
    }
    consumeLoadError();

    // Context parameters with memory optimizations for low-end devices
    llama_context_params ctx_params = llama_context_default_params();

    // Ask for what the caller wants, but never for more than the model was
    // trained on: Settings lets any number be typed (a recurrent model such as
    // RWKV keeps a fixed-size state, so a big number there costs nothing), and
    // this is the one place every load funnels through, so the ceiling belongs
    // here rather than in the UI. llama_n_ctx() reports the effective value
    // back, which is what the context-usage bar already reads.
    const int n_ctx_train = llama_model_n_ctx_train(g_model);
    if (n_ctx_train > 0 && ctx_size > n_ctx_train) {
        LOGI("Requested context %d exceeds the model's trained context %d — using %d",
             (int)ctx_size, n_ctx_train, n_ctx_train);
        ctx_size = n_ctx_train;
    }
    ctx_params.n_ctx = ctx_size;
    ctx_params.n_threads = n_threads;
    ctx_params.n_threads_batch = n_threads;
    
    // Memory optimization: reduce memory usage by limiting batch processing
    ctx_params.n_batch = 512;  // Process smaller batches to reduce memory spikes

    // With the weights in system RAM, let them be computed there too.
    //
    // ggml's scheduler has a second, separate offload path from n_gpu_layers:
    // ggml_backend_sched_backend_id_from_cur() hands any op whose batch is at
    // least GGML_OP_OFFLOAD_MIN_BATCH (32) to a higher-priority backend that
    // claims it, even when the weights live on the host. Registering Vulkan is
    // enough to trigger it, so "CPU" in Settings never was CPU: decode (batch 1)
    // stayed put, but every prefill (batch 244 measured) shipped each layer's
    // weights over the bus to the GPU and back, once per op. Measured on a
    // Mali-G615: 244 text tokens took 63.8s to prefill, 3.8 tok/s -- slower than
    // this build decodes (4.3 tok/s), when prefill should beat decode severalfold.
    // It also pins the GPU, which is why generating froze the whole UI.
    if (n_gpu_layers == 0) {
        ctx_params.op_offload = false;
        LOGI("op_offload disabled: weights are on the host");
    }

    // Create context (using new API)
    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (!g_ctx) {
        llama_model_free(g_model);
        g_model = nullptr;
        jclass exception = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(exception, "Failed to create context");
        return;
    }

    // Get vocab for tokenization
    g_vocab = llama_model_get_vocab(g_model);
    LOGI("Vocab initialized: %p", (void*)g_vocab);
    
    if (!g_vocab) {
        llama_free(g_ctx);
        llama_model_free(g_model);
        g_ctx = nullptr;
        g_model = nullptr;
        jclass exception = env->FindClass("java/lang/RuntimeException");
        env->ThrowNew(exception, "Failed to get vocab from model");
        return;
    }
    
    // Reset KV cache position counter for new model
    g_n_past = 0;

    // Report progress completion
    if (progress_callback) {
        jclass callbackClass = env->GetObjectClass(progress_callback);
        jmethodID invokeMethod = env->GetMethodID(callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");
        
        // Create Double object for 1.0
        jclass doubleClass = env->FindClass("java/lang/Double");
        jmethodID doubleConstructor = env->GetMethodID(doubleClass, "<init>", "(D)V");
        jobject doubleObj = env->NewObject(doubleClass, doubleConstructor, 1.0);
        
        env->CallObjectMethod(progress_callback, invokeMethod, doubleObj);
        env->DeleteLocalRef(doubleObj);
        env->DeleteLocalRef(callbackClass);
    }

    LOGI("Model loaded successfully");
}

static jobject g_token_callback = nullptr;

// ---------------------------------------------------------------------------
// Multimodal (libmtmd)
// ---------------------------------------------------------------------------

// The marker the projector expects in the prompt where media should be spliced
// in. Exposed so the Dart side can place it inside the chat template rather
// than having the JNI guess where the user's turn begins.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeDrainLog(
        JNIEnv* env, jobject /* this */) {
    std::deque<std::string> drained;
    {
        std::lock_guard<std::mutex> lock(g_log_ring_mutex);
        drained.swap(g_log_ring);
    }
    jclass stringClass = env->FindClass("java/lang/String");
    jobjectArray out = env->NewObjectArray(
        static_cast<jsize>(drained.size()), stringClass, nullptr);
    for (jsize i = 0; i < static_cast<jsize>(drained.size()); ++i) {
        jstring line = env->NewStringUTF(drained[i].c_str());
        // NewStringUTF returns null on malformed UTF-8; skip rather than
        // hand the JVM a null element the Kotlin side would trip over.
        if (line == nullptr) {
            env->ExceptionClear();
            continue;
        }
        env->SetObjectArrayElement(out, i, line);
        env->DeleteLocalRef(line);
    }
    return out;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeMediaMarker(
    JNIEnv* env, jobject thiz) {
    return env->NewStringUTF(mtmd_default_marker());
}

// Loads the multimodal projector that pairs with the already-loaded model.
// Returns a capability bitmask: 1 = vision, 2 = audio, -1 = load failed.
extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadMmproj(
    JNIEnv* env, jobject thiz, jstring mmproj_path, jboolean use_gpu, jint n_threads) {

    if (!g_model) {
        LOGE("Cannot load mmproj: no model loaded");
        return -1;
    }

    if (g_mtmd) {
        mtmd_free(g_mtmd);
        g_mtmd = nullptr;
    }

    const char* path = env->GetStringUTFChars(mmproj_path, nullptr);
    LOGI("Loading mmproj: %s (gpu=%d)", path, (int)use_gpu);

    mtmd_context_params params = mtmd_context_params_default();
    params.use_gpu       = use_gpu;
    // On by default: the encoder is the slowest step of a multimodal turn by
    // an order of magnitude, and without its own timing there is no way to tell
    // an expensive image apart from a slow prefill in the log.
    params.print_timings = true;
    params.n_threads     = n_threads > 0 ? n_threads : 4;
    // The encoder runs once per image, and a warmup pass would double the cost
    // of the very first one for no benefit on a phone.
    params.warmup        = false;

    g_mtmd = mtmd_init_from_file(path, g_model, params);
    env->ReleaseStringUTFChars(mmproj_path, path);

    if (!g_mtmd) {
        LOGE("mtmd_init_from_file failed");
        return -1;
    }

    jint caps = 0;
    if (mtmd_support_vision(g_mtmd)) caps |= 1;
    if (mtmd_support_audio(g_mtmd))  caps |= 2;
    LOGI("mmproj loaded, capabilities: vision=%d audio=%d",
         (caps & 1) ? 1 : 0, (caps & 2) ? 1 : 0);
    return caps;
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeFreeMmproj(
    JNIEnv* env, jobject thiz) {
    if (g_mtmd) {
        mtmd_free(g_mtmd);
        g_mtmd = nullptr;
        LOGI("mmproj freed");
    }
    g_pending_media.clear();
}

// Audio input has to be resampled to whatever rate the projector was trained
// on. Reported here so the caller can convert before handing over a file.
extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeAudioSampleRate(
    JNIEnv* env, jobject thiz) {
    return g_mtmd ? mtmd_get_audio_sample_rate(g_mtmd) : 0;
}

// Queues media for the next generate call. Each path is an image or audio file
// and must line up, in order, with the markers in that call's prompt.
extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeSetMedia(
    JNIEnv* env, jobject thiz, jobjectArray paths) {

    g_pending_media.clear();
    if (paths == nullptr) return;

    const jsize count = env->GetArrayLength(paths);
    for (jsize i = 0; i < count; i++) {
        jstring item = (jstring) env->GetObjectArrayElement(paths, i);
        if (item == nullptr) continue;
        const char* chars = env->GetStringUTFChars(item, nullptr);
        g_pending_media.emplace_back(chars);
        env->ReleaseStringUTFChars(item, chars);
        env->DeleteLocalRef(item);
    }
    LOGI("Queued %zu media file(s) for the next generation", g_pending_media.size());
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGenerate(
    JNIEnv* env, jobject thiz,
    jstring prompt, jlong max_tokens, 
    jdouble temperature, jdouble top_p, jlong top_k, jdouble min_p, jdouble typical_p,
    jdouble repeat_penalty, jdouble frequency_penalty, jdouble presence_penalty, jlong repeat_last_n,
    jlong mirostat, jdouble mirostat_tau, jdouble mirostat_eta,
    jlong seed, jboolean penalize_newline,
    jobject token_callback) {
    
    if (g_token_callback != nullptr) {
        env->DeleteGlobalRef(g_token_callback);
        g_token_callback = nullptr;
    }
    g_token_callback = env->NewGlobalRef(token_callback);
    
    if (!g_model || !g_ctx || !g_vocab) {
        jclass exception = env->FindClass("java/lang/IllegalStateException");
        env->ThrowNew(exception, "Model not loaded");
        return;
    }

    // Held for the whole generation: nothing may free g_ctx underneath it.
    //
    // Logged around, not just taken: the lock is acquired before any other
    // message, so a request blocked here would otherwise look exactly like
    // one that was never made. Those need different fixes, so say which.
    LOGI("nativeGenerate: entry");
    std::unique_lock<std::mutex> ctx_lock(g_ctx_mutex, std::try_to_lock);
    if (!ctx_lock.owns_lock()) {
        LOGI("nativeGenerate: context busy, waiting for the previous generation");
        ctx_lock.lock();
    }
    LOGI("nativeGenerate: context acquired");

    // Clear memory from previous generation to start fresh
    const char* prompt_str = env->GetStringUTFChars(prompt, nullptr);
    g_stop_flag = false;
    
    const int prompt_len = strlen(prompt_str);
    LOGI("Tokenizing prompt: '%s' (length: %d)", prompt_str, prompt_len);
    LOGI("Vocab pointer: %p, Model pointer: %p", (void*)g_vocab, (void*)g_model);

    // Sanitize the UTF-8 string before tokenizing
    std::string sanitized_prompt = sanitizeUTF8(prompt_str, prompt_len);
    env->ReleaseStringUTFChars(prompt, prompt_str);

    const int n_ctx = llama_n_ctx(g_ctx);
    const int max_batch_size = 512;

    // Reused by both prefill paths below and by the generation loop.
    llama_batch batch = llama_batch_init(max_batch_size, 0, 1);
    LOGI("Context size: %d", n_ctx);

    // Shifts the KV cache when the incoming prompt would not fit, dropping the
    // oldest quarter of the context.
    auto make_room_for = [&](int incoming) {
        if (g_n_past + incoming <= n_ctx) return;
        const int n_discard = n_ctx / 4;
        LOGI("Context is full, shifting KV cache by %d tokens", n_discard);
        llama_memory_seq_rm (llama_get_memory(g_ctx), 0, 0, n_discard);
        llama_memory_seq_add(llama_get_memory(g_ctx), 0, n_discard, g_n_past, -n_discard);
        g_n_past -= n_discard;
    };

    const bool use_mtmd = (g_mtmd != nullptr) && !g_pending_media.empty();

    if (use_mtmd) {
        // --- multimodal prefill ------------------------------------------
        // libmtmd splits the prompt at each media marker, runs the vision or
        // audio encoder over the matching file, and feeds the resulting
        // embeddings to llama_decode itself. Tokenizing here by hand would
        // throw the media away, which is why this path bypasses the block
        // below entirely.
        const std::string marker = mtmd_default_marker();

        size_t marker_count = 0;
        for (size_t at = sanitized_prompt.find(marker); at != std::string::npos;
             at = sanitized_prompt.find(marker, at + marker.size())) {
            marker_count++;
        }

        // mtmd_tokenize fails outright when the counts disagree. Rather than
        // error out, normalize: strip whatever markers are there and put one
        // per file at the front. A misplaced marker degrades the answer; a
        // missing one loses the image.
        if (marker_count != g_pending_media.size()) {
            LOGI("Marker count %zu != %zu media file(s), rewriting prompt",
                 marker_count, g_pending_media.size());
            for (size_t at = sanitized_prompt.find(marker); at != std::string::npos;
                 at = sanitized_prompt.find(marker)) {
                sanitized_prompt.erase(at, marker.size());
            }
            std::string prefix;
            for (size_t i = 0; i < g_pending_media.size(); i++) {
                prefix += marker;
                prefix += "\n";
            }
            sanitized_prompt = prefix + sanitized_prompt;
        }

        std::vector<mtmd_bitmap*> bitmaps;
        std::string load_failure;
        for (const std::string& path : g_pending_media) {
            mtmd_bitmap* bitmap = mtmd_helper_bitmap_init_from_file(g_mtmd, path.c_str());
            if (!bitmap) {
                load_failure = path;
                break;
            }
            bitmaps.push_back(bitmap);
        }

        if (!load_failure.empty()) {
            for (mtmd_bitmap* b : bitmaps) mtmd_bitmap_free(b);
            g_pending_media.clear();
            llama_batch_free(batch);
            LOGE("Failed to load media file: %s", load_failure.c_str());
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception,
                ("Failed to read media file: " + load_failure).c_str());
            return;
        }

        mtmd_input_text text;
        text.text          = sanitized_prompt.c_str();
        text.add_special   = true;
        text.parse_special = true;

        std::vector<const mtmd_bitmap*> bitmap_ptrs(bitmaps.begin(), bitmaps.end());
        mtmd_input_chunks* chunks = mtmd_input_chunks_init();

        const int32_t tokenize_rc = mtmd_tokenize(
            g_mtmd, chunks, &text, bitmap_ptrs.data(), bitmap_ptrs.size());

        for (mtmd_bitmap* b : bitmaps) mtmd_bitmap_free(b);
        g_pending_media.clear();

        if (tokenize_rc != 0) {
            mtmd_input_chunks_free(chunks);
            llama_batch_free(batch);
            LOGE("mtmd_tokenize failed with code %d", tokenize_rc);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, tokenize_rc == 1
                ? "Media count does not match the markers in the prompt"
                : "Failed to preprocess the media for this model");
            return;
        }

        const size_t n_incoming = mtmd_helper_get_n_tokens(chunks);
        LOGI("Multimodal prompt: %zu tokens across %zu chunk(s)",
             n_incoming, mtmd_input_chunks_size(chunks));
        make_room_for((int) n_incoming);

        // Per chunk rather than mtmd_helper_eval_chunks() over the lot, so the
        // log says which part of a multimodal prefill the time went to. The
        // whole-list helper is a black box that can run for a minute, and the
        // encoder and the decode of its output have completely different fixes.
        // Same breakdown llama.rn prints, which makes the two directly
        // comparable on the same prompt.
        llama_pos new_n_past = g_n_past;
        int32_t eval_rc = 0;
        const size_t n_chunks = mtmd_input_chunks_size(chunks);
        for (size_t i = 0; i < n_chunks && eval_rc == 0; i++) {
            const mtmd_input_chunk* chunk = mtmd_input_chunks_get(chunks, i);
            const mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);
            const char* kind = type == MTMD_INPUT_CHUNK_TYPE_TEXT  ? "TEXT"
                             : type == MTMD_INPUT_CHUNK_TYPE_IMAGE ? "IMAGE"
                                                                   : "AUDIO";
            const size_t n_tok = mtmd_input_chunk_get_n_tokens(chunk);
            const auto t0 = std::chrono::steady_clock::now();
            eval_rc = mtmd_helper_eval_chunk_single(
                g_mtmd, g_ctx, chunk, new_n_past, /* seq_id */ 0,
                max_batch_size, /* logits_last */ i + 1 == n_chunks, &new_n_past);
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();
            LOGI("Chunk %zu/%zu: type=%s, n_tokens=%zu, %lld ms",
                 i + 1, n_chunks, kind, n_tok, (long long) ms);
        }

        mtmd_input_chunks_free(chunks);

        if (eval_rc != 0) {
            llama_batch_free(batch);
            LOGE("mtmd_helper_eval_chunks failed with code %d", eval_rc);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, "Failed to evaluate the multimodal prompt");
            return;
        }

        g_n_past = new_n_past;
        LOGI("Multimodal prefill done, g_n_past=%d", g_n_past);

    } else {
        // --- text-only prefill -------------------------------------------
        const char* sanitized_cstr = sanitized_prompt.c_str();
        const int sanitized_len = sanitized_prompt.length();

        // Tokenize prompt - when tokens is NULL, llama_tokenize returns NEGATIVE count
        const int n_prompt_tokens = -llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, nullptr, 0, true, true);
        LOGI("Token count: %d", n_prompt_tokens);

        if (n_prompt_tokens <= 0) {
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            char error_msg[256];
            snprintf(error_msg, sizeof(error_msg), "Failed to tokenize prompt (got %d tokens)", n_prompt_tokens);
            env->ThrowNew(exception, error_msg);
            return;
        }
        std::vector<llama_token> tokens(n_prompt_tokens);
        const int actual_tokens = llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, tokens.data(), tokens.size(), true, true);
        if (actual_tokens < 0) {
            llama_batch_free(batch);
            jclass exception = env->FindClass("java/lang/RuntimeException");
            env->ThrowNew(exception, "Failed to tokenize prompt");
            return;
        }
        tokens.resize(actual_tokens);

        make_room_for((int) tokens.size());

        // Process prompt in batches to handle long inputs
        int tokens_processed = 0;

        while (tokens_processed < tokens.size() && !g_stop_flag) {
            batch.n_tokens = 0;
            int batch_size = std::min((int)tokens.size() - tokens_processed, max_batch_size);

            for (int i = 0; i < batch_size; i++) {
                batch.token[batch.n_tokens] = tokens[tokens_processed + i];
                batch.pos[batch.n_tokens] = g_n_past + tokens_processed + i;
                batch.n_seq_id[batch.n_tokens] = 1;
                batch.seq_id[batch.n_tokens][0] = 0;
                batch.logits[batch.n_tokens] = (tokens_processed + i == tokens.size() - 1);
                batch.n_tokens++;
            }

            LOGI("Decoding batch: g_n_past=%d, batch_size=%d", g_n_past + tokens_processed, batch.n_tokens);
            int decode_result = llama_decode(g_ctx, batch);
            if (decode_result != 0) {
                LOGE("❌ DECODE FAILED! Result code: %d", decode_result);
                llama_batch_free(batch);
                jclass exception = env->FindClass("java/lang/RuntimeException");
                env->ThrowNew(exception, "Failed to decode prompt");
                return;
            }
            tokens_processed += batch_size;
        }

        LOGI("✅ Decode successful! Processed %d total tokens", tokens_processed);

        // Update position counter after decoding the whole prompt
        g_n_past += tokens.size();
    }

    // Create sampler chain with all parameters
    if (g_sampler) {
        llama_sampler_free(g_sampler);
    }
    
    // Use seed or current time
    uint32_t sampler_seed = (seed >= 0) ? static_cast<uint32_t>(seed) : static_cast<uint32_t>(time(nullptr));
    
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    g_sampler = llama_sampler_chain_init(sparams);
    
    // Add penalties first (applied to logits before sampling)
    if (repeat_penalty != 1.0f || frequency_penalty != 0.0f || presence_penalty != 0.0f) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_penalties(
            repeat_last_n,              // penalty_last_n
            repeat_penalty,             // penalty_repeat
            frequency_penalty,          // penalty_freq
            presence_penalty            // penalty_present
        ));
    }
    
    // Temperature sampling
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(temperature));
    
    // Add advanced samplers if enabled
    if (mirostat == 1) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat(
            llama_vocab_n_tokens(g_vocab),  // Use the vocab to get n_vocab
            sampler_seed,
            mirostat_tau,
            mirostat_eta,
            100  // m parameter
        ));
    } else if (mirostat == 2) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat_v2(
            sampler_seed,
            mirostat_tau,
            mirostat_eta
        ));
    } else {
        // Standard sampling chain (only if mirostat is disabled)
        if (min_p > 0.0f && min_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p(min_p, 1));
        }
        
        if (typical_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_typical(typical_p, 1));
        }
        
        if (top_k > 0) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(top_k));
        }
        
        if (top_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(top_p, 1));
        }
    }
    
    // Final distribution sampler
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(sampler_seed));

    // Get callback method
    jclass callbackClass = env->GetObjectClass(token_callback);
    jmethodID invokeMethod = env->GetMethodID(callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");

    // Generation loop
    LOGI("Starting generation loop: max_tokens=%lld", max_tokens);
    for (int i = 0; i < max_tokens && !g_stop_flag; i++) {
        // Sample next token
        LOGI("Sampling token %d, g_n_past=%d", i + 1, g_n_past);
        llama_token new_token_id = llama_sampler_sample(g_sampler, g_ctx, -1);
        LOGI("Sampled token: %d", new_token_id);

        // Check for end of generation (EOS/EOD tokens)
        if (llama_vocab_is_eog(g_vocab, new_token_id)) {
            LOGI("EOS token detected, ending generation.");
            break;
        }

        // Decode token to string
        char buffer[256];
        int32_t length = llama_token_to_piece(g_vocab, new_token_id, buffer, sizeof(buffer), 0, true);
        std::string piece;
        
        if (length > 0) {
            piece = sanitizeUTF8(buffer, length);
        } else {
            piece = "";
        }
        
        // Call Kotlin callback
        jstring token_str = env->NewStringUTF(piece.c_str());
        env->CallObjectMethod(g_token_callback, invokeMethod, token_str);
        env->DeleteLocalRef(token_str);

        // Prepare next batch
        batch.n_tokens = 0;
        batch.token[batch.n_tokens] = new_token_id;
        batch.pos[batch.n_tokens] = g_n_past;  // Use the tracked position
        batch.n_seq_id[batch.n_tokens] = 1;
        batch.seq_id[batch.n_tokens][0] = 0;
        batch.logits[batch.n_tokens] = true;
        batch.n_tokens++;

        if (llama_decode(g_ctx, batch) != 0) {
            LOGE("Failed to decode after sampling token %d", i + 1);
            break;
        }
        
        // Update position counter after each generated token
        g_n_past++;
    }
    LOGI("Generation loop finished.");

    if (g_token_callback != nullptr) {
        env->DeleteGlobalRef(g_token_callback);
        g_token_callback = nullptr;
    }

    // After generation completion, ensure the KV cache is properly managed
    // In some llama.cpp versions, KV cache management may be needed between generations
    // For chat applications, we want to maintain conversation context
    
    llama_batch_free(batch);
    env->DeleteLocalRef(callbackClass);
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeStop(
    JNIEnv* env, jobject thiz) {
    g_stop_flag = true;
    // When stopping generation, we just set the flag - KV cache management handled by llama.cpp
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeFreeModel(
    JNIEnv* env, jobject thiz) {

    // Raise the flag before queueing on the mutex, so a generation in flight
    // unwinds at its next batch instead of making this wait out the whole
    // prompt. Ordering matters: lock first and the two would deadlock the
    // caller for the length of a full prefill.
    g_stop_flag = true;
    std::lock_guard<std::mutex> ctx_lock(g_ctx_mutex);

    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_mtmd) {
        mtmd_free(g_mtmd);
        g_mtmd = nullptr;
    }
    g_pending_media.clear();
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
    }
    g_vocab = nullptr;
    g_n_past = 0;  // Reset position counter
    
    LOGI("Model freed");
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetTokensUsed(
    JNIEnv* env, jobject thiz) {
    return g_n_past;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetContextSize(
    JNIEnv* env, jobject thiz) {
    return g_ctx ? llama_n_ctx(g_ctx) : 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeClearContext(
    JNIEnv* env, jobject thiz) {
    if (!g_ctx) {
        LOGE("Cannot clear context: context is null");
        return;
    }
    
    llama_memory_t mem = llama_get_memory(g_ctx);
    if (mem) {
        llama_memory_seq_rm(mem, 0, 0, -1);
        g_n_past = 0;
        LOGI("Context cleared, g_n_past reset to 0");
    } else {
        LOGE("Failed to get memory object from context");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeSetSystemPromptLength(
    JNIEnv* env, jobject thiz, jint length) {
    // Currently not used but available for future smart context management
    LOGI("System prompt length set to: %d tokens (currently unused)", length);
}
