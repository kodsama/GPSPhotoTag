import CoreLocation
import Flutter
import Photos

/// Native side of the `stunda/photo` method channel.
///
/// photo_manager handles enumerate/metadata/thumbnail/bytes/delete; the one
/// thing it cannot do is write GPS back onto an asset. `writeGps` sets the
/// asset's location via `PHAssetChangeRequest`, which records a Photos edit.
enum StundaPhotoChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "stunda/photo", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "writeGps":
        guard let args = call.arguments as? [String: Any],
          let id = args["id"] as? String,
          let lat = args["lat"] as? Double,
          let lng = args["lng"] as? Double
        else {
          result(
            FlutterError(code: "bad_args", message: "writeGps needs id/lat/lng", details: nil))
          return
        }
        writeGps(id: id, lat: lat, lng: lng, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func writeGps(
    id: String, lat: Double, lng: Double, result: @escaping FlutterResult
  ) {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard let asset = assets.firstObject else {
      result(FlutterError(code: "not_found", message: "asset \(id) not found", details: nil))
      return
    }
    PHPhotoLibrary.shared().performChanges(
      {
        let request = PHAssetChangeRequest(for: asset)
        request.location = CLLocation(latitude: lat, longitude: lng)
      },
      completionHandler: { success, error in
        DispatchQueue.main.async {
          if success {
            result(nil)
          } else {
            result(
              FlutterError(
                code: "write_failed",
                message: error?.localizedDescription ?? "unknown error",
                details: nil))
          }
        }
      })
  }
}
