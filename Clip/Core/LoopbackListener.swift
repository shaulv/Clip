import Foundation
import Darwin

/// A one-shot HTTP server on 127.0.0.1, for an OAuth redirect to land in.
///
/// The redirect has to come back somewhere, and for a Mac app the two choices
/// are a custom URL scheme or a loopback address. Loopback is what Google
/// recommends for desktop clients and the one that cannot be hijacked by
/// another app registering the same scheme - a real attack on macOS, where
/// scheme registration is first-come and unpoliced.
///
/// **Why a raw socket rather than `NWListener`.** The first version used
/// Network.framework and failed every time with "could not open a local port".
/// `NWListener` does not publish its port until it reaches `.ready`, which is
/// asynchronous, so the authorisation URL - which has to contain the port -
/// could not be built at the moment it was needed. Spinning for it blocked the
/// main actor and still lost the race. `bind` to port 0 answers immediately and
/// `getsockname` reads the port straight back, which is the whole requirement.
///
/// Deliberately minimal: one connection, one request line, one reply, then
/// closed. It speaks just enough HTTP to satisfy a browser, because a
/// general-purpose server listening on someone's Mac is a much larger thing to
/// be responsible for than this job needs.
// `@unchecked Sendable`: every mutable property this class owns (`continuation`,
// `finished`, `closed`) is documented above as reached only through
// `stateQueue`, a serial queue - that queue IS the synchronization, it is just
// not something the compiler can see. Without this, the `[weak self]` capture
// in the two `stateQueue`/`acceptQueue` closures below (both `@Sendable`
// under Swift 6, since `DispatchQueue.async` takes one) warns on capturing a
// non-Sendable class, and that warning becomes a hard error under the Swift 6
// language mode.
final class LoopbackListener: @unchecked Sendable {

    struct Callback {
        var code: String?
        var state: String?
        var error: String?
    }

    enum Failure: LocalizedError {
        case noPort(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noPort(let detail): return "No local port was available (\(detail))."
            case .timedOut:           return "The sign-in was not completed in time."
            }
        }
    }

    let port: UInt16

    private let socketHandle: Int32
    /// Guards `finished` and the continuation. Serial, and never blocked.
    private let stateQueue = DispatchQueue(label: "clip.oauth.loopback.state")
    /// Where `accept` parks. It has to be somewhere that can block for five
    /// minutes without stopping anything else - notably the deadline, which in
    /// the first version shared the serial queue with `accept` and therefore
    /// could never fire while it was waiting.
    private let acceptQueue = DispatchQueue(label: "clip.oauth.loopback.accept")
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished = false
    private var closed = false

    /// Binds to an ephemeral port on the loopback interface only.
    init() throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure.noPort("socket: \(errno)") }

        // Without this a listener left in TIME_WAIT by a previous sign-in makes
        // the next one fail, and the failure looks permanent.
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                    // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")        // loopback only
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw Failure.noPort("bind: \(errno)")
        }
        guard listen(handle, 1) == 0 else {
            close(handle)
            throw Failure.noPort("listen: \(errno)")
        }

        // The port, read back from the kernel. This is the line the Network
        // framework version could not give synchronously.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0, actual.sin_port != 0 else {
            close(handle)
            throw Failure.noPort("getsockname: \(errno)")
        }

        socketHandle = handle
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { shutDown() }

    /// Waits for the browser to arrive, or gives up.
    ///
    /// A listener with no deadline is a port held open for the life of the app
    /// because somebody closed the tab and forgot.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.continuation = continuation
                self.acceptQueue.async { self.accept() }
            }
            // On the state queue, which stays responsive. Firing it closes the
            // listening socket, which is also what unparks `accept`.
            stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(Failure.timedOut))
            }
        }
    }

    /// Blocks this queue's thread until the browser connects. That is what the
    /// dedicated queue is for.
    private func accept() {
        let client = Darwin.accept(socketHandle, nil, nil)
        guard client >= 0 else {
            // A closed listening socket is the ordinary way out when the
            // deadline fired first. `finish` only resumes once, so reporting it
            // here is harmless and covers the case where accept failed for a
            // reason of its own.
            finish(.failure(Failure.noPort("accept: \(errno)")))
            return
        }

        var request = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        // One read is enough: a browser sends the whole request line in the
        // first segment, and everything wanted is in it.
        let read = recv(client, &buffer, buffer.count, 0)
        if read > 0 {
            request = String(decoding: buffer[0..<read], as: UTF8.self)
        }
        let callback = Self.parse(request)

        let body = Self.page(success: callback.code != nil)
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        _ = Array(response.utf8).withUnsafeBufferPointer {
            send(client, $0.baseAddress, $0.count, 0)
        }
        close(client)
        finish(.success(callback))
    }

    /// The query string off the first request line.
    private static func parse(_ request: String) -> Callback {
        guard let line = request.components(separatedBy: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)")
        else { return Callback() }

        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        return Callback(code: value("code"), state: value("state"), error: value("error"))
    }

    /// What the browser shows. The person is mid-task in another app, so it
    /// says the one thing they need: go back.
    private static func page(success: Bool) -> String {
        """
        <!doctype html><meta charset="utf-8">
        <title>Clip</title>
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; color: #1c1c1e;
                 background: #f5f5f7; display: grid; place-items: center;
                 height: 100vh; margin: 0; }
          .card { background: #fff; padding: 32px 40px; border-radius: 14px;
                  box-shadow: 0 8px 30px rgba(0,0,0,.08); text-align: center; }
          h1 { font-size: 17px; margin: 0 0 6px; }
          p { margin: 0; color: #6e6e73; font-size: 13px; }
          @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; color: #f5f5f7; }
            .card { background: #2c2c2e; box-shadow: none; }
            p { color: #98989d; }
          }
        </style>
        <div class="card">
          <h1>\(success ? "Signed in" : "Sign-in did not complete")</h1>
          <p>\(success ? "You can close this tab and go back to Clip."
                       : "Nothing was changed. Close this tab and try again in Clip.")</p>
        </div>
        """
    }

    /// Closing the socket is what unparks `accept`, so it must be safe to call
    /// from any queue and more than once.
    private func shutDown() {
        guard !closed else { return }
        closed = true
        // Shutting down before closing is what unblocks a thread parked in
        // accept(); closing alone can leave it there until the process exits.
        shutdown(socketHandle, SHUT_RDWR)
        close(socketHandle)
    }

    /// Resumes the waiter exactly once. The browser arriving and the deadline
    /// firing race for this, and resuming a continuation twice is a crash.
    private func finish(_ result: Result<Callback, Error>) {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            let waiting = self.continuation
            self.continuation = nil
            self.shutDown()
            switch result {
            case .success(let callback): waiting?.resume(returning: callback)
            case .failure(let error):    waiting?.resume(throwing: error)
            }
        }
    }
}
