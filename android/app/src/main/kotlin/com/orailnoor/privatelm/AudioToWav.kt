package com.orailnoor.privatelm

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Decode any audio file Android can read into a 16 kHz mono 16-bit WAV.
 *
 * LiteRT-LM preprocesses audio with miniaudio built for WAV only — the shipped
 * liblitertlm_jni.so carries the RIFF/WAVE magic and nothing for Ogg, FLAC or
 * MP3 — so an .ogg reaches it as "Failed to initialize miniaudio decoder, error
 * code: -10" (MA_INVALID_FILE). Android's own MediaCodec already has decoders
 * for Vorbis, Opus, MP3, AAC and FLAC, so the fix is a format conversion on the
 * way in, not a codec of our own.
 *
 * 16 kHz mono is what speech-capable multimodal models expect, and it is also
 * the cheapest thing to carry: a minute of it is under 2 MB.
 */
object AudioToWav {

    private const val TARGET_RATE = 16_000
    private const val DEQUEUE_TIMEOUT_US = 10_000L

    /** Guard against a malformed file decoding into gigabytes: ~30 min at 16 kHz. */
    private const val MAX_SAMPLES = TARGET_RATE * 60 * 30

    /**
     * Returns the path of a WAV holding [sourcePath]'s audio.
     *
     * A file that is already a 16 kHz mono WAV is returned untouched — no point
     * decoding and re-encoding what LiteRT can already read.
     */
    fun convert(sourcePath: String, outputDir: File): String {
        val source = File(sourcePath)
        require(source.exists()) { "Audio file not found: $sourcePath" }

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(sourcePath)
            val trackIndex = (0 until extractor.trackCount).firstOrNull { i ->
                extractor.getTrackFormat(i)
                    .getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("No audio track in ${source.name}")

            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val sourceRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val sourceChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            // Already exactly what we want, and stored as PCM: hand it straight
            // over. "audio/raw" is what an uncompressed WAV reports.
            if (mime == "audio/raw" && sourceRate == TARGET_RATE && sourceChannels == 1) {
                return sourcePath
            }

            extractor.selectTrack(trackIndex)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val mono = decodeToMono(extractor, codec, sourceChannels)
            val resampled = resample(mono, sourceRate, TARGET_RATE)

            outputDir.mkdirs()
            val out = File(outputDir, "${source.nameWithoutExtension}_16k.wav")
            writeWav(out, resampled)
            return out.absolutePath
        } finally {
            try {
                codec?.stop()
            } catch (_: IllegalStateException) {
                // Already stopped after an error; releasing is what matters.
            }
            codec?.release()
            extractor.release()
        }
    }

    /**
     * Run the decode loop, downmixing to one channel as samples arrive.
     *
     * Averaging the channels rather than dropping one keeps a voice that was
     * panned to one side from disappearing.
     */
    private fun decodeToMono(
        extractor: MediaExtractor,
        codec: MediaCodec,
        declaredChannels: Int,
    ): ShortArray {
        val samples = ShortArrayBuilder()
        val info = MediaCodec.BufferInfo()
        var channels = declaredChannels
        var inputDone = false

        while (true) {
            if (!inputDone) {
                val inputIndex = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inputIndex >= 0) {
                    val buffer = codec.getInputBuffer(inputIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(
                            inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            when (val outputIndex = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // The real channel count is only trustworthy here: some
                    // decoders correct the container's claim on first output.
                    channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                else -> {
                    if (outputIndex >= 0) {
                        val buffer = codec.getOutputBuffer(outputIndex)!!
                        if (info.size > 0) {
                            appendMono(buffer, info, channels, samples)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            return samples.build()
                        }
                        if (samples.size >= MAX_SAMPLES) return samples.build()
                    }
                }
            }
        }
    }

    private fun appendMono(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        channels: Int,
        into: ShortArrayBuilder,
    ) {
        val pcm = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        pcm.position(info.offset)
        pcm.limit(info.offset + info.size)
        val shorts = pcm.asShortBuffer()

        if (channels <= 1) {
            while (shorts.hasRemaining()) into.add(shorts.get())
            return
        }
        val frame = ShortArray(channels)
        while (shorts.remaining() >= channels) {
            shorts.get(frame)
            var sum = 0
            for (s in frame) sum += s
            into.add((sum / channels).toShort())
        }
    }

    /**
     * Linear interpolation, which is enough here: the model's own front end
     * band-limits far below anything the aliasing this leaves behind would
     * reach. A polyphase filter would be the answer if this fed a codec.
     */
    private fun resample(input: ShortArray, from: Int, to: Int): ShortArray {
        if (from == to || input.isEmpty()) return input
        val outLength = ((input.size.toLong() * to) / from).toInt()
        if (outLength <= 0) return ShortArray(0)

        val output = ShortArray(outLength)
        val step = from.toDouble() / to
        for (i in 0 until outLength) {
            val pos = i * step
            val left = pos.toInt()
            val right = (left + 1).coerceAtMost(input.size - 1)
            val frac = pos - left
            output[i] = (input[left] * (1 - frac) + input[right] * frac).roundToInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }
        return output
    }

    private fun writeWav(file: File, samples: ShortArray) {
        val dataBytes = samples.size * 2
        RandomAccessFile(file, "rw").use { raf ->
            raf.setLength(0)
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + dataBytes)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)                       // PCM header size
            header.putShort(1)                      // format: PCM
            header.putShort(1)                      // channels: mono
            header.putInt(TARGET_RATE)
            header.putInt(TARGET_RATE * 2)          // byte rate
            header.putShort(2)                      // block align
            header.putShort(16)                     // bits per sample
            header.put("data".toByteArray())
            header.putInt(dataBytes)
            raf.write(header.array())

            val body = ByteBuffer.allocate(dataBytes).order(ByteOrder.LITTLE_ENDIAN)
            for (s in samples) body.putShort(s)
            raf.write(body.array())
        }
    }

    /** Grow-by-doubling short buffer: decode length is not known up front. */
    private class ShortArrayBuilder {
        private var data = ShortArray(TARGET_RATE * 8)
        var size = 0
            private set

        fun add(value: Short) {
            if (size == data.size) data = data.copyOf(data.size * 2)
            data[size++] = value
        }

        fun build(): ShortArray = data.copyOf(size)
    }
}
