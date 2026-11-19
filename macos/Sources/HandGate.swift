// HandGate.swift — stage 1 of the battery-first detector (CameraGate.swift).
//
// While the HUD is closed the camera delivers its slowest rate (15 fps on most Mac
// cameras) in its native biplanar YUV, and CameraGate hands this gate 5 frames a
// second. Each goes through, cheapest first:
//   1. darkness: 64x48 luma thumbnail read straight from the Y plane; mean < 6 and
//      99th percentile < 22 -> dark, nothing else runs (same rule and thresholds as
//      the engine, in full-range luma);
//   2. motion:   mean |diff - median diff| between consecutive thumbnails > 3.0;
//   3. Apple Vision hand pose, only when something moved and nobody is typing
//      (hands on the keyboard are not waving). When Vision sees part of a hand (a
//      hand rising into view, blurred by its own movement), the gate watches closely
//      for 0.6 s: every camera frame (15 fps) instead of every third, so the hand's
//      first clear frame is not missed (measured: without this a wave opened the HUD
//      up to 0.6 s later, as the engine joined the wave a swing late);
//   4. a clear hand only. Vision's observation confidence is no use for this: it is
//      1.0 for almost every observation, even one without a single visible joint. A
//      detection counts when at least 10 of its 21 joints have a confidence of 0.5
//      or more, it has a plausible size, it is not a small blob inside a face (the
//      face check runs only for a borderline detection), and it is not a hand that
//      sat still in the same spot the last time the engine looked at it (a chin
//      resting on a hand, a hand-like shape in the background);
// The first clear frame switches the camera to active mode for a short while; the
// engine (MediaPipe, which tells real hands from phantoms far better) then decides
// whether it needs more. Waiting for a second clear frame here was measured to delay
// a wave by ~1 s: the engine joined the wave a swing late.
// Measured on the calibration clips: a Vision hand run costs ~3-6 ms of CPU, a face
// check ~4-10 ms, everything before Vision ~0.04 ms.

import CoreGraphics
import CoreVideo
import Vision

final class HandGate {
    static let thumbWidth = 64, thumbHeight = 48
    static let darkMean: Float = 6.0, darkP99: Float = 22.0   // same as the engine (config dark_mean / dark_p99)
    static let motionThreshold: Float = 3.0
    static let jointConfidence: Float = 0.5      // a joint counts as seen at this confidence
    static let minJoints = 10                    // joints (of 21) a clear hand shows
    static let sureJoints = 16                   // from this many on, no face check
    static let minSize: CGFloat = 0.05           // the hand's box, longer side, as a fraction of the frame
    static let faceInside: CGFloat = 0.8         // a detection this much inside a face's box...
    static let faceSmall: CGFloat = 0.4          // ...and this small next to it (area) is the face, not a hand
    static let restingDistance: CGFloat = 0.06   // a declined hand still this close to its spot is resting
    static let restingMemory: TimeInterval = 60
    static let partialJoints = 1                 // a detection with this many joints (but < minJoints) is a partial hand:
    static let watchLength: TimeInterval = 0.6   // it starts a close watch this long...
    static let watchMax: TimeInterval = 1.5      // ...one watch at most this long in all...
    static let watchSpacing: TimeInterval = 2.0  // ...and starts at most this often (bounds Vision while someone moves a lot)

    /// A clear hand, in Vision's normalised coordinates (origin bottom left).
    struct Hand: Equatable {
        let center: CGPoint
        let size: CGFloat
        let joints: Int
    }

    enum Verdict: Equatable {
        case dark, firstFrame, still(Float), typing, noHand(Float)
        case rejected(String)        // Vision saw something, but not a clear hand
        case hand(Hand)              // a clear hand: switch to active
    }

    private var prevThumb: [Float]?
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2       // a resting hand must not hide a waving one
        return r
    }()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var resting: [(hand: Hand, until: TimeInterval)] = []
    private var watchUntil: TimeInterval = -1, watchStarted: TimeInterval = -1e9

    // Counters for the once-a-minute power log (CameraGate reads and resets them).
    var visionRuns = 0, faceRuns = 0, rejections = 0, hands = 0

    /// Forget the previous thumbnail and any close watch (after a mode change).
    func reset() {
        prevThumb = nil
        watchUntil = -1
    }

    /// True while the gate wants every camera frame rather than 5 a second.
    func watching(at now: TimeInterval) -> Bool { now <= watchUntil }

    private func startWatch(_ now: TimeInterval) {
        if watching(at: now) {
            watchUntil = min(now + Self.watchLength, watchStarted + Self.watchMax)
        } else if now - watchStarted >= Self.watchSpacing {
            watchStarted = now
            watchUntil = now + Self.watchLength
        }
    }

    /// The engine looked at this hand and did not want full-rate frames for it:
    /// ignore it for a while, as long as it stays where it is.
    func decline(_ hand: Hand, now: TimeInterval) {
        resting.removeAll { $0.until <= now || Self.sameSpot($0.hand, hand) }
        resting.append((hand, now + Self.restingMemory))
        if resting.count > 4 { resting.removeFirst() }
    }

    /// Run Vision once on a blank frame. The first request after install (or an OS
    /// update) makes the system prepare the models for the Neural Engine, which can
    /// take seconds; doing it up front keeps the first real gesture fast.
    func warmUp() {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb) == kCVReturnSuccess,
              let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
                memset(base, plane == 0 ? 16 : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]).perform([handRequest, faceRequest])
    }

    /// One idle frame. `typing`: a key was pressed a moment ago, so Vision is skipped.
    func evaluate(_ pb: CVPixelBuffer, now: TimeInterval, typing: Bool) -> Verdict {
        guard let thumb = Self.thumbnail(pb) else { return .firstFrame }
        if Self.isDark(thumb) {
            prevThumb = nil
            return .dark
        }
        defer { prevThumb = thumb }
        guard let prev = prevThumb, prev.count == thumb.count else { return .firstFrame }
        let motion = Self.motion(thumb, prev)
        let watching = self.watching(at: now)
        // (while watching closely, a hand that pauses - a fist before it opens - still counts)
        guard watching || motion > Self.motionThreshold else { return .still(motion) }
        if typing {
            watchUntil = -1
            return .typing
        }
        visionRuns += 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([handRequest]) } catch { return .noHand(motion) }
        let observations = handRequest.results ?? []
        guard !observations.isEmpty else { return .noHand(motion) }
        var why = "weak"
        var best: Hand?
        var partial = false          // (an observation without a single joint is noise, not part of a hand)
        for obs in observations {
            switch clearHand(obs, handler, now) {
            case .success(let h): if h.joints > (best?.joints ?? -1) { best = h }
            case .failure(let reason):
                why = reason.text
                if reason.joints >= Self.partialJoints { partial = true }
            }
        }
        guard let hand = best else {
            rejections += 1
            if partial { startWatch(now) }
            return .rejected(why)
        }
        hands += 1
        watchUntil = -1
        return .hand(hand)
    }

    private struct Reason: Error {
        let text: String
        var joints = 0                // a partial hand (worth a closer look) has a few
    }

    private func clearHand(_ obs: VNHumanHandPoseObservation, _ handler: VNImageRequestHandler,
                           _ now: TimeInterval) -> Result<Hand, Reason> {
        guard let points = try? obs.recognizedPoints(.all) else { return .failure(Reason(text: "no joints")) }
        var joints = 0
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for p in points.values where p.confidence >= 0.3 {
            if p.confidence >= Self.jointConfidence { joints += 1 }
            minX = min(minX, p.location.x); maxX = max(maxX, p.location.x)
            minY = min(minY, p.location.y); maxY = max(maxY, p.location.y)
        }
        guard joints >= Self.minJoints else { return .failure(Reason(text: "weak (\(joints) joints)", joints: joints)) }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let size = max(box.width, box.height)
        guard size >= Self.minSize else { return .failure(Reason(text: "tiny")) }
        let hand = Hand(center: CGPoint(x: box.midX, y: box.midY), size: size, joints: joints)
        resting.removeAll { $0.until <= now }
        if resting.contains(where: { Self.sameSpot($0.hand, hand) }) { return .failure(Reason(text: "resting")) }
        if joints < Self.sureJoints && box.width > 0 && box.height > 0 {
            faceRuns += 1
            if (try? handler.perform([faceRequest])) != nil {
                for face in faceRequest.results ?? [] {
                    let f = face.boundingBox
                    let overlap = box.intersection(f)
                    guard !overlap.isNull else { continue }
                    let inside = overlap.width * overlap.height / (box.width * box.height)
                    let small = box.width * box.height / max(f.width * f.height, 1e-6)
                    if inside >= Self.faceInside && small < Self.faceSmall { return .failure(Reason(text: "face")) }
                }
            }
        }
        return .success(hand)
    }

    /// The same hand in (about) the same place.
    static func sameSpot(_ a: Hand, _ b: Hand) -> Bool {
        let d = hypot(a.center.x - b.center.x, a.center.y - b.center.y)
        let ratio = a.size / max(b.size, 1e-6)
        return d <= max(restingDistance, 0.25 * a.size) && ratio > 0.67 && ratio < 1.5
    }

    static func isDark(_ thumb: [Float]) -> Bool {
        let mean = thumb.reduce(0, +) / Float(thumb.count)
        guard mean < darkMean else { return false }
        let sorted = thumb.sorted()
        // numpy.percentile(..., 99) with linear interpolation
        let pos = Float(sorted.count - 1) * 0.99
        let lo = Int(pos), hi = min(lo + 1, sorted.count - 1)
        let p99 = sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Float(lo))
        return p99 < darkP99
    }

    static func motion(_ a: [Float], _ b: [Float]) -> Float {
        var diffs = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { diffs[i] = abs(a[i] - b[i]) }
        var sorted = diffs
        sorted.sort()
        let med = sorted[sorted.count / 2]
        var sum: Float = 0
        for d in diffs { sum += abs(d - med) }
        return sum / Float(diffs.count)
    }

    /// 64x48 full-range luma thumbnail. Each cell is the average of a 5x5 grid of
    /// samples spread over its area (close to OpenCV's INTER_AREA, which the engine
    /// uses), so sensor noise does not read as motion. YUV buffers are read straight
    /// from the Y plane (video-range luma is stretched to full range, so the
    /// thresholds mean the same as in the engine); BGRA buffers are converted per sample.
    static func thumbnail(_ pb: CVPixelBuffer) -> [Float]? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let yuv = videoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard yuv || format == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = yuv ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = yuv ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = yuv ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let bpr = yuv ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard w >= thumbWidth, h >= thumbHeight else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let samples = 5
        let n = Float(samples * samples)
        // a cell's luma = sum * scale + offset
        let scale: Float = !yuv ? 1 / (1000 * n) : videoRange ? 255 / (219 * n) : 1 / n
        let offset: Float = videoRange ? -16 * 255 / 219 : 0
        var out = [Float](repeating: 0, count: thumbWidth * thumbHeight)
        out.withUnsafeMutableBufferPointer { o in
            for ty in 0..<thumbHeight {
                let y0 = ty * h / thumbHeight, y1 = (ty + 1) * h / thumbHeight
                for tx in 0..<thumbWidth {
                    let x0 = tx * w / thumbWidth, x1 = (tx + 1) * w / thumbWidth
                    var sum = 0
                    for sy in 0..<samples {
                        let row = p + (y0 + ((y1 - y0) * (2 * sy + 1)) / (2 * samples)) * bpr
                        for sx in 0..<samples {
                            let x = x0 + ((x1 - x0) * (2 * sx + 1)) / (2 * samples)
                            if yuv {
                                sum += Int(row[x])
                            } else {
                                let px = row + x * 4                              // B, G, R, A
                                sum += 114 * Int(px[0]) + 587 * Int(px[1]) + 299 * Int(px[2])
                            }
                        }
                    }
                    o[ty * thumbWidth + tx] = max(0, Float(sum) * scale + offset)
                }
            }
        }
        return out
    }
}
