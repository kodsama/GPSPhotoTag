package ai.kodsama.stunda

import android.content.ContentUris
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of the `stunda/photo` method channel.
 *
 * photo_manager handles enumerate/metadata/thumbnail/bytes/delete; the one thing
 * it cannot do is write GPS back. `writeGps` writes EXIF GPS tags onto the
 * MediaStore entry via ExifInterface.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stunda/photo")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "writeGps" -> {
                        val id = call.argument<String>("id")
                        val lat = call.argument<Double>("lat")
                        val lng = call.argument<Double>("lng")
                        if (id == null || lat == null || lng == null) {
                            result.error("bad_args", "writeGps needs id/lat/lng", null)
                        } else {
                            writeGps(id, lat, lng, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun writeGps(id: String, lat: Double, lng: Double, result: MethodChannel.Result) {
        try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLong()
            )
            contentResolver.openFileDescriptor(uri, "rw").use { pfd ->
                if (pfd == null) {
                    result.error("not_found", "asset $id not found", null)
                    return
                }
                val exif = ExifInterface(pfd.fileDescriptor)
                exif.setLatLong(lat, lng)
                exif.saveAttributes()
            }
            result.success(null)
        } catch (e: Exception) {
            // On Android 10+, writing to media the app doesn't own can throw a
            // RecoverableSecurityException that needs a user-consent intent;
            // surface it so the Dart layer can report it.
            result.error("write_failed", e.message, null)
        }
    }
}
