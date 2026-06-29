import CoreLocation
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "StundaPhotoChannel") {
      Self.registerPhotoChannel(messenger: registrar.messenger())
    }
  }

  /// Native side of the `stunda/photo` method channel.
  ///
  /// photo_manager handles enumerate/metadata/thumbnail/bytes/delete; the one
  /// thing it cannot do is write GPS back onto an asset. `writeGps` sets the
  /// asset's location via `PHAssetChangeRequest`, which records a Photos edit.
  private static func registerPhotoChannel(messenger: FlutterBinaryMessenger) {
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
      case "sizes":
        guard let args = call.arguments as? [String: Any],
          let ids = args["ids"] as? [String]
        else {
          result(FlutterError(code: "bad_args", message: "sizes needs ids", details: nil))
          return
        }
        sizes(ids: ids, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Returns an id -> byte-size map for the given PHAsset local identifiers.
  ///
  /// photo_manager exposes pixel dimensions but not file size, so the Dart
  /// enumerate() batch-queries the byte size here from each asset's primary
  /// PHAssetResource (`fileSize`, a private NSNumber key). Ids that can't be
  /// sized are omitted (Dart defaults them to 0).
  private static func sizes(ids: [String], result: @escaping FlutterResult) {
    var out: [String: Int] = [:]
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    assets.enumerateObjects { asset, _, _ in
      let resources = PHAssetResource.assetResources(for: asset)
      // Prefer the full-sized photo resource; fall back to the first resource.
      let resource = resources.first { $0.type == .photo } ?? resources.first
      if let value = resource?.value(forKey: "fileSize") as? NSNumber {
        out[asset.localIdentifier] = value.intValue
      }
    }
    result(out)
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
