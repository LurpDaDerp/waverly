// TestVideoSource.swift — developer hook: plays a video file into CameraGate as
// if it were the camera, so the whole app pipeline (idle gating with Apple
// Vision, active mode, frame ring, engine, overlay) can be verified without a
// person in front of the Mac. Off unless the user default "HUDTestVideo" is set:
//
//   Waverly.app/Contents/MacOS/Waverly -HUDTestVideo /path/clip.mov [-HUDTestVideoDelay 5] [-HUDTestVideoLoop YES]
//
// A test video that can't be found leaves the camera paused (it never falls back to the real camera).
//
// Frames are scaled and letterboxed into 640x480 exactly like tools/fake_camera.py
// (grey 40,40,40 borders) and delivered as the MacBook camera delivers them: in
// biplanar 4:2:0 YUV (video range, BT.601), never slower than 15 fps (idle mode
// takes every third frame, as with the real camera). The clip plays in real time;
// the camera mode only decides how often a frame is taken (15 or 30 fps). Before
// the delay and after the clip ends it delivers a still grey frame (an empty room).

import AVFoundation
import Accelerate
import CoreVideo

final class TestVideoSource {
    let url: URL
    let delay: TimeInterval
    let loop: Bool
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var queue: DispatchQueue?
    private var timer: DispatchSourceTimer?
    private var fps = 0
    private var clockStart: TimeInterval?
    private let asset: AVURLAsset
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: (t: Double, pb: CVPixelBuffer)?
    private var current: CVPixelBuffer?
    private var currentIsVideo = false
    private var ended = false
    private var pool: CVPixelBufferPool?          // BGRA work buffers (letterboxing)
    private var yuvPool: CVPixelBufferPool?       // what goes out
    private var blank: CVPixelBuffer?
    private var toYUV = vImage_ARGBToYpCbCr()
    /// The slowest rate a Mac camera runs at (CameraGate decimates idle frames itself).
    static let minFPS = 15

    /// The developer asked for a test video. If it can't be played, the real camera
    /// must stay off (CameraGate): a test run never films the room by mistake.
    static func isRequested(_ defaults: UserDefaults = .standard) -> Bool {
        !(defaults.string(forKey: "HUDTestVideo") ?? "").isEmpty
    }

    init?(defaults: UserDefaults = .standard) {
        guard let path = defaults.string(forKey: "HUDTestVideo"), !path.isEmpty else { return nil }
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        delay = defaults.double(forKey: "HUDTestVideoDelay")
        loop = defaults.bool(forKey: "HUDTestVideoLoop")
        asset = AVURLAsset(url: url)
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: CameraGate.width,
                                    kCVPixelBufferHeightKey as String: CameraGate.height,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let yuvAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       kCVPixelBufferWidthKey as String: CameraGate.width,
                                       kCVPixelBufferHeightKey as String: CameraGate.height,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, nil, yuvAttrs as CFDictionary, &yuvPool)
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &toYUV,
                                                      kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        if let b = makeBuffer() {
            fill(b)
            blank = yuv(b)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            AppLog.error("test video not found: \(url.path)")
            return nil
        }
    }

    /// Load the video track (on the camera queue, never the main thread).
    private func loadTrack() -> AVAssetTrack? {
        if let track { return track }
        let sem = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            self.track = tracks?.first
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        if track == nil { AppLog.error("test video has no video track: \(url.path)") }
        return track
    }

    /// Start (or change the rate of) frame delivery on `queue`.
    func start(fps requested: Int, queue: DispatchQueue) {
        self.queue = queue
        let fps = max(requested, Self.minFPS)
        if clockStart == nil { clockStart = CameraGate.now(); openReader() }
        guard fps != self.fps || timer == nil else { return }
        self.fps = fps
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let period = 1.0 / Double(fps)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        fps = 0
    }

    private func openReader() {
        guard let track = loadTrack() else { ended = true; return }
        reader?.cancelReading()
        guard let r = try? AVAssetReader(asset: asset) else { ended = true; return }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { ended = true; return }
        r.add(o)
        r.startReading()
        reader = r
        output = o
        pending = nil
        ended = false
        readNext()
    }

    private func readNext() {
        guard let o = output, let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else {
            pending = nil
            ended = true
            return
        }
        pending = (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)), pb)
    }

    private func tick() {
        guard let start = clockStart else { return }
        var t = CameraGate.now() - start - delay
        var frame: CVPixelBuffer?
        if t >= 0 {
            if ended && loop && track != nil {
                clockStart = CameraGate.now() - delay
                t = 0
                openReader()
            }
            var latest: CVPixelBuffer?
            while let p = pending, p.t <= t {
                latest = p.pb
                readNext()
            }
            if let raw = latest, let work = makeBuffer() {
                letterbox(raw, into: work)
                if let out = yuv(work) {
                    current = out
                    currentIsVideo = true
                }
            }
            if ended && pending == nil && !loop && currentIsVideo {
                current = nil                      // the clip is over: an empty room from now on
                currentIsVideo = false
                AppLog.info("test video finished")
            }
            frame = current ?? blank
        } else {
            frame = blank
        }
        if let f = frame { onFrame?(f) }
    }

    // MARK: pixels

    private func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// BGRA -> a new 4:2:0 YUV buffer (video range, BT.601), like the camera's frames.
    private func yuv(_ bgra: CVPixelBuffer) -> CVPixelBuffer? {
        guard let yuvPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, yuvPool, &out)
        guard let out else { return nil }
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(bgra), height: vImagePixelCount(CVPixelBufferGetHeight(bgra)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(bgra)), rowBytes: CVPixelBufferGetBytesPerRow(bgra))
        var y = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(out, 0), height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(out, 0)),
                              width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(out, 0)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(out, 0))
        var cbcr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(out, 1), height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(out, 1)),
                                 width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(out, 1)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(out, 1))
        let argb: [UInt8] = [3, 2, 1, 0]                     // B, G, R, A in memory -> A, R, G, B
        guard vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &y, &cbcr, &toYUV, argb, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return out
    }

    private func fill(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var grey: [UInt8] = [40, 40, 40, 255]                // B, G, R, A in memory order
        vImageBufferFill_ARGB8888(&dst, &grey, vImage_Flags(kvImageNoFlags))
    }

    /// Scale to fit 640x480 and centre with grey borders, like tools/fake_camera.py.
    private func letterbox(_ src: CVPixelBuffer, into dst: CVPixelBuffer) {
        fill(dst)
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        let dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst)
        let s = min(Double(dw) / Double(sw), Double(dh) / Double(sh))
        let fw = Int(Double(sw) * s), fh = Int(Double(sh) * s)
        let ox = (dw - fw) / 2, oy = (dh - fh) / 2
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sBase = CVPixelBufferGetBaseAddress(src), let dBase = CVPixelBufferGetBaseAddress(dst) else { return }
        let dBpr = CVPixelBufferGetBytesPerRow(dst)
        var s1 = vImage_Buffer(data: sBase, height: vImagePixelCount(sh), width: vImagePixelCount(sw),
                               rowBytes: CVPixelBufferGetBytesPerRow(src))
        var d1 = vImage_Buffer(data: dBase + oy * dBpr + ox * 4, height: vImagePixelCount(fh), width: vImagePixelCount(fw),
                               rowBytes: dBpr)
        vImageScale_ARGB8888(&s1, &d1, nil, vImage_Flags(kvImageNoFlags))
    }
}
