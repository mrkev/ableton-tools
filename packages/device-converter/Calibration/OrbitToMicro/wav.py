"""Minimal WAV reader (16/24-bit PCM and 32/64-bit float) returning frames × channels."""
import struct
import numpy as np


def read(path):
    b = open(path, "rb").read()
    i, fmt = 12, None
    while i < len(b):
        cid, size = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        body = b[i + 8:i + 8 + size]
        if cid == b"fmt ":
            tag, channels, _, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, channels, bits)
        if cid == b"data":
            tag, channels, bits = fmt
            if tag == 3:
                a = np.frombuffer(body, "<f4" if bits == 32 else "<f8").astype(float)
            elif bits == 16:
                a = np.frombuffer(body, "<i2") / 32768.0
            else:
                u = np.frombuffer(body, np.uint8).reshape(-1, 3).astype(np.int32)
                v = u[:, 0] | u[:, 1] << 8 | u[:, 2] << 16
                v[v >= 1 << 23] -= 1 << 24
                a = v / float(1 << 23)
            return a.reshape(-1, channels)
        i += 8 + size + (size & 1)
