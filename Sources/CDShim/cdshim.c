#include "cdshim.h"

#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <IOKit/storage/IOCDTypes.h>
#include <IOKit/storage/IOCDMediaBSDClient.h>

int cdshim_read_toc(int fd, void *buf, uint16_t capacity) {
    dk_cd_read_toc_t request;
    memset(&request, 0, sizeof request);
    request.format = 0x00;                                   // formatted TOC
    request.formatAsTime = 0;                                // LBA, not MSF
    request.address.track = 0;                               // from the first track
    request.buffer = buf;
    request.bufferLength = capacity;
    if (ioctl(fd, DKIOCCDREADTOC, &request) < 0) return -1;
    return request.bufferLength;
}

int64_t cdshim_read_sectors(int fd, uint32_t lba, uint32_t count, void *buf) {
    dk_cd_read_t request;
    memset(&request, 0, sizeof request);
    request.offset = (uint64_t)lba * CDSHIM_SECTOR_BYTES;
    request.sectorArea = kCDSectorAreaUser;
    request.sectorType = kCDSectorTypeCDDA;
    request.buffer = buf;
    request.bufferLength = count * CDSHIM_SECTOR_BYTES;
    if (ioctl(fd, DKIOCCDREAD, &request) < 0) return -1;
    return request.bufferLength;
}
