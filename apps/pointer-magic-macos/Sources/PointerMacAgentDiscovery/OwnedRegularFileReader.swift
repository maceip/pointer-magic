import Darwin
import Foundation

/// An owned, bounded snapshot of one regular-file descriptor.
///
/// Provider files are concurrently replaced and truncated. Opening with `O_NOFOLLOW`
/// and validating the same descriptor closes the pathname TOCTOU that can otherwise
/// turn a prior `lstat` into a blocking FIFO read or a read from a different inode.
struct OwnedRegularFileSnapshot: Sendable {
    let data: Data
    let device: UInt64
    let inode: UInt64
    let fileSize: UInt64
}

enum OwnedRegularFileReader {
    static func read(
        path: String,
        offset: UInt64 = 0,
        maximumBytes: Int
    ) -> OwnedRegularFileSnapshot? {
        guard maximumBytes > 0,
              offset <= UInt64(Int64.max)
        else { return nil }

        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = Darwin.stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0
        else { return nil }

        let fileSize = UInt64(metadata.st_size)
        guard offset <= fileSize else { return nil }
        let available = fileSize - offset
        let requestedCount = Int(min(UInt64(maximumBytes), available))
        var bytes = [UInt8](repeating: 0, count: requestedCount)
        var copiedCount = 0

        let readSucceeded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard requestedCount == 0 || buffer.baseAddress != nil else { return false }
            while copiedCount < requestedCount {
                let position = offset + UInt64(copiedCount)
                let copied = Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: copiedCount),
                    requestedCount - copiedCount,
                    off_t(position)
                )
                if copied > 0 {
                    copiedCount += copied
                } else if copied == 0 {
                    // The inode was truncated after fstat. Return the owned prefix;
                    // parsers will retain only complete records and retry next scan.
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readSucceeded else { return nil }

        let data = copiedCount == bytes.count
            ? Data(bytes)
            : Data(bytes.prefix(copiedCount))
        return OwnedRegularFileSnapshot(
            data: data,
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            fileSize: fileSize
        )
    }
}
