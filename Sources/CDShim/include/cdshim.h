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

/// The drive's current read speed in kilobytes per second (176 is 1x), or -1 with errno set.
int cdshim_get_speed(int fd);

/// Asks the drive for this read speed; 0xFFFF means as fast as it can. Returns 0, or -1 with errno set.
int cdshim_set_speed(int fd, uint16_t speed);

#endif
