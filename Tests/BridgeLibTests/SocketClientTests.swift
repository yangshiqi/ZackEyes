import Foundation
import Testing
@testable import BridgeLib

// POSIX imports for raw socket server in tests
#if canImport(Darwin)
import Darwin
#endif

@Suite("BridgeSocketClient")
struct SocketClientTests {

    // MARK: - Test 1: connect failure when socket missing

    @Test("sendFireAndForget returns false when socket path does not exist")
    func socketClient_connectFailure_whenSocketMissing() async {
        let path = "/tmp/zackeyes-test-\(UUID().uuidString).sock"
        let client = BridgeSocketClient(path: path)
        let data = Data("{\"test\":true}\n".utf8)
        let result = client.sendFireAndForget(data: data)
        #expect(result == false)
    }

    // MARK: - Test 2: send and receive through a real Unix socket

    @Test("sendAndWaitForResponse echoes data through a real Unix socket server")
    func socketClient_sendAndReceive_throughRealSocket() async throws {
        let path = "/tmp/zackeyes-test-\(UUID().uuidString).sock"
        defer { unlink(path) }

        // --- Build server socket ---
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(serverFd >= 0, "socket() failed")

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 108) { buf in
                _ = path.withCString { strncpy(buf, $0, 107) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0, "bind() failed: \(errno)")

        #expect(listen(serverFd, 1) == 0, "listen() failed")

        // --- Echo server in detached task ---
        Task.detached {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(clientFd, &buf, buf.count)
            if n > 0 {
                _ = write(clientFd, buf, n)
            }
            close(clientFd)
            close(serverFd)
        }

        // Give the server task time to reach accept()
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // --- Client side ---
        let payload = "{\"test\":true}\n"
        let data = Data(payload.utf8)
        let client = BridgeSocketClient(path: path)
        let response = client.sendAndWaitForResponse(data: data, timeoutSeconds: 5)

        #expect(response != nil, "Expected a response, got nil")
        #expect(response == data, "Expected echoed data to equal sent data")
    }
}
