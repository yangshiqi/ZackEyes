import Foundation
import RemoteCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("Usage: zackeyes --stream\nEmit read-only Claude/Codex session snapshots as JSON lines over SSH.")
    exit(0)
}
guard arguments == ["--stream"] else {
    FileHandle.standardError.write(Data("Usage: zackeyes --stream\n".utf8))
    exit(1)
}
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in _exit(0) }
signal(SIGHUP) { _ in _exit(0) }
func writeFrame(_ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            offset += count
        }
    }
}
var scanner = RemoteTranscriptScanner()
while true {
    do {
        try writeFrame(RemoteFrameCodec.encode(scanner.snapshot()))
    } catch {
        // Broken stdout means the SSH consumer has gone away. Other failures
        // are reported only on stderr, never mixed into the JSONL protocol.
        if (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(EPIPE) { exit(0) }
        FileHandle.standardError.write(Data("Remote session observation failed.\n".utf8))
        exit(1)
    }
    Thread.sleep(forTimeInterval: 5)
}
