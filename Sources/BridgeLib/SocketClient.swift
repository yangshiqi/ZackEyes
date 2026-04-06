import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct BridgeSocketClient: Sendable {

    private let path: String

    public init(path: String) {
        self.path = path
    }

    // MARK: - Private helpers

    /// Creates a connected AF_UNIX/SOCK_STREAM socket.
    /// Returns a valid file descriptor on success, or -1 on any failure.
    private func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path into the fixed-size sun_path char array
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                _ = path.withCString { strncpy(buf, $0, maxLen) }
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - Public API

    /// Connect, write all data, close. Returns true iff all bytes were written.
    @discardableResult
    public func sendFireAndForget(data: Data) -> Bool {
        let fd = connect()
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var totalWritten = 0
        let count = data.count
        let written: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n <= 0 { return false }
                totalWritten += n
            }
            return true
        }
        return written && totalWritten == count
    }

    /// Connect, set SO_RCVTIMEO, write data, read response, close.
    /// Returns the response Data, or nil on any error or timeout.
    public func sendAndWaitForResponse(data: Data, timeoutSeconds: Int) -> Data? {
        let fd = connect()
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Set receive timeout
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Write all data
        var totalWritten = 0
        let count = data.count
        let sendOK: Bool = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n <= 0 { return false }
                totalWritten += n
            }
            return true
        }
        guard sendOK else { return nil }

        // Read response (up to 64 KB)
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }
}
