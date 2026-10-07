// VideoToolbox's frame processors (macOS 15.4+): slow motion by frame-rate conversion, and
// motion blur, on Apple's own models. Written by AVAssetWriter as HEVC, so encoding is hardware
// too. The Swift-refined wrappers live in the macOS 26 overlay, which a 15.x runtime lacks, so
// this calls the Objective-C names (`__`). The portable fallback (ffmpeg minterpolate) lives in the resolve phase, for hosts that
// have no VideoToolbox.
//
//   moonsplice-apple slowmo IN OUT.mov --factor 4       F times as many frames, same rate: F x slower
//   moonsplice-apple motionblur IN OUT.mov --strength 50

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

struct Source {
    let frames: [CVPixelBuffer]
    let fps: Double
    let w: Int
    let h: Int
}

func readAll(_ path: String, format: OSType) -> Source {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    asset.loadTracks(withMediaType: .video) { t, _ in track = t?.first; sem.signal() }
    sem.wait()
    guard let track else { fail("no video in \(path)") }
    var fps: Float = 30
    track.loadValuesAsynchronously(forKeys: ["nominalFrameRate"]) { sem.signal() }
    sem.wait()
    fps = track.nominalFrameRate
    guard let reader = try? AVAssetReader(asset: asset) else { fail("cannot read \(path)") }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: format,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    reader.add(out)
    reader.startReading()
    var frames: [CVPixelBuffer] = []
    while let s = out.copyNextSampleBuffer() {
        if let px = CMSampleBufferGetImageBuffer(s) { frames.append(px) }
    }
    guard let first = frames.first else { fail("no frames in \(path)") }
    return Source(frames: frames, fps: Double(fps > 0 ? fps : 30), w: CVPixelBufferGetWidth(first), h: CVPixelBufferGetHeight(first))
}

final class Writer {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var n: Int64 = 0
    let fps: Double

    init(_ path: String, w: Int, h: Int, fps: Double) {
        try? FileManager.default.removeItem(atPath: path)
        guard let wr = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov) else { fail("cannot write \(path)") }
        writer = wr
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        self.fps = fps
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ px: CVPixelBuffer) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        if !adaptor.append(px, withPresentationTime: CMTime(seconds: Double(n) / fps, preferredTimescale: 240000)) { fail("append failed: \(String(describing: writer.error))") }
        n += 1
    }

    func finish() {
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { fail("writing failed: \(String(describing: writer.error))") }
    }
}

func pool(_ attrs: [String: Any]) -> CVPixelBufferPool {
    var p: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
    guard let p else { fail("no pixel buffer pool") }
    return p
}

func buffer(_ p: CVPixelBufferPool) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, p, &b)
    guard let b else { fail("no pixel buffer") }
    return b
}

@available(macOS 15.4, *)
func run(_ proc: VTFrameProcessor, _ params: any VTFrameProcessorParameters) {
    let sem = DispatchSemaphore(value: 0)
    var err: Error?
    proc.process(parameters: params) { _, e in err = e; sem.signal() }
    sem.wait()
    if let err { fail("VideoToolbox: \(err)") }
}

@available(macOS 15.4, *)
func slowmo(_ input: String, _ output: String) {
    let factor = max(2, Int(arg("--factor", "2")) ?? 2)
    let probe = readAll(input, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    guard let cfg = VTFrameRateConversionConfiguration(frameWidth: probe.w, frameHeight: probe.h, usePrecomputedFlow: false,
        qualityPrioritization: .quality, revision: .revision1) else { fail("frame-rate conversion is not available here") }
    let fmt = (cfg.__frameSupportedPixelFormats.first?.uint32Value ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let src = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? probe : readAll(input, format: fmt)
    let proc = VTFrameProcessor()
    do { try proc.startSession(configuration: cfg) } catch { fail("VideoToolbox session: \(error)") }
    let dst = pool(cfg.destinationPixelBufferAttributes)
    let out = Writer(output, w: src.w, h: src.h, fps: src.fps)
    let phases = (1..<factor).map { Float($0) / Float(factor) }
    for i in 0..<src.frames.count {
        out.append(src.frames[i])
        guard i + 1 < src.frames.count else { break }
        let t0 = CMTime(value: Int64(i), timescale: Int32(src.fps.rounded()))
        let t1 = CMTime(value: Int64(i + 1), timescale: Int32(src.fps.rounded()))
        guard let a = VTFrameProcessorFrame(buffer: src.frames[i], presentationTimeStamp: t0),
              let b = VTFrameProcessorFrame(buffer: src.frames[i + 1], presentationTimeStamp: t1) else { fail("frame wrap") }
        let outs = phases.compactMap { ph -> VTFrameProcessorFrame? in
            VTFrameProcessorFrame(buffer: buffer(dst), presentationTimeStamp: CMTimeAdd(t0, CMTimeMultiplyByFloat64(CMTimeSubtract(t1, t0), multiplier: Float64(ph))))
        }
        guard let params = VTFrameRateConversionParameters(__sourceFrame: a, nextFrame: b, opticalFlow: nil,
            interpolationPhase: phases.map { NSNumber(value: $0) }, submissionMode: .sequential, destinationFrames: outs) else { fail("parameters") }
        run(proc, params)
        for o in outs { out.append(o.buffer) }
    }
    proc.endSession()
    out.finish()
    writeJSON(["src": "apple/videotoolbox/frame-rate-conversion", "factor": factor, "frames": out.n, "fps": src.fps], output + ".json")
}

@available(macOS 15.4, *)
func motionblur(_ input: String, _ output: String) {
    let strength = Int(arg("--strength", "50")) ?? 50
    let probe = readAll(input, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    guard let cfg = VTMotionBlurConfiguration(frameWidth: probe.w, frameHeight: probe.h, usePrecomputedFlow: false,
        qualityPrioritization: .quality, revision: .revision1) else { fail("motion blur is not available here") }
    let fmt = (cfg.__frameSupportedPixelFormats.first?.uint32Value ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let src = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? probe : readAll(input, format: fmt)
    let proc = VTFrameProcessor()
    do { try proc.startSession(configuration: cfg) } catch { fail("VideoToolbox session: \(error)") }
    let dst = pool(cfg.destinationPixelBufferAttributes)
    let out = Writer(output, w: src.w, h: src.h, fps: src.fps)
    let ts = { (i: Int) in CMTime(value: Int64(i), timescale: Int32(src.fps.rounded())) }
    for i in 0..<src.frames.count {
        guard let cur = VTFrameProcessorFrame(buffer: src.frames[i], presentationTimeStamp: ts(i)) else { fail("frame wrap") }
        let next = i + 1 < src.frames.count ? VTFrameProcessorFrame(buffer: src.frames[i + 1], presentationTimeStamp: ts(i + 1)) : nil
        let prev = i > 0 ? VTFrameProcessorFrame(buffer: src.frames[i - 1], presentationTimeStamp: ts(i - 1)) : nil
        guard let o = VTFrameProcessorFrame(buffer: buffer(dst), presentationTimeStamp: ts(i)),
              let params = VTMotionBlurParameters(sourceFrame: cur, nextFrame: next, previousFrame: prev, nextOpticalFlow: nil,
                  previousOpticalFlow: nil, motionBlurStrength: strength, submissionMode: .sequential, destinationFrame: o) else { fail("parameters") }
        run(proc, params)
        out.append(o.buffer)
    }
    proc.endSession()
    out.finish()
    writeJSON(["src": "apple/videotoolbox/motion-blur", "strength": strength, "frames": out.n], output + ".json")
}
