"""Camera frames from the macOS app to the Python engine: a shared-memory ring.

The macOS app owns the camera. It writes each frame it wants analysed into a
memory-mapped file and then sends the frame's sequence number as an 8-byte
datagram to a Unix socket the engine listens on. The engine blocks on that
socket (no CPU while no frames arrive), then reads the newest frame.

File layout, all integers little-endian
---------------------------------------
Header, 64 bytes:
    0   4s  magic          b"HUDF"
    4   u32 version        1
    8   u32 width          pixels (640)
    12  u32 height         pixels (480)
    16  u32 stride         bytes per row (>= width * 4)
    20  u32 slots          number of frame slots (3)
    24  u32 pixel_format   1 = BGRA8 (kCVPixelFormatType_32BGRA)
    28  u32 reserved       0
    32  u64 latest         sequence number of the newest complete frame (0 = none)
    40  24 bytes reserved  zeros
Slot i starts at 64 + i * (16 + stride * height):
    +0  u64 seq            sequence number of the frame in this slot (0 while being written)
    +8  u64 t_ns           capture time, nanoseconds, monotonic clock (informational)
    +16 stride*height bytes of pixels, rows top to bottom, NOT mirrored

Writer protocol (a seqlock): seq N goes to slot N % slots.
    1. slot.seq = 0
    2. copy pixels, write slot.t_ns
    3. memory barrier, then slot.seq = N
    4. header.latest = N
    5. send N (u64) as an 8-byte datagram to the socket
Clearing (the camera stopped sending frames, or the app quits; nothing stays behind):
    header.latest = 0, then for every slot: slot.seq = 0, zero t_ns and the pixels.
    The writer's sequence numbers keep counting.
Reader protocol:
    read latest -> slot; s1 = slot.seq; copy pixels; s2 = slot.seq;
    use the frame only if s1 == s2 == latest (otherwise it was being overwritten).
If the resolution changes the writer recreates the file; the reader re-maps
whenever the file at the path is another one (inode or size) or its
width/height/stride no longer match. The app zeroes the slots when the camera
stops sending frames and deletes the file when it quits (if the app crashes, the
engine does both as it stops: FrameReader.discard); while the file is missing the
reader simply has no frames, and maps the new one once it appears.
"""
from __future__ import annotations

import mmap
import os
import socket
import struct
from pathlib import Path

import cv2
import numpy as np

MAGIC = b"HUDF"
HEADER = struct.Struct("<4sIIIIIII Q 24x")  # 64 bytes
SLOT_HDR = struct.Struct("<QQ")              # 16 bytes
BGRA = 1
assert HEADER.size == 64 and SLOT_HDR.size == 16


def slot_offset(i: int, stride: int, height: int) -> int:
    return HEADER.size + i * (SLOT_HDR.size + stride * height)


def file_size(width: int, height: int, stride: int, slots: int) -> int:
    return slot_offset(slots, stride, height)


class FrameReader:
    """Engine side: wait for frames and read the newest one as a BGR numpy array."""

    def __init__(self, shm_path: Path, sock_path: Path):
        self.shm_path, self.sock_path = Path(shm_path), Path(sock_path)
        self.sock_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.sock_path.unlink()
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(str(self.sock_path))
        os.chmod(self.sock_path, 0o600)
        self.sock_ino = os.stat(self.sock_path).st_ino
        self.mm = None
        self.geom = None
        self.ident = None   # (inode, size) of the mapped file
        self.last_seq = 0

    def _unmap(self):
        if self.mm is not None:
            self.mm.close()
        self.mm = self.geom = self.ident = None

    def _map(self) -> bool:
        self._unmap()
        try:
            fd = os.open(self.shm_path, os.O_RDONLY)
        except FileNotFoundError:
            return False
        try:
            st = os.fstat(fd)
            if st.st_size < HEADER.size:
                return False
            mm = mmap.mmap(fd, st.st_size, prot=mmap.PROT_READ)
        finally:
            os.close(fd)
        magic, ver, w, h, stride, slots, fmt, _r, _latest = HEADER.unpack_from(mm, 0)
        if magic != MAGIC or ver != 1 or fmt != BGRA or st.st_size < file_size(w, h, stride, slots):
            mm.close()
            return False
        self.mm, self.geom, self.ident = mm, (w, h, stride, slots, st.st_size), (st.st_ino, st.st_size)
        self.last_seq = 0  # a new writer counts from 1 again
        return True

    def wait(self, timeout: float):
        """Block up to `timeout` s for a new frame. Returns (seq, BGR image) or None."""
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(64)
        except (socket.timeout, BlockingIOError):
            return None
        # drain any backlog so we always analyse the newest frame
        self.sock.setblocking(False)
        try:
            while True:
                data = self.sock.recv(64)
        except (BlockingIOError, OSError):
            pass
        return self.read()

    def read(self):
        try:
            st = os.stat(self.shm_path)
        except FileNotFoundError:
            self._unmap()  # the app is quitting (it deletes the ring) or has not made it yet
            return None
        if self.mm is None or (st.st_ino, st.st_size) != self.ident:
            if not self._map():  # a new file (app restarted, resolution changed): map it
                return None
        w, h, stride, slots, size = self.geom
        hdr = HEADER.unpack_from(self.mm, 0)
        if (hdr[2], hdr[3], hdr[4], hdr[5]) != (w, h, stride, slots):
            if not self._map():
                return None
            w, h, stride, slots, size = self.geom
            hdr = HEADER.unpack_from(self.mm, 0)
        latest = hdr[8]
        if latest == 0 or latest == self.last_seq:
            return None
        off = slot_offset(latest % slots, stride, h)
        s1, _t = SLOT_HDR.unpack_from(self.mm, off)
        if s1 != latest:
            return None
        px = np.frombuffer(self.mm, dtype=np.uint8, count=stride * h, offset=off + SLOT_HDR.size)
        # BGRA -> BGR straight from the mapped slot: one pass, and a fresh array (a strided
        # numpy slice of the alpha-less channels costs ~40x as much per frame)
        img = cv2.cvtColor(px.reshape(h, stride)[:, : w * 4].reshape(h, w, 4), cv2.COLOR_BGRA2BGR)
        s2, _t = SLOT_HDR.unpack_from(self.mm, off)
        if s2 != s1:
            return None  # overwritten while copying
        self.last_seq = latest
        return latest, img

    def close(self):
        try:
            self.sock.close()
            self.sock_path.unlink()
        except OSError:
            pass

    def discard(self):
        """The app is gone without its own cleanup (a crash or Force Quit): do what it
        would have done on quitting, zero the ring and delete it and our socket. A ring
        that is not the one we read from belongs to a newer copy of the app: left alone.
        Called just before the process exits (the reader's own mapping stays as it is)."""
        try:
            fd = os.open(self.shm_path, os.O_RDWR)
        except FileNotFoundError:
            fd = -1
        if fd >= 0:
            try:
                st = os.fstat(fd)
                if self.ident is None or (st.st_ino, st.st_size) == self.ident:
                    if st.st_size > HEADER.size:
                        with mmap.mmap(fd, st.st_size) as mm:
                            struct.pack_into("<Q", mm, 32, 0)          # latest = 0 first
                            blank = bytes(1 << 20)
                            for pos in range(HEADER.size, st.st_size, len(blank)):
                                n = min(len(blank), st.st_size - pos)
                                mm[pos: pos + n] = blank[:n]           # every slot's seq, t_ns and pixels
                            mm.flush()
                    os.unlink(self.shm_path)
            finally:
                os.close(fd)
        try:
            self.sock.close()
            if os.stat(self.sock_path).st_ino == self.sock_ino:
                self.sock_path.unlink()
        except OSError:
            pass


class FrameWriter:
    """Reference writer, used by tools/fake_camera.py. The macOS app implements
    exactly this in Swift (see BUILD_PROMPT.md, "Frame ring")."""

    def __init__(self, shm_path: Path, sock_path: Path, width=640, height=480, slots=3):
        self.shm_path, self.sock_path = Path(shm_path), Path(sock_path)
        self.w, self.h, self.stride, self.slots = width, height, width * 4, slots
        size = file_size(self.w, self.h, self.stride, slots)
        self.shm_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.shm_path.with_suffix(".tmp")
        with open(tmp, "wb") as f:
            f.truncate(size)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.shm_path)
        fd = os.open(self.shm_path, os.O_RDWR)
        self.mm = mmap.mmap(fd, size)
        os.close(fd)
        HEADER.pack_into(self.mm, 0, MAGIC, 1, self.w, self.h, self.stride, slots, BGRA, 0, 0)
        self.seq = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)

    def write(self, bgr: np.ndarray, t_ns: int = 0):
        assert bgr.shape == (self.h, self.w, 3)
        self.seq += 1
        n = self.seq
        off = slot_offset(n % self.slots, self.stride, self.h)
        SLOT_HDR.pack_into(self.mm, off, 0, 0)
        bgra = np.concatenate([bgr, np.full((self.h, self.w, 1), 255, np.uint8)], axis=2)
        self.mm[off + SLOT_HDR.size: off + SLOT_HDR.size + self.stride * self.h] = bgra.tobytes()
        SLOT_HDR.pack_into(self.mm, off, n, t_ns)
        struct.pack_into("<Q", self.mm, 32, n)
        try:
            self.sock.sendto(struct.pack("<Q", n), str(self.sock_path))
        except OSError:
            pass  # engine not running yet

    def clear(self):
        """Forget every frame, as the app does when its camera stops sending (see Clearing)."""
        struct.pack_into("<Q", self.mm, 32, 0)
        blank = bytes(self.stride * self.h)
        for i in range(self.slots):
            off = slot_offset(i, self.stride, self.h)
            SLOT_HDR.pack_into(self.mm, off, 0, 0)
            self.mm[off + SLOT_HDR.size: off + SLOT_HDR.size + len(blank)] = blank
