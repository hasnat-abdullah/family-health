package com.familyhealth.report_ocr

import android.content.Context
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** On-device OCR using the bundled ML Kit Latin text model. */
class ReportOcrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "report_ocr")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (call.method != "recognize" || path == null) {
            result.notImplemented()
            return
        }
        val image = try {
            InputImage.fromFilePath(context, Uri.fromFile(File(path)))
        } catch (e: Exception) {
            result.error("ocr_failed", e.message, null)
            return
        }
        // InputImage applies EXIF rotation, so width/height are of the upright image.
        val width = image.width.toDouble()
        val height = image.height.toDouble()
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer.process(image)
            .addOnSuccessListener { text ->
                val blocks = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
                    val box = line.boundingBox ?: return@mapNotNull null
                    mapOf(
                        "text" to line.text,
                        "x" to box.left / width,
                        "y" to box.top / height,
                        "w" to box.width() / width,
                        "h" to box.height() / height,
                    )
                }
                result.success(blocks)
            }
            .addOnFailureListener { e -> result.error("ocr_failed", e.message, null) }
            .addOnCompleteListener { recognizer.close() }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
