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
                    "sizes" -> {
                        val ids = call.argument<List<String>>("ids")
                        if (ids == null) {
                            result.error("bad_args", "sizes needs ids", null)
                        } else {
                            sizes(ids, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Returns an id -> byte-size map for the given MediaStore image ids.
     *
     * photo_manager exposes pixel dimensions but not file size, so the Dart
     * enumerate() batch-queries MediaStore.Images.Media.SIZE here in one cursor
     * pass. Ids that aren't found are simply omitted (Dart defaults them to 0).
     */
    private fun sizes(ids: List<String>, result: MethodChannel.Result) {
        val out = HashMap<String, Long>()
        try {
            if (ids.isEmpty()) {
                result.success(out)
                return
            }
            val placeholders = ids.joinToString(",") { "?" }
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.SIZE,
            )
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                "${MediaStore.Images.Media._ID} IN ($placeholders)",
                ids.toTypedArray(),
                null,
            ).use { cursor ->
                if (cursor != null) {
                    val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                    while (cursor.moveToNext()) {
                        out[cursor.getLong(idCol).toString()] = cursor.getLong(sizeCol)
                    }
                }
            }
            result.success(out)
        } catch (e: Exception) {
            result.error("sizes_failed", e.message, null)
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
