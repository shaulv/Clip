import Foundation
import Darwin

/// Starts the local sync service on demand.
///
/// Sign-in used to fail with "could not connect to the server" unless the user
/// had already started a Python process by hand. That is not sign-in, it is
/// homework. Clip launches the service itself the first time an account needs
/// it, and says something useful if it cannot.
@MainActor
final class SyncService: ObservableObject {

    static let shared = SyncService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var process: Process?
    private init() {}

    private var port: UInt16 {
        UInt16(SyncClient.shared.baseURL?.port ?? 8787)
    }

    /// Where the service lives.
    ///
    /// Counting `..` levels from the bundle is how this broke the first time: the
    /// arithmetic was one directory short and the error read "reinstall Clip",
    /// which was both wrong and unhelpful. Walking up until the file is found
    /// works from a bundle, from a build directory, and from a source checkout,
    /// whatever the nesting happens to be.
    private var scriptURL: URL? {
        let fileManager = FileManager.default
        let relative = "sync-server/server.py"

        // Shipped inside the app.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(relative),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        // Otherwise search upward from the bundle for the source tree.
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Returns once the service answers, starting it if needed.
    ///
    /// Only ever starts anything when the app is pointed at *this machine*. With
    /// a real service on a domain there is nothing here to start, and launching a
    /// local one anyway would leave a stray process behind and make a network
    /// failure look like a local one.
    func ensureRunning() async throws {
        guard SyncClient.shared.isLocalService else { isRunning = false; return }
        if Self.isPortOpen(port) { isRunning = true; return }
        try start()
        try await waitUntilReady()
    }

    private func start() throws {
        guard let script = scriptURL else {
            throw SyncError.server("""
                Clip could not find its sync service. Reinstall Clip, or point it at \
                a service in Settings.
                """)
        }
        guard let python = Self.findPython() else {
            throw SyncError.server("""
                Clip needs Python 3 to run its local sync service, and could not find \
                it. Install it from python.org, or point Clip at a hosted service.
                """)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [script.path, "--port", String(port),
                          "--db", AppPaths.support.appendingPathComponent("sync.sqlite").path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            process = task
        } catch {
            throw SyncError.server("Could not start the sync service: \(error.localizedDescription)")
        }
    }

    private func waitUntilReady(timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.isPortOpen(port) {
                isRunning = true
                Database.shared.log("sync", "Started the local sync service on port \(port)")
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw SyncError.server("The sync service did not start in time.")
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    // MARK: - Helpers

    /// The first `python3` that actually exists. `/usr/bin/env` alone is not
    /// enough: a Process needs a real executable path.
    private static func findPython() -> String? {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3",
                          "/usr/local/bin/python3"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Fall back to asking the shell where it is.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    nonisolated static func isPortOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
