// The `--out` file. A round counts as saved (and may be delete-acked under `--allow-delete`) only
// after it is written here and flushed to the drive, so the file must be a regular file: /dev/null,
// a pipe or a terminal would take the write and "sync" it without storing anything.

import Foundation

enum OutFileError: Error, Equatable, CustomStringConvertible {
    case notRegularFile(path: String, kind: String)
    case cannotCreate(path: String)
    case cannotOpen(path: String)

    var description: String {
        switch self {
        case .notRegularFile(let path, let kind):
            return "--out must be a regular file, and '\(path)' is \(kind): a round written there would count as saved without being stored"
        case .cannotCreate(let path): return "cannot create --out file '\(path)'"
        case .cannotOpen(let path): return "cannot open --out file '\(path)' for writing"
        }
    }
}

@available(macOS 10.15.4, *)
enum OutFile {

    /// Opens `path` for appending, creating it if needed. Fails unless it is a regular file (a
    /// symlink to one is fine). Checked before opening, so a FIFO cannot block the open, and again
    /// on the open descriptor.
    static func open(_ path: String) -> Result<FileHandle, OutFileError> {
        var info = stat()
        if stat(path, &info) == 0 {
            guard isRegular(info) else { return .failure(.notRegularFile(path: path, kind: kind(info))) }
        } else if !FileManager.default.createFile(atPath: path, contents: nil) {
            return .failure(.cannotCreate(path: path))
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return .failure(.cannotOpen(path: path)) }
        guard fstat(handle.fileDescriptor, &info) == 0, isRegular(info) else {
            try? handle.close()
            return .failure(.notRegularFile(path: path, kind: kind(info)))
        }
        handle.seekToEndOfFile()
        return .success(handle)
    }

    /// Flushes everything written so far to the drive. `fsync` (FileHandle.synchronize) is not enough
    /// on macOS: it leaves the data in the drive's cache. `F_FULLFSYNC` asks the drive to flush it
    /// too; a filesystem that cannot do that throws, and the round is then not durable.
    static func synchronize(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }

    private static func kind(_ info: stat) -> String {
        switch info.st_mode & S_IFMT {
        case S_IFCHR: return "a character device"
        case S_IFBLK: return "a block device"
        case S_IFDIR: return "a directory"
        case S_IFIFO: return "a pipe"
        case S_IFSOCK: return "a socket"
        default: return "not a regular file"
        }
    }
}
