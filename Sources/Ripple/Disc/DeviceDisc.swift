import CDShim
import Foundation
import RippleKit

/// A real drive: reads the table of contents and audio sectors from /dev/rdiskN.
/// Needs no mounted volume, and Ripple refuses the system's audio-disc mount while it runs.
nonisolated final class DeviceDisc: AudioDisc, @unchecked Sendable {
    enum OpenError: Error { case cannotOpen(Int32), noTableOfContents }

    let toc: DiscTOC
    private let fd: Int32

    init(bsdName: String) throws {
        let fd = open("/dev/r\(bsdName)", O_RDONLY)
        guard fd >= 0 else { throw OpenError.cannotOpen(errno) }
        // 4-byte header plus up to 100 descriptors of 8 bytes.
        var buffer = Data(count: 804)
        let size = buffer.withUnsafeMutableBytes { cdshim_read_toc(fd, $0.baseAddress, 804) }
        guard size > 0, let toc = DiscTOC(parsing: buffer.prefix(Int(size))) else {
            close(fd)
            throw OpenError.noTableOfContents
        }
        self.fd = fd
        self.toc = toc
    }

    deinit { close(fd) }

    func readSectors(start: Int, count: Int) throws -> Data {
        guard start >= 0, count >= 0, start + count <= toc.leadOut else { throw DiscError.outOfRange }
        var data = Data(count: count * Int(CDSHIM_SECTOR_BYTES))
        let read = data.withUnsafeMutableBytes { cdshim_read_sectors(fd, UInt32(start), UInt32(count), $0.baseAddress) }
        guard read == data.count else { throw DiscError.unreadable(sector: start) }
        return data
    }
}
