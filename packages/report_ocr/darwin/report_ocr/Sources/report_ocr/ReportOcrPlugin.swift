#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import ImageIO
import Vision

public class ReportOcrPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "report_ocr", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(ReportOcrPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognize",
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let blocks = try Self.recognize(path: path)
        DispatchQueue.main.async { result(blocks) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private static func recognize(path: String) throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw NSError(domain: "report_ocr", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read image"])
    }
    // Respect EXIF orientation so phone photos are read upright.
    var orientation = CGImagePropertyOrientation.up
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let raw = props[kCGImagePropertyOrientation] as? UInt32,
       let parsed = CGImagePropertyOrientation(rawValue: raw) {
      orientation = parsed
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Lab values and abbreviations (MCHC, RDW-CV) get "corrected" into words otherwise.
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    try handler.perform([request])

    return (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      let box = observation.boundingBox  // normalised, origin bottom-left
      return [
        "text": text,
        "x": box.minX,
        "y": 1 - box.maxY,
        "w": box.width,
        "h": box.height,
      ]
    }
  }
}
