#ifndef CDSHIM_H
#define CDSHIM_H

#include <stdint.h>
#include <stddef.h>

/// Bytes in one CD audio sector (588 stereo frames of 16-bit samples).
#define CDSHIM_SECTOR_BYTES 2352

/// Reads the formatted table of contents (LBA addresses) into buf.
/// Returns the number of bytes written, or -1 with errno set.
int cdshim_read_toc(int fd, void *buf, uint16_t capacity);

/// Reads `count` audio sectors starting at sector `lba` into buf
/// (count * CDSHIM_SECTOR_BYTES bytes). Returns bytes read, or -1 with errno set.
int64_t cdshim_read_sectors(int fd, uint32_t lba, uint32_t count, void *buf);

#endif
