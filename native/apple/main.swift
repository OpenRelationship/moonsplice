// moonsplice-apple: what macOS already knows how to see and hear, as files the resolve phase reads.
//
// Every command reads a media file and writes either a JSON fact file or a folder of mask
// frames. Nothing here ships a model: these are Apple's own (Vision, Sound Analysis), on the
// Neural Engine where the OS puts them. .robot/docs/capcut-parity.robot §2, "Apple frameworks first".
//
//   moonsplice-apple segment IN DIR [--kind person|subject] [--fps N]   mask PNGs, one a frame
//   moonsplice-apple saliency IN OUT.json [--fps N]                     the attended region a frame
//   moonsplice-apple faces IN OUT.json [--fps N]                        face boxes a frame
//   moonsplice-apple aesthetics IN OUT.json [--fps N]                   a score a sampled frame
//   moonsplice-apple pose IN OUT.json [--fps N]                         body joints a frame
//   moonsplice-apple sound IN OUT.json                                  sound events over time
//   moonsplice-apple slowmo IN OUT.mov --factor F | motionblur IN OUT.mov --strength S  (vt.swift)
//
// Boxes are normalised 0..1 with the origin top-left (Vision's is bottom-left; flipped here).

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SoundAnalysis
import UniformTypeIdentifiers
import Vision

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("moonsplice-apple: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

func arg(_ name: String, _ d: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return d
}

func writeJSON(_ obj: Any, _ path: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { fail("cannot encode json") }
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("cannot write \(path): \(error)") }
}

func r4(_ x: CGFloat) -> Double { (Double(x) * 10000).rounded() / 10000 }

func box(_ b: CGRect) -> [Double] { [r4(b.minX), r4(1 - b.maxY), r4(b.width), r4(b.height)] }

/// Frames of a video at `fps` (0: every frame), as (seconds, pixel buffer).
func frames(_ path: String, fps: Double, _ body: (Double, CVPixelBuffer) -> Void) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    asset.loadTracks(withMediaType: .video) { t, _ in track = t?.first; sem.signal() }
    sem.wait()
    guard let track else { fail("no video in \(path)") }
    guard let reader = try? AVAssetReader(asset: asset) else { fail("cannot read \(path)") }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    reader.startReading()
    var next = 0.0
    while let s = out.copyNextSampleBuffer() {
        guard let px = CMSampleBufferGetImageBuffer(s) else { continue }
        let t = CMSampleBufferGetPresentationTimeStamp(s).seconds
        if fps > 0 && t + 1e-6 < next { continue }
        next = fps > 0 ? next + 1.0 / fps : t
        autoreleasepool { body(t, px) }
    }
}

let ci = CIContext(options: [.workingColorSpace: NSNull()])

func savePNG(_ img: CIImage, _ path: String) {
    guard let cg = ci.createCGImage(img, from: img.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { fail("mask render") }
    guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(dst, cg, nil)
    CGImageDestinationFinalize(dst)
}

func segment(_ input: String, _ dir: String) {
    let kind = arg("--kind", "person")
    let fps = Double(arg("--fps", "0")) ?? 0
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var n = 0
    frames(input, fps: fps) { _, px in
        n += 1
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
        var mask: CIImage?
        if kind == "person" {
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? handler.perform([req])
            if let m = req.results?.first?.pixelBuffer { mask = CIImage(cvPixelBuffer: m) }
        } else {
            let req = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([req])
            if let obs = req.results?.first,
               let m = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                mask = CIImage(cvPixelBuffer: m)
            }
        }
        var img = mask ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let sx = CGFloat(w) / img.extent.width, sy = CGFloat(h) / img.extent.height
        img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        savePNG(img, String(format: "%@/%05d.png", dir, n))
    }
    writeJSON(["frames": n, "kind": kind, "src": "apple/vision/" + (kind == "person" ? "person-segmentation" : "foreground-instance-mask")], dir + "/mask.json")
}

func perFrame(_ input: String, _ outPath: String, src: String, _ make: (VNImageRequestHandler) -> Any?) {
    let fps = Double(arg("--fps", "4")) ?? 4
    var rows: [[String: Any]] = []
    frames(input, fps: fps) { t, px in
        let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
        if let v = make(handler) { rows.append(["t": (t * 1000).rounded() / 1000, "v": v]) }
    }
    writeJSON(["src": src, "fps": fps, "frames": rows], outPath)
}

func saliency(_ i: String, _ o: String) {
    perFrame(i, o, src: "apple/vision/attention-saliency") { h in
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        try? h.perform([req])
        return (req.results?.first?.salientObjects ?? []).map { ["box": box($0.boundingBox), "confidence": r4(CGFloat($0.confidence))] }
    }
}

func faces(_ i: String, _ o: String) {
    perFrame(i, o, src: "apple/vision/face-rectangles") { h in
        let req = VNDetectFaceRectanglesRequest()
        try? h.perform([req])
        return (req.results ?? []).map { ["box": box($0.boundingBox), "confidence": r4(CGFloat($0.confidence))] }
    }
}

func aesthetics(_ i: String, _ o: String) {
    perFrame(i, o, src: "apple/vision/aesthetics") { h in
        let req = VNCalculateImageAestheticsScoresRequest()
        try? h.perform([req])
        guard let r = req.results?.first else { return nil }
        return ["score": r4(CGFloat(r.overallScore)), "utility": r.isUtility]
    }
}

func pose(_ i: String, _ o: String) {
    perFrame(i, o, src: "apple/vision/body-pose") { h in
        let req = VNDetectHumanBodyPoseRequest()
        try? h.perform([req])
        return (req.results ?? []).map { obs -> [String: Any] in
            var joints: [String: [Double]] = [:]
            if let pts = try? obs.recognizedPoints(.all) {
                for (k, p) in pts where p.confidence > 0.2 {
                    joints[k.rawValue.rawValue] = [r4(p.location.x), r4(1 - p.location.y), r4(CGFloat(p.confidence))]
                }
            }
            return ["joints": joints]
        }
    }
}

final class SoundSink: NSObject, SNResultsObserving {
    var rows: [[String: Any]] = []
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let top = r.classifications.prefix(3).filter { $0.confidence > 0.3 }
        if top.isEmpty { return }
        rows.append([
            "t": (r.timeRange.start.seconds * 1000).rounded() / 1000,
            "d": (r.timeRange.duration.seconds * 1000).rounded() / 1000,
            "labels": top.map { ["label": $0.identifier, "confidence": r4(CGFloat($0.confidence))] },
        ])
    }
}

func sound(_ i: String, _ o: String) {
    guard let analyzer = try? SNAudioFileAnalyzer(url: URL(fileURLWithPath: i)) else { fail("cannot open audio in \(i)") }
    guard let req = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { fail("no sound classifier") }
    req.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 1000)
    req.overlapFactor = 0.5
    let sink = SoundSink()
    do { try analyzer.add(req, withObserver: sink) } catch { fail("sound analysis: \(error)") }
    analyzer.analyze()
    writeJSON(["src": "apple/sound-analysis/version1", "events": sink.rows], o)
}

let a = CommandLine.arguments
guard a.count >= 4 else { fail("usage: moonsplice-apple segment|saliency|faces|aesthetics|pose|sound IN OUT [options]") }
switch a[1] {
case "segment": segment(a[2], a[3])
case "saliency": saliency(a[2], a[3])
case "faces": faces(a[2], a[3])
case "aesthetics": aesthetics(a[2], a[3])
case "pose": pose(a[2], a[3])
case "sound": sound(a[2], a[3])
case "slowmo": if #available(macOS 15.4, *) { slowmo(a[2], a[3]) } else { fail("slowmo needs macOS 15.4") }
case "motionblur": if #available(macOS 15.4, *) { motionblur(a[2], a[3]) } else { fail("motionblur needs macOS 15.4") }
default: fail("unknown command \(a[1])")
}
