package com.songhieu.flutter_litert_lm

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.SamplerConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import android.os.Build
import android.util.Log
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class FlutterLitertLmPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val engines = ConcurrentHashMap<String, Engine>()
    private val conversations = ConcurrentHashMap<String, Conversation>()
    private val conversationEngineMap = ConcurrentHashMap<String, String>()

    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "flutter_litert_lm")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "flutter_litert_lm/stream")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        scope.cancel()
        // Clean up all resources
        conversations.values.forEach { it.close() }
        conversations.clear()
        engines.values.forEach { it.close() }
        engines.clear()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "createEngine" -> handleCreateEngine(call, result)
            "disposeEngine" -> handleDisposeEngine(call, result)
            "createConversation" -> handleCreateConversation(call, result)
            "disposeConversation" -> handleDisposeConversation(call, result)
            "sendMessage" -> handleSendMessage(call, result)
            "startMessageStream" -> handleStartMessageStream(call, result)
            "countTokens" -> handleCountTokens(call, result)
            "npuStatus" -> handleNpuStatus(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Vendor NPU driver sonames, in the order LiteRT itself tries them.
     * Written the way System.loadLibrary wants them: no "lib" prefix, no ".so".
     */
    private val logTag = "LiteRtNpuProbe"

    private val vendorDriverSonames = listOf(
        "neuronusdk_adapter.mtk",
        "neuronusdk_adapter.9.mtk",
        "neuronusdk_adapter",
        "neuron_adapter_mgvi",
        "neuron_adapter",
    )

    /**
     * Can this build actually reach the NPU?
     *
     * Two separate pieces have to line up, and only one of them is ours:
     *
     *  1. The *dispatch* library, which we build from LiteRT and ship in
     *     jniLibs. `Backend.NPU(dir)` does not carry one — it only names the
     *     directory to load it from, and the published litertlm-android AAR
     *     contains just liblitertlm_jni.so.
     *  2. The vendor *driver*, which is proprietary and lives on the device.
     *     The dispatch library dlopens it by bare soname, so it resolves only
     *     if the OEM exposed it through /system/etc/public.libraries*.txt.
     *     `System.loadLibrary` answers that question from inside the app's own
     *     linker namespace, which is the only namespace whose answer counts.
     *
     * Probe both rather than inferring from the SoC name: a Dimensity 7300 is
     * on Google's supported-SoC list and still cannot touch its APU if either
     * piece is missing.
     */
    private fun handleNpuStatus(result: Result) {
        val dir = File(context.applicationInfo.nativeLibraryDir)
        val libs = dir.listFiles()?.map { it.name }?.filter { name ->
            name.startsWith("libLiteRtDispatch") ||   // LiteRT vendor dispatch API
                name.startsWith("libneuron_adapter") ||   // MediaTek NeuroPilot
                name.startsWith("libneuronusdk_adapter") ||
                name.startsWith("libQnnHtp")             // Qualcomm QAIRT
        } ?: emptyList()

        val bundledDriver = libs.any { !it.startsWith("libLiteRtDispatch") }
        val systemDriver = if (bundledDriver) null else findSystemDriver()

        result.success(
            mapOf(
                "available" to (libs.any { it.startsWith("libLiteRtDispatch") } &&
                    (bundledDriver || systemDriver != null)),
                "libraries" to libs,
                "systemDriver" to (systemDriver ?: ""),
                "soc" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else "",
                "nativeLibraryDir" to dir.path,
            )
        )
    }

    /**
     * Name of the first vendor NPU driver the app can actually load, or null.
     *
     * Same sonames the LiteRT dispatch library tries, in the same order (see
     * litert/vendors/mediatek/neuron_adapter_api.cc), so a hit here means the
     * dispatch library will find it too. Loading is the test — the library is
     * left loaded, which is exactly what the NPU tier would do moments later.
     */
    private fun findSystemDriver(): String? = vendorDriverSonames.firstOrNull { soname ->
        try {
            System.loadLibrary(soname)
            Log.i(logTag, "NPU driver loaded: lib$soname.so")
            true
        } catch (e: UnsatisfiedLinkError) {
            // The linker's own wording separates "no such file" from "not
            // accessible for the namespace", which are very different verdicts.
            Log.i(logTag, "NPU driver lib$soname.so rejected: ${e.message}")
            false
        } catch (e: SecurityException) {
            Log.i(logTag, "NPU driver lib$soname.so rejected: $e")
            false
        }
    }

    private fun handleCreateEngine(call: MethodCall, result: Result) {
        scope.launch {
            try {
                val modelPath = call.argument<String>("modelPath")!!
                val backendName = call.argument<String>("backend") ?: "cpu"
                val cacheDir = call.argument<String>("cacheDir")
                val visionBackendName = call.argument<String>("visionBackend")
                val audioBackendName = call.argument<String>("audioBackend")
                val maxNumTokens = call.argument<Int>("maxNumTokens")

                val backend = parseBackend(backendName)
                val visionBackend = visionBackendName?.let { parseBackend(it) }
                val audioBackend = audioBackendName?.let { parseBackend(it) }
                val configBuilder = EngineConfig(
                    modelPath = modelPath,
                    backend = backend,
                    cacheDir = cacheDir ?: context.cacheDir.absolutePath,
                    visionBackend = visionBackend,
                    audioBackend = audioBackend,
                    maxNumTokens = maxNumTokens,
                )

                val engine = Engine(configBuilder)
                engine.initialize()

                val engineId = UUID.randomUUID().toString()
                engines[engineId] = engine

                withContext(Dispatchers.Main) {
                    result.success(engineId)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("ENGINE_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
    }

    private fun handleDisposeEngine(call: MethodCall, result: Result) {
        val engineId = call.argument<String>("engineId")!!
        // Dispose all conversations belonging to this engine
        conversationEngineMap.entries
            .filter { it.value == engineId }
            .forEach { (convId, _) ->
                conversations.remove(convId)?.close()
                conversationEngineMap.remove(convId)
            }
        engines.remove(engineId)?.close()
        result.success(null)
    }

    private fun handleCreateConversation(call: MethodCall, result: Result) {
        scope.launch {
            try {
                val engineId = call.argument<String>("engineId")!!
                val engine = engines[engineId]
                    ?: throw IllegalStateException("Engine not found: $engineId")
                val configMap = call.argument<Map<String, Any>>("config")

                val conversation = if (configMap != null) {
                    val convConfig = parseConversationConfig(configMap)
                    engine.createConversation(convConfig)
                } else {
                    engine.createConversation()
                }

                val convId = UUID.randomUUID().toString()
                conversations[convId] = conversation
                conversationEngineMap[convId] = engineId

                withContext(Dispatchers.Main) {
                    result.success(convId)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("CONVERSATION_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
    }

    private fun handleDisposeConversation(call: MethodCall, result: Result) {
        val convId = call.argument<String>("conversationId")!!
        conversations.remove(convId)?.close()
        conversationEngineMap.remove(convId)
        result.success(null)
    }

    private fun handleSendMessage(call: MethodCall, result: Result) {
        scope.launch {
            try {
                val convId = call.argument<String>("conversationId")!!
                val contentsList = call.argument<List<Map<String, Any>>>("contents")!!
                @Suppress("UNCHECKED_CAST")
                val extraContext = call.argument<Map<String, Any>>("extraContext")

                val conversation = conversations[convId]
                    ?: throw IllegalStateException("Conversation not found: $convId")

                val contents = parseContents(contentsList)
                val response = if (extraContext != null) {
                    conversation.sendMessage(contents, extraContext)
                } else {
                    conversation.sendMessage(contents)
                }

                val responseMap = messageToMap(response)

                withContext(Dispatchers.Main) {
                    result.success(responseMap)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("MESSAGE_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
    }

    private fun handleStartMessageStream(call: MethodCall, result: Result) {
        scope.launch {
            try {
                val convId = call.argument<String>("conversationId")!!
                val contentsList = call.argument<List<Map<String, Any>>>("contents")!!
                @Suppress("UNCHECKED_CAST")
                val extraContext = call.argument<Map<String, Any>>("extraContext")

                val conversation = conversations[convId]
                    ?: throw IllegalStateException("Conversation not found: $convId")

                val contents = parseContents(contentsList)
                val flow = if (extraContext != null) {
                    conversation.sendMessageAsync(contents, extraContext)
                } else {
                    conversation.sendMessageAsync(contents)
                }

                flow.collect { message: Message ->
                    val map = messageToMap(message)
                    withContext(Dispatchers.Main) {
                        eventSink?.success(map)
                    }
                }

                withContext(Dispatchers.Main) {
                    eventSink?.endOfStream()
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    eventSink?.error("STREAM_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
        // Return immediately — streaming happens via event channel
        result.success(null)
    }

    private fun handleCountTokens(call: MethodCall, result: Result) {
        scope.launch {
            try {
                val engineId = call.argument<String>("engineId")!!
                val text = call.argument<String>("text")!!
                // Token counting is not directly exposed in the public API yet.
                // Return -1 as a placeholder.
                withContext(Dispatchers.Main) {
                    result.success(-1)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("COUNT_ERROR", e.message, e.stackTraceToString())
                }
            }
        }
    }

    // --- Helper methods ---

    private fun parseBackend(name: String): Backend = when (name) {
        "gpu" -> Backend.GPU()
        "npu" -> Backend.NPU(context.applicationInfo.nativeLibraryDir)
        else -> Backend.CPU()
    }

    private fun parseConversationConfig(map: Map<String, Any>): ConversationConfig {
        val systemInstruction = map["systemInstruction"] as? String
        val samplerMap = map["samplerConfig"] as? Map<String, Any>
        val toolsList = map["tools"] as? List<Map<String, Any>>
        val initialMsgsList = map["initialMessages"] as? List<Map<String, Any>>

        val samplerConfig = samplerMap?.let {
            SamplerConfig(
                topK = (it["topK"] as? Number)?.toInt() ?: 40,
                topP = (it["topP"] as? Number)?.toDouble() ?: 0.95,
                temperature = (it["temperature"] as? Number)?.toDouble() ?: 0.8,
            )
        }

        val initialMessages = initialMsgsList?.map { msgMap ->
            val role = msgMap["role"] as String
            val text = msgMap["text"] as? String ?: ""
            when (role) {
                "user" -> Message.user(text)
                "model" -> Message.model(text)
                else -> Message.user(text)
            }
        }

        // ConversationConfig fields are non-null with defaults; build from default
        // and override only what we have via copy().
        var config = ConversationConfig()
        systemInstruction?.let { config = config.copy(systemInstruction = Contents.of(it)) }
        if (!initialMessages.isNullOrEmpty()) {
            config = config.copy(initialMessages = initialMessages)
        }
        samplerConfig?.let { config = config.copy(samplerConfig = it) }
        return config
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseContents(contentsList: List<Map<String, Any>>): Contents {
        val parts = mutableListOf<Content>()
        for (content in contentsList) {
            when (content["type"]) {
                "text" -> parts.add(Content.Text(content["text"] as String))
                "imageFile" -> parts.add(Content.ImageFile(content["path"] as String))
                "imageBytes" -> parts.add(Content.ImageBytes(content["bytes"] as ByteArray))
                "audioFile" -> parts.add(Content.AudioFile(content["path"] as String))
                "audioBytes" -> parts.add(Content.AudioBytes(content["bytes"] as ByteArray))
                "toolResponse" -> parts.add(
                    Content.ToolResponse(
                        content["name"] as String,
                        content["result"] as String,
                    )
                )
            }
        }
        return Contents.of(parts)
    }

    private fun messageToMap(message: Message): Map<String, Any> {
        // Message no longer has a `.text` property; extract by joining all
        // Content.Text parts in the message's contents.
        val text = message.contents.contents
            .filterIsInstance<Content.Text>()
            .joinToString("") { it.text }
        val toolCalls = message.toolCalls.map { tc ->
            mapOf(
                "name" to tc.name,
                "arguments" to tc.arguments,
            )
        }
        return mapOf(
            "role" to "model",
            "text" to text,
            "toolCalls" to toolCalls,
        )
    }
}
