#include "CGzip.h"
#include <zlib.h>
#include <stdlib.h>
#include <string.h>

int cgzip_inflate(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits 15 + 32 => automatically detect a gzip or zlib header.
    if (inflateInit2(&strm, 15 + 32) != Z_OK) return -1;

    size_t cap = src_len * 4 + 1024;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { inflateEnd(&strm); return -1; }

    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)src_len;

    int ret;
    do {
        if ((size_t)strm.total_out >= cap) {
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (!nb) { free(buf); inflateEnd(&strm); return -1; }
            buf = nb;
        }
        strm.next_out = buf + strm.total_out;
        strm.avail_out = (uInt)(cap - (size_t)strm.total_out);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) {
            free(buf);
            inflateEnd(&strm);
            return -1;
        }
    } while (ret != Z_STREAM_END);

    *out_len = (size_t)strm.total_out;
    *out = buf;
    inflateEnd(&strm);
    return 0;
}

int cgzip_deflate(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits 15 + 16 => write a gzip header/trailer.
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        return -1;
    }

    size_t cap = deflateBound(&strm, src_len) + 64;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { deflateEnd(&strm); return -1; }

    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)src_len;
    strm.next_out = buf;
    strm.avail_out = (uInt)cap;

    int ret = deflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) {
        free(buf);
        deflateEnd(&strm);
        return -1;
    }

    *out_len = (size_t)strm.total_out;
    *out = buf;
    deflateEnd(&strm);
    return 0;
}
