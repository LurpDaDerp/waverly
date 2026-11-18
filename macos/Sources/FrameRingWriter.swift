// FrameRingWriter.swift — writes camera frames into the shared-memory ring the
// Python engine reads. Byte-compatible with hud/python/hud/framering.py, which is
// the authoritative definition of the layout and the seqlock protocol:
//
//   Header, 64 bytes, little-endian:
//     0 "HUDF" | 4 u32 version=1 | 8 u32 width | 12 u32 height | 16 u32 stride
//     20 u32 slots | 24 u32 pixel_format (1 = BGRA8) | 28 u32 reserved | 32 u64 latest | 40 24 x 0
//   Slot i at 64 + i * (16 + stride * height): u64 seq | u64 t_ns | stride*height pixel bytes,
//     rows top to bottom, NOT mirrored.
//   Writer: seq N -> slot N % slots; slot.seq = 0; copy pixels + t_ns; barrier; slot.seq = N;
//     header.latest = N; send N (u64 LE) as an 8-byte datagram to the engine's socket.
//   Clearing: header.latest = 0, then every slot's seq, t_ns and pixels = 0 (sequence numbers go on).
//
// Privacy: camera frames never outlive their use. CameraGate clears the ring whenever the
// camera stops sending frames to the engine (back to idle, or paused), and the app clears it
// and deletes the file (and the engine's socket) when it quits.
//
// The camera delivers biplanar YUV (CameraGate keeps it in the camera's own format
// so idle frames need no conversion); those frames are converted to BGRA with vImage
// straight into the slot, which costs about as much as the plain copy did.

import Accelerate
import Foundation
import CoreVideo
import Darwin

final class FrameRingWriter {
    static let magic: [UInt8] = Array("HUDF".utf8)
    static let headerSize = 64
    static let slotHeaderSize = 16
    static let pixelFormatBGRA: UInt32 = 1

    let width: Int, height: Int, stride: Int, slots: Int
    let fileURL: URL
    let socketPath: String
    /// Called (on the writer's thread) if the ring file was deleted or replaced
    /// behind our back and had to be recreated: the engine must re-open it.
    var onRecreated: (() -> Void)?

    private var base: UnsafeMutableRawPointer?
    private var mappedSize = 0
    private var inode: ino_t = 0
    private var sock: Int32 = -1
    private var addr = sockaddr_un()
    private(set) var seq: UInt64 = 0
    private var lastCheck: UInt64 = 0
    private var removed = false                          // removeFiles() ran: write nothing more
    private var yuvConversions: [Int: vImage_YpCbCrToARGB] = [:]   // key: (BT.709 ? 2 : 0) + (full range ? 1 : 0)

    init(fileURL: URL, socketPath: String, width: Int = 640, height: Int = 480, slots: Int = 3) throws {
        self.fileURL = fileURL
        self.socketPath = socketPath
        self.width = width
        self.height = height
        self.stride = width * 4
        self.slots = slots
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)   // the rest stays zero (NUL-terminated)
        }
        try createFile()
        sock = socket(AF_UNIX, SOCK_DGRAM, 0)
        if sock >= 0 {
            // never block the camera thread if the engine is stalled and its socket buffer is full
            _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    deinit {
        if let b = base { munmap(b, mappedSize) }
        if sock >= 0 { Darwin.close(sock) }
    }

    static func fileSize(width: Int, height: Int, stride: Int, slots: Int) -> Int {
        headerSize + slots * (slotHeaderSize + stride * height)
    }

    private func slotOffset(_ i: Int) -> Int { Self.headerSize + i * (Self.slotHeaderSize + stride * height) }

    /// Build the file under a temporary name and rename it into place, so the
    /// engine never maps a half-made file.
    private func createFile() throws {
        let size = Self.fileSize(width: width, height: height, stride: stride, slots: slots)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(getpid()).tmp").path
        unlink(tmp)
        let fd = Darwin.open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            let e = errno
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        let p: UnsafeMutableRawPointer! = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p, p != UnsafeMutableRawPointer(bitPattern: -1) else {
            unlink(tmp)
            throw POSIXError(.ENOMEM)
        }
        memset(p, 0, Self.headerSize)
        for (i, b) in Self.magic.enumerated() { p.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
        p.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 4, as: UInt32.self)                  // version
        p.storeBytes(of: UInt32(width).littleEndian, toByteOffset: 8, as: UInt32.self)
        p.storeBytes(of: UInt32(height).littleEndian, toByteOffset: 12, as: UInt32.self)
        p.storeBytes(of: UInt32(stride).littleEndian, toByteOffset: 16, as: UInt32.self)
        p.storeBytes(of: UInt32(slots).littleEndian, toByteOffset: 20, as: UInt32.self)
        p.storeBytes(of: Self.pixelFormatBGRA.littleEndian, toByteOffset: 24, as: UInt32.self)
        p.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
        p.storeBytes(of: UInt64(0), toByteOffset: 32, as: UInt64.self)                              // latest
        msync(p, Self.headerSize, MS_SYNC)
        guard rename(tmp, fileURL.path) == 0 else {
            let e = errno
            munmap(p, size)
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        var st = stat()
        if fstat(fd, &st) == 0 { inode = st.st_ino }
        if let old = base { munmap(old, mappedSize) }
        base = p
        mappedSize = size
        seq = 0
    }

    private func put64(_ v: UInt64, at off: Int) {
        base!.storeBytes(of: v.littleEndian, toByteOffset: off, as: UInt64.self)
    }

    /// Copy one pixel buffer (width x height, not mirrored) into the ring as BGRA,
    /// then notify the engine. BGRA is copied as it is; biplanar 4:2:0 YUV (video or
    /// full range) is converted on the way in. Returns false if the buffer does not
    /// match the ring's geometry or has another pixel format.
    @discardableResult
    func write(_ pb: CVPixelBuffer, timestampNs: UInt64) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pb)
        let yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height,
              yuv || format == kCVPixelFormatType_32BGRA else { return false }
        guard !removed else { return false }
        checkFile(timestampNs)
        guard let base else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var info = vImage_YpCbCrToARGB()
        if yuv {
            guard CVPixelBufferGetPlaneCount(pb) == 2, CVPixelBufferGetBaseAddressOfPlane(pb, 0) != nil,
                  CVPixelBufferGetBaseAddressOfPlane(pb, 1) != nil, let c = conversion(for: pb, format) else { return false }
            info = c
        } else {
            guard CVPixelBufferGetBaseAddress(pb) != nil else { return false }
        }

        seq &+= 1
        let n = seq
        let off = slotOffset(Int(n % UInt64(slots)))
        put64(0, at: off)                                    // 1. slot is being written
        OSMemoryBarrier()
        let dst = base + off + Self.slotHeaderSize           // 2. pixels (+ capture time)
        if yuv {
            convert(pb, &info, into: dst)
        } else {
            let src = CVPixelBufferGetBaseAddress(pb)!
            let srcStride = CVPixelBufferGetBytesPerRow(pb)
            if srcStride == stride {
                memcpy(dst, src, stride * height)
            } else {
                for row in 0..<height { memcpy(dst + row * stride, src + row * srcStride, stride) }
            }
        }
        put64(timestampNs, at: off + 8)
        OSMemoryBarrier()                                    // 3. publish the slot
        put64(n, at: off)
        OSMemoryBarrier()
        put64(n, at: 32)                                     // 4. header.latest = n
        notify(n)                                            // 5. wake the engine
        return true
    }

    /// The YUV -> RGB conversion for this buffer's colour matrix and range (cached).
    private func conversion(for pb: CVPixelBuffer, _ format: OSType) -> vImage_YpCbCrToARGB? {
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let is709 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let key = (is709 ? 2 : 0) + (full ? 1 : 0)
        if let c = yuvConversions[key] { return c }
        var range = full
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                      YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                      YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var info = vImage_YpCbCrToARGB()
        let err = vImageConvert_YpCbCrToARGB_GenerateConversion(
            is709 ? kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 : kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        yuvConversions[key] = info
        return info
    }

    /// 4:2:0 biplanar YUV (locked by the caller) -> BGRA rows of `stride` bytes at `dst`.
    private func convert(_ pb: CVPixelBuffer, _ info: inout vImage_YpCbCrToARGB, into dst: UnsafeMutableRawPointer) {
        var y = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                              height: vImagePixelCount(height), width: vImagePixelCount(width),
                              rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        var cbcr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 1),
                                 height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
        var out = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        let bgra: [UInt8] = [3, 2, 1, 0]                     // ARGB -> B, G, R, A in memory
        // one thread: the frame is small, and waking more cores costs more than it saves
        vImageConvert_420Yp8_CbCr8ToARGB8888(&y, &cbcr, &out, &info, bgra, 255, vImage_Flags(kvImageDoNotTile))
    }

    /// Zero every slot (pixels included) and the header's newest-frame number, so no camera
    /// frame stays in the file (which lives on disk). Call on the thread that writes.
    func clear() {
        guard let base else { return }
        put64(0, at: 32)                                     // no frame
        OSMemoryBarrier()
        for i in 0..<slots {
            let off = slotOffset(i)
            put64(0, at: off)                                // seq 0 first: a reader drops what it copies
            OSMemoryBarrier()
            memset(base + off + 8, 0, 8 + stride * height)   // t_ns and the pixels
        }
        OSMemoryBarrier()
    }

    /// The app is quitting: clear the ring, unmap it and delete the file and the engine's
    /// socket (the engine has been stopped). The next launch makes a new ring.
    func removeFiles() {
        guard !removed else { return }
        removed = true
        clear()
        if let b = base {
            msync(b, mappedSize, MS_SYNC)
            munmap(b, mappedSize)
        }
        base = nil
        mappedSize = 0
        unlink(fileURL.path)
        unlink(socketPath)
    }

    /// Every ~2 s make sure the file we write is still the one at the path.
    private func checkFile(_ nowNs: UInt64) {
        guard nowNs &- lastCheck > 2_000_000_000 else { return }
        lastCheck = nowNs
        var st = stat()
        if stat(fileURL.path, &st) == 0 && st.st_ino == inode { return }
        AppLog.warning("frame ring file missing or replaced; recreating it")
        if (try? createFile()) != nil { onRecreated?() }
    }

    private func notify(_ n: UInt64) {
        guard sock >= 0 else { return }
        var payload = n.littleEndian
        _ = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                // fails harmlessly (ENOENT / ECONNREFUSED / EAGAIN) if the engine isn't listening
                sendto(sock, &payload, 8, 0, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
