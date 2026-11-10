import Flutter
import UIKit
import CoreVideo
import AVFoundation
import AVKit
import MediaPipeTasksVision

/// Hand landmarks on iOS: the same MediaPipe model the Android side uses.
/// Dart sends one camera frame (BGRA) per call over the "palmtunes/hands"
/// channel and gets back 63 numbers (21 x, y, z triples) per detected hand,
/// in the upright, un-mirrored image.
public class PalmtunesHandsPlugin: NSObject, FlutterPlugin {
  private var modelPath: String?
  private static var pipManager: PipManager?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "palmtunes/hands",
      binaryMessenger: registrar.messenger()
    )
    let instance = PalmtunesHandsPlugin()
    let pipChannel = FlutterMethodChannel(
      name: "palmtunes/pip",
      binaryMessenger: registrar.messenger()
    )
    pipManager = PipManager(channel: pipChannel)
    let bassChannel = FlutterMethodChannel(
      name: "palmtunes/bass",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: bassChannel)
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
    case "envelope":
      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterError(code: "args", message: "path is missing", details: nil))
        return
      }
      let windowMs = args["windowMs"] as? Double ?? 20.0
      queue.async { [weak self] in
        let env = self?.bassEnvelope(path: path, windowMs: windowMs)
        DispatchQueue.main.async {
          if let env = env {
            result(env)
          } else {
            result(FlutterError(code: "analyze", message: "Could not read this audio", details: nil))
          }
        }
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

  /// Decodes the audio (AVAssetReader) to 8 kHz mono, runs the 150 Hz 3-pole
  /// low-pass and returns the RMS level in dB for every window.
  private func bassEnvelope(path: String, windowMs: Double) -> FlutterStandardTypedData? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first,
          let reader = try? AVAssetReader(asset: asset) else { return nil }
    let rate = 8000.0
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }

    let alpha = Float(1.0 - exp(-2.0 * Double.pi * 150.0 / rate))
    let window = max(1, Int((rate * windowMs / 1000.0).rounded()))
    var state = [Float](repeating: 0, count: 3)
    var sum: Double = 0
    var count = 0
    var out = [Double]()

    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      if length <= 0 { continue }
      var data = Data(count: length)
      let status = data.withUnsafeMutableBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
      }
      if status != kCMBlockBufferNoErr { continue }
      data.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for i in 0..<samples.count {
          var v = Float(samples[i]) / 32768.0
          for k in 0..<3 {
            state[k] += alpha * (v - state[k])
            v = state[k]
          }
          sum += Double(v * v)
          count += 1
          if count >= window {
            let rms = (sum / Double(count)).squareRoot()
            out.append(20.0 * log10(rms + 1e-9))
            sum = 0
            count = 0
          }
        }
      }
    }
    if out.isEmpty { return nil }
    let bytes = out.withUnsafeBufferPointer { Data(buffer: $0) }
    return FlutterStandardTypedData(float64: bytes)
  }
}


/// Picture in Picture: a silent AVPlayer plays the same video behind the app
/// so iOS can float it when the app is left. Sound still comes from Dart's
/// player; play/pause and "back to app" in the PiP window are sent to Dart.
final class PipManager: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var layer: AVPlayerLayer?
  private var host: UIView?
  private var pip: AVPictureInPictureController?
  private var statusObs: NSKeyValueObservation?
  private var active = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "prepare":
      DispatchQueue.main.async { self.prepare(args) }
      result(nil)
    case "sync":
      DispatchQueue.main.async { self.sync(args) }
      result(nil)
    case "start":
      DispatchQueue.main.async {
        if let pip = self.pip, pip.isPictureInPicturePossible, !pip.isPictureInPictureActive {
          pip.startPictureInPicture()
        }
      }
      result(nil)
    case "dispose":
      DispatchQueue.main.async { self.teardown() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func keyWindow() -> UIWindow? {
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func prepare(_ args: [String: Any]) {
    teardown()
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let window = keyWindow() else { return }
    let positionMs = args["positionMs"] as? Int ?? 0
    let playing = args["playing"] as? Bool ?? false

    var options: [String: Any] = [:]
    if let headers = args["headers"] as? [String: String], !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    let p = AVPlayer(playerItem: item)
    p.isMuted = true
    p.allowsExternalPlayback = false
    p.seek(
      to: CMTime(value: Int64(positionMs), timescale: 1000),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    if playing { p.play() }

    let l = AVPlayerLayer(player: p)
    l.videoGravity = .resizeAspect
    let h = UIView(frame: window.bounds)
    h.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    h.isUserInteractionEnabled = false
    h.backgroundColor = .black
    l.frame = h.bounds
    h.layer.addSublayer(l)
    // Behind the Flutter view, but still part of the window.
    window.insertSubview(h, at: 0)

    let c = AVPictureInPictureController(playerLayer: l)
    c?.delegate = self
    if #available(iOS 14.2, *) {
      c?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    statusObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
      guard let self = self, self.active else { return }
      self.channel.invokeMethod(
        "pipPlaying",
        arguments: ["playing": pl.timeControlStatus != .paused]
      )
    }

    player = p
    layer = l
    host = h
    pip = c
  }

  private func sync(_ args: [String: Any]) {
    guard let p = player else { return }
    let positionMs = args["positionMs"] as? Int ?? 0
    let playing = args["playing"] as? Bool ?? false
    let currentMs = p.currentTime().seconds * 1000
    if abs(currentMs - Double(positionMs)) > 1200 {
      p.seek(
        to: CMTime(value: Int64(positionMs), timescale: 1000),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
    if playing && p.timeControlStatus == .paused {
      p.play()
    } else if !playing && p.timeControlStatus != .paused {
      p.pause()
    }
    layer?.frame = host?.bounds ?? .zero
  }

  private func teardown() {
    if let c = pip, c.isPictureInPictureActive { c.stopPictureInPicture() }
    statusObs = nil
    player?.pause()
    layer?.removeFromSuperlayer()
    host?.removeFromSuperview()
    player = nil
    layer = nil
    host = nil
    pip = nil
    active = false
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
    active = true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
    active = false
    let ms = Int((player?.currentTime().seconds ?? 0) * 1000)
    let playing = (player?.timeControlStatus ?? .paused) != .paused
    channel.invokeMethod("pipStopped", arguments: ["positionMs": ms, "playing": playing])
  }

  func pictureInPictureController(
    _ c: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler handler: @escaping (Bool) -> Void
  ) {
    handler(true)
  }
}
