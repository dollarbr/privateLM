package com.orailnoor.privatelm

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import java.io.File

/**
 * Turns a video into something a vision model can actually read: a handful of
 * evenly spaced frames, written out as JPEGs.
 *
 * None of the local runtimes take video directly, and pulling in a full
 * transcoder (ffmpeg) to change that would add tens of megabytes to the APK for
 * a job the platform already does — MediaMetadataRetriever decodes frames with
 * the device's own hardware decoders, for any container Android can play.
 *
 * The audio track is not extracted here. Doing that properly needs
 * MediaExtractor + MediaMuxer remuxing, and the speech path already exists for a
 * standalone audio file, so a video's narration is better handled by attaching
 * the audio separately than by half-doing it here.
 */
object VideoFrames {
    /** Frames are downscaled to this on the long edge — vision encoders work at
     *  a few hundred pixels, and full-resolution stills would just be re-encoded
     *  and thrown away. */
    private const val MAX_EDGE = 768

    private const val JPEG_QUALITY = 85

    /**
     * @param path a readable video file
     * @param maxFrames how many stills to take, spread evenly across the runtime
     * @param outputDir where the JPEGs land (the app's cache dir)
     * @return absolute paths of the frames written, in playback order
     */
    fun extract(path: String, maxFrames: Int, outputDir: File): List<String> {
        require(maxFrames > 0) { "maxFrames must be positive" }
        val source = File(path)
        require(source.isFile) { "No such video file: $path" }

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L

            // A video too short (or with no duration metadata) to sample across
            // still has a first frame worth looking at.
            val frameCount = if (durationMs <= 0L) 1 else maxFrames
            val stamp = source.nameWithoutExtension.replace(Regex("""[^A-Za-z0-9_-]"""), "_")
            outputDir.mkdirs()

            val paths = mutableListOf<String>()
            for (i in 0 until frameCount) {
                // Sample at the midpoint of each slice rather than at its edge:
                // the first and last frames of a video are very often black.
                val positionUs = if (durationMs <= 0L) 0L
                    else ((durationMs * 1000L) * (2 * i + 1)) / (2L * frameCount)

                val bitmap = retriever.getFrameAtTime(
                    positionUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                ) ?: continue

                val scaled = downscale(bitmap)
                val out = File(outputDir, "${stamp}_frame$i.jpg")
                out.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }
                if (scaled !== bitmap) scaled.recycle()
                bitmap.recycle()
                paths.add(out.absolutePath)
            }
            return paths
        } finally {
            retriever.release()
        }
    }

    private fun downscale(bitmap: Bitmap): Bitmap {
        val longEdge = maxOf(bitmap.width, bitmap.height)
        if (longEdge <= MAX_EDGE) return bitmap
        val scale = MAX_EDGE.toDouble() / longEdge
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }
}
