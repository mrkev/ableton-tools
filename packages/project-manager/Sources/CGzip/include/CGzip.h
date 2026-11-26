#ifndef CGZIP_H
#define CGZIP_H

#include <stddef.h>
#include <stdint.h>

// Decompress gzip- (or zlib-) framed data. On success returns 0 and allocates
// *out via malloc (caller must free). Returns non-zero on failure.
int cgzip_inflate(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len);

// Compress data to gzip framing. On success returns 0 and allocates *out via
// malloc (caller must free). Returns non-zero on failure.
int cgzip_deflate(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len);

#endif
