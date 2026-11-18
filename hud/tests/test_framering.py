"""Tests for the camera frame ring (hud/framering.py): the engine's reader against the
reference writer, including what the macOS app does for privacy (it zeroes the slots
when the camera stops sending frames, and deletes the file when it quits).

Run:  python3 tests/test_framering.py      (from hud/, with the venv active)
  or  python3 -m pytest tests/test_framering.py
"""
import atexit
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from hud.framering import HEADER, SLOT_HDR, FrameReader, FrameWriter, file_size, slot_offset  # noqa: E402

# Unix socket paths are limited to 104 bytes: keep the folder short.
_TMP = Path(tempfile.mkdtemp(prefix="wv-ring-", dir="/tmp"))
atexit.register(shutil.rmtree, _TMP, ignore_errors=True)


def frame(value):
    return np.full((480, 640, 3), value, np.uint8)


def ring(name):
    d = _TMP / name
    d.mkdir()
    return d / "frames.shm", d / "frames.sock"


def test_round_trip():
    shm, sock = ring("rt")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    try:
        assert os.stat(shm).st_mode & 0o777 == 0o600 and os.stat(sock).st_mode & 0o777 == 0o600
        assert os.path.getsize(shm) == file_size(640, 480, 640 * 4, 3)
        assert r.wait(0.05) is None                       # nothing written yet
        w.write(frame(7))
        seq, img = r.wait(1.0)
        assert seq == 1 and img.shape == (480, 640, 3) and int(img[0, 0, 0]) == 7
        assert r.read() is None                           # the same frame is not delivered twice
        for v in (8, 9, 10):
            w.write(frame(v))
        seq, img = r.wait(1.0)                            # the backlog is drained: the newest frame
        assert seq == 4 and int(img[100, 100, 2]) == 10
    finally:
        r.close()


def test_clear_leaves_no_frame():
    shm, sock = ring("clear")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    try:
        for v in (50, 60, 70):
            w.write(frame(v))
        assert r.wait(1.0)[0] == 3
        w.clear()
        data = shm.read_bytes()
        assert HEADER.unpack_from(data, 0)[8] == 0        # header.latest
        body = data[HEADER.size:]
        assert body.count(0) == len(body)                 # every slot header and pixel is zero
        assert r.read() is None
        w.write(frame(80))                                # sequence numbers go on after a clear
        seq, img = r.wait(1.0)
        assert seq == 4 and int(img[0, 0, 0]) == 80
    finally:
        r.close()


def test_pixels_exact():
    shm, sock = ring("exact")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    try:
        src = np.random.default_rng(1).integers(0, 256, (480, 640, 3), dtype=np.uint8)
        w.write(src)
        seq, img = r.wait(1.0)
        assert img.dtype == np.uint8 and img.flags.c_contiguous and np.array_equal(img, src)  # B, G, R in order
        for _ in range(3):
            w.write(frame(0))                             # the slot it came from is overwritten...
        assert np.array_equal(img, src)                   # ...but the frame is a copy, not a view
    finally:
        r.close()


def test_padded_rows():
    # CoreVideo may pad each row (stride > width * 4): only the first width * 4 bytes are pixels.
    shm, sock = ring("pad")
    r = FrameReader(shm, sock)
    try:
        wd, ht, stride = 64, 48, 64 * 4 + 32
        buf = bytearray(file_size(wd, ht, stride, 3))
        HEADER.pack_into(buf, 0, b"HUDF", 1, wd, ht, stride, 3, 1, 0, 1)
        src = np.random.default_rng(2).integers(0, 256, (ht, wd, 3), dtype=np.uint8)
        rows = np.full((ht, stride), 0xEE, np.uint8)      # padding that must not leak into the image
        rows[:, : wd * 4] = np.concatenate([src, np.full((ht, wd, 1), 255, np.uint8)], axis=2).reshape(ht, -1)
        off = slot_offset(1, stride, ht)
        SLOT_HDR.pack_into(buf, off, 1, 0)
        buf[off + SLOT_HDR.size: off + SLOT_HDR.size + stride * ht] = rows.tobytes()
        shm.write_bytes(bytes(buf))
        seq, img = r.read()
        assert seq == 1 and img.shape == (ht, wd, 3) and np.array_equal(img, src)
    finally:
        r.close()


def test_torn_read_is_dropped():
    shm, sock = ring("torn")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    try:
        w.write(frame(1))
        # the writer is rewriting the slot of the newest frame (seq 0 while being written)
        SLOT_HDR.pack_into(w.mm, slot_offset(1 % 3, 640 * 4, 480), 0, 0)
        assert r.read() is None
    finally:
        r.close()


def test_missing_and_replaced_file():
    shm, sock = ring("gone")
    r = FrameReader(shm, sock)
    try:
        assert r.read() is None                           # the app has not made the ring yet
        w = FrameWriter(shm, sock)
        w.write(frame(20))
        assert r.wait(1.0)[0] == 1
        w.clear()
        shm.unlink()                                      # the app quit: the ring is gone
        assert r.read() is None and r.mm is None          # no crash, mapping released
        w2 = FrameWriter(shm, sock)                       # next launch: a new ring, counting from 1
        w2.write(frame(30))
        seq, img = r.wait(1.0)
        assert seq == 1 and int(img[0, 0, 0]) == 30
        w3 = FrameWriter(shm, sock)                       # replaced while mapped (another inode)
        w3.write(frame(40))
        seq, img = r.wait(1.0)
        assert seq == 1 and int(img[0, 0, 0]) == 40
    finally:
        r.close()


def test_discard_after_app_crash():
    shm, sock = ring("crash")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    w.write(frame(90))
    assert r.wait(1.0)[0] == 1
    old = shm.read_bytes()
    assert old.count(90) > 640 * 480                      # the frame is in the file
    fd = os.open(shm, os.O_RDONLY)                        # to see the old file after it is deleted
    try:
        r.discard()
        assert not shm.exists() and not sock.exists()     # ring and socket gone, as on a normal quit
        data = os.pread(fd, len(old), 0)
        assert data[:32] == old[:32] and not any(data[32:])   # latest = 0, no frame left
    finally:
        os.close(fd)

    # a newer copy of the app made a new ring (and a new engine a new socket) before
    # we noticed: neither is touched
    shm, sock = ring("crash-new")
    r = FrameReader(shm, sock)
    w = FrameWriter(shm, sock)
    w.write(frame(50))
    assert r.wait(1.0)[0] == 1
    FrameWriter(shm, sock).write(frame(60))               # replaced (another inode)
    r2 = FrameReader(shm, sock)                           # binds a new socket at the path
    try:
        r.discard()
        assert shm.exists() and sock.exists()
        seq, img = r2.read()
        assert seq == 1 and int(img[0, 0, 0]) == 60
    finally:
        r2.close()


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", name)
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
