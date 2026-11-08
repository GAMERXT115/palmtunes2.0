import Flutter
import UIKit
import CoreVideo
import MediaPipeTasksVision

/// Hand landmarks on iOS: the same MediaPipe model the Android side uses.
/// Dart sends one camera frame (BGRA) per call over the "palmtunes/hands"
/// channel and gets back 63 numbers (21 x, y, z triples) per detected hand,
/// in the upright, un-mirrored image.
public class PalmtunesHandsPlugin: NSObject, FlutterPlugin {
  private var modelPath: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "palmtunes/hands",
      binaryMessenger: registrar.messenger()
    )
    let instance = PalmtunesHandsPlugin()
    // The model ships as a normal Flutter asset (assets/hand_landmarker.task).
    let key = registrar.lookupKey(forAsset: "assets/hand_landmarker.task")
    instance.modelPath = Bundle.main.path(forResource: key, ofType: nil)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let queue = DispatchQueue(label: "palmtunes.hands", qos: .userInitiated)
  private var landmarker: HandLandmarker?

  private func ensureLandmarker() -> HandLandmarker? {
    if let existing = landmarker { return existing }
    guard let path = modelPath else {
      NSLog("[PalmTunes] assets/hand_landmarker.task is missing from the app")
      return nil
    }
    let options = HandLandmarkerOptions()
    options.baseOptions.modelAssetPath = path
    options.runningMode = .image
    options.numHands = 2
    options.minHandDetectionConfidence = 0.7
    options.minHandPresenceConfidence = 0.5
    options.minTrackingConfidence = 0.5
    landmarker = try? HandLandmarker(options: options)
    return landmarker
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "detect":
      guard
        let args = call.arguments as? [String: Any],
        let data = args["bytes"] as? FlutterStandardTypedData,
        let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let bytesPerRow = args["bytesPerRow"] as? Int
      else {
        result([])
        return
      }
      let rotation = args["rotation"] as? Int ?? 90
      queue.async { [weak self] in
        let hands = self?.detect(
          bytes: data.data,
          width: width,
          height: height,
          bytesPerRow: bytesPerRow,
          rotation: rotation
        ) ?? []
        DispatchQueue.main.async { result(hands) }
      }
    case "close":
      queue.async { [weak self] in self?.landmarker = nil }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func detect(bytes: Data, width: Int, height: Int, bytesPerRow: Int, rotation: Int) -> [[Double]] {
    guard let landmarker = ensureLandmarker() else { return [] }

    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    guard
      CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
      let pixelBuffer = buffer
    else { return [] }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let dst = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
      let copyBytes = min(dstStride, bytesPerRow, width * 4)
      bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        guard let base = src.baseAddress else { return }
        for row in 0..<height {
          memcpy(dst + row * dstStride, base + row * bytesPerRow, copyBytes)
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let orientation: UIImage.Orientation
    switch rotation {
    case 90: orientation = .right
    case 180: orientation = .down
    case 270: orientation = .left
    default: orientation = .up
    }

    do {
      let image = try MPImage(pixelBuffer: pixelBuffer, orientation: orientation)
      let output = try landmarker.detect(image: image)
      return output.landmarks.map { hand in
        hand.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
      }
    } catch {
      NSLog("[PalmTunes] hand detection failed: \(error)")
      return []
    }
  }
}
