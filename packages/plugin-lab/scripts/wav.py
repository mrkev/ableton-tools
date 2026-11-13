"""Read and write WAV files as float arrays (frames x channels), numpy only."""
import struct
import numpy as np


def read(path):
    """PCM 16/24/32-bit or float 32/64, any channel count. Returns float64 in [-1, 1]."""
    b = open(path, "rb").read()
    i, fmt = 12, None
    while i < len(b):
        cid, size = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        body = b[i + 8:i + 8 + size]
        if cid == b"fmt ":
            tag, ch, _, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, bits)
        elif cid == b"data":
            tag, ch, bits = fmt
            if tag == 3:
                a = np.frombuffer(body, "<f4" if bits == 32 else "<f8").astype(float)
            elif bits == 16:
                a = np.frombuffer(body, "<i2") / 32768.0
            elif bits == 24:
                u = np.frombuffer(body, np.uint8).reshape(-1, 3).astype(np.int32)
                v = u[:, 0] | u[:, 1] << 8 | u[:, 2] << 16
                v[v >= 1 << 23] -= 1 << 24
                a = v / float(1 << 23)
            elif bits == 32:
                a = np.frombuffer(body, "<i4") / 2147483648.0
            return a.reshape(-1, ch)
        i += 8 + size + (size & 1)
    raise ValueError(f"{path}: no audio data")


def write(path, data, sr=48000):
    """32-bit float WAV."""
    data = np.asarray(data, dtype="<f4")
    if data.ndim == 1:
        data = data[:, None]
    ch = data.shape[1]
    body = data.tobytes()
    fmt = struct.pack("<HHIIHH", 3, ch, sr, sr * ch * 4, ch * 4, 32)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(body)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        f.write(b"data" + struct.pack("<I", len(body)) + body)
