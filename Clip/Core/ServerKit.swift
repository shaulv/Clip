import Foundation
import AppKit

/// Everything a person needs to run their own sync server.
///
/// Sync used to point at one particular domain by default, which meant anybody
/// else running this build would have synced their clipboard into somebody
/// else's database. The address is now per-install and starts empty, and this is
/// what makes that practical rather than merely correct: a folder you can upload
/// and a page telling you what to do with it.
enum ServerKit {

    enum KitError: LocalizedError {
        case missingSources
        case write(String)

        var errorDescription: String? {
            switch self {
            case .missingSources:
                return "This build does not include the server files."
            case .write(let detail):
                return "Could not write the setup folder: \(detail)"
            }
        }
    }

    /// Where the API sources live: inside the app when installed, in the source
    /// tree when running from a build directory.
    ///
    /// Only `api/` and `schema.sql` are shipped. The folder they come from also
    /// holds a test harness, a deploy script and - before this was noticed - a
    /// file with real database credentials, none of which belong inside an app
    /// that other people run.
    private struct Sources {
        let api: URL
        let schema: URL
    }

    private static var sources: Sources? {
        let fileManager = FileManager.default

        if let resources = Bundle.main.resourceURL {
            let api = resources.appendingPathComponent("api")
            let schema = resources.appendingPathComponent("schema.sql")
            if fileManager.fileExists(atPath: api.path),
               fileManager.fileExists(atPath: schema.path) {
                return Sources(api: api, schema: schema)
            }
        }

        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let root = directory.appendingPathComponent("sync-server-php")
            let api = root.appendingPathComponent("api")
            let schema = root.appendingPathComponent("schema.sql")
            if fileManager.fileExists(atPath: api.path),
               fileManager.fileExists(atPath: schema.path) {
                return Sources(api: api, schema: schema)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Writes the setup folder and returns where it landed.
    @discardableResult
    @MainActor
    static func writeKit(to destination: URL, config: ServerConfig? = nil) throws -> URL {
        // The kit writes a real `config.php`, so this is one of the two places
        // that genuinely needs the secret. `exportSettings` below deliberately
        // does not, and keeps using the password-free load.
        let config = config ?? ServerConfig.loadIncludingPassword()
        guard let sources else { throw KitError.missingSources }
        let fileManager = FileManager.default
        let root = destination.appendingPathComponent("Clip-Sync-Server")

        // A second run must not fail because the first one is still there, and
        // must not silently merge into it either.
        if fileManager.fileExists(atPath: root.path) {
            let stamped = destination.appendingPathComponent(
                "Clip-Sync-Server-\(Int(Date().timeIntervalSince1970))")
            try? fileManager.moveItem(at: root, to: stamped)
        }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            // The API, loose, for anyone who would rather use FTP.
            let api = root.appendingPathComponent("api")
            try fileManager.copyItem(at: sources.api, to: api)

            // config.php is generated from the values in Settings, so what lands
            // on the server is already configured. Editing PHP through a web file
            // manager is the step most likely to go wrong, and this removes it.
            let configFile = api.appendingPathComponent("config.php")
            try? fileManager.removeItem(at: configFile)
            try config.configPHP.write(to: configFile, atomically: true, encoding: .utf8)

            try fileManager.copyItem(at: sources.schema,
                                     to: root.appendingPathComponent("schema.sql"))

            try steps(for: config).write(to: root.appendingPathComponent("START-HERE.html"),
                                         atomically: true, encoding: .utf8)

            // One archive to upload, because a hundred small transfers is how a
            // deploy ends up half-finished.
            try zip(api, named: "clipassets", into: root)
        } catch {
            throw KitError.write(error.localizedDescription)
        }
        return root
    }

    /// Builds `clipassets.zip` with the API inside `clipassets/api/`, which is
    /// the shape the extract step expects.
    private static func zip(_ api: URL, named: String, into root: URL) throws {
        let staging = root.appendingPathComponent("clipassets")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: api, to: staging.appendingPathComponent("api"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-r", "-q", "\(named).zip", "clipassets"]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Settings, so the second Mac is quick

    private static let settingsVersion = 1

    /// The connection settings, without anything secret in them.
    ///
    /// The token is deliberately absent. The address says *which server*; the
    /// token says *which data*. Keeping them apart means this file can be sent
    /// to your other Mac without also sending the contents of your clipboard,
    /// and it matches how it gets used: import the settings, paste the token.
    @MainActor
    static func exportSettings() -> Data? {
        let config = ServerConfig.load()
        let payload: [String: Any] = [
            "application": "Clip",
            "kind": "sync-settings",
            "version": settingsVersion,
            "service": config.address,
            "databaseHost": config.databaseHost,
            "databaseName": config.databaseName,
            "databaseUser": config.databaseUser,
            "requireHTTPS": config.requireHTTPS,
            "pageSize": config.pageSize,
            "tokensPerHour": config.tokensPerHour,
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
    }

    enum ImportResult {
        case applied(String)
        case notClipSettings
        case noService
    }

    @discardableResult
    @MainActor
    static func importSettings(from data: Data) -> ImportResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["application"] as? String == "Clip",
              json["kind"] as? String == "sync-settings" else {
            return .notClipSettings
        }
        guard let service = json["service"] as? String, !service.isEmpty,
              URL(string: service) != nil else {
            return .noService
        }

        var config = ServerConfig.load()
        config.address = service
        config.databaseHost = json["databaseHost"] as? String ?? config.databaseHost
        config.databaseName = json["databaseName"] as? String ?? config.databaseName
        config.databaseUser = json["databaseUser"] as? String ?? config.databaseUser
        config.requireHTTPS = json["requireHTTPS"] as? Bool ?? config.requireHTTPS
        config.pageSize = json["pageSize"] as? Int ?? config.pageSize
        config.tokensPerHour = json["tokensPerHour"] as? Int ?? config.tokensPerHour
        // The password is never in the file, so whatever this Mac already had
        // stays - and on a fresh Mac it is simply blank until it is entered.
        config.save()

        Database.shared.log("sync", "Imported server settings pointing at \(service)")
        return .applied(service)
    }

    // MARK: - The steps

    /// The setup page, written around the values the user actually entered.
    ///
    /// Deliberately not about any one control panel. The previous version named
    /// cPanel, phpMyAdmin and File Manager at every step, which is fine until
    /// somebody's host has none of them - and then the instructions are not
    /// merely unhelpful, they describe buttons that do not exist. What every
    /// host has in common is: a way to make a database, a way to run a `.sql`
    /// file, and a way to put files on the server. So the steps are those, with
    /// the panel-driven route mentioned as one way among several.
    static func steps(for config: ServerConfig) -> String {
        let database = config.databaseName.isEmpty ? "your database" : config.databaseName
        let user = config.databaseUser.isEmpty ? "your database user" : config.databaseUser
        let destination = config.uploadPath.isEmpty
            ? "the folder your address points at"
            : config.uploadPath
        let address = config.address.isEmpty
            ? "the address you entered in Clip"
            : config.address

        return """
        <!doctype html>
        <meta charset="utf-8">
        <title>Set up your Clip sync server</title>
        <style>
          body { font: 15px/1.6 -apple-system, system-ui, sans-serif; color: #1d1d1f;
                 max-width: 720px; margin: 40px auto; padding: 0 24px; }
          h1 { font-size: 26px; margin-bottom: 4px; }
          .lede { color: #6e6e73; margin-top: 0; }
          h2 { font-size: 17px; margin-top: 34px; }
          code { background: #f2f2f7; padding: 2px 5px; border-radius: 4px;
                 font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
          ol { padding-left: 22px; } li { margin: 9px 0; }
          .note { background: #f2f7ff; border-left: 3px solid #3b7dd8;
                  padding: 12px 16px; border-radius: 0 6px 6px 0; margin: 22px 0; }
          .warn { background: #fff7ed; border-left-color: #d97706; }
          table { border-collapse: collapse; margin: 14px 0; font-size: 14px; }
          td { padding: 4px 14px 4px 0; vertical-align: top; }
          td:first-child { color: #6e6e73; }
          footer { margin-top: 44px; color: #6e6e73; font-size: 13px; }
        </style>

        <h1>Your Clip sync server</h1>
        <p class="lede">Three things: a database, a table structure, and a folder of
        files. Any hosting that runs PHP 8 and MySQL can do all three.</p>

        <div class="note">
          <strong>Already filled in.</strong> These files were written using the
          settings you entered in Clip, so there is no configuration to edit here.
          <table>
            <tr><td>Address</td><td><code>\(address)</code></td></tr>
            <tr><td>Database</td><td><code>\(database)</code></td></tr>
            <tr><td>Database user</td><td><code>\(user)</code></td></tr>
            <tr><td>Upload to</td><td><code>\(destination)</code></td></tr>
          </table>
          If any of that is wrong, change it in Clip and save this folder again -
          do not edit the files by hand, or the app and the server will disagree.
        </div>

        <h2>1. Create the database and its user</h2>
        <p>Make a database named <code>\(database)</code> and a user
        <code>\(user)</code>, and give that user full rights on that database.</p>
        <ul>
          <li><strong>With a hosting control panel</strong> - look for a database
              section. It will ask for a name, then a user, then which user may use
              which database.</li>
          <li><strong>With shell access</strong> - <code>CREATE DATABASE</code>,
              <code>CREATE USER</code>, <code>GRANT ALL ON \(database).* TO
              …</code>.</li>
        </ul>
        <div class="warn note">
          Some hosts silently prefix what you type, so <code>\(database)</code>
          becomes something like <code>account_\(database)</code>. <strong>The
          prefixed name is the real one</strong> - put that back into Clip and save
          this folder again.
        </div>

        <h2>2. Create the tables</h2>
        <p>Run <code>schema.sql</code> from this folder against that database. A
        database tool, a web admin page, or
        <code>mysql -u user -p \(database) &lt; schema.sql</code> - whichever your
        host gives you.</p>
        <p>You should end up with six tables: <code>spaces</code>,
        <code>tokens</code>, <code>devices</code>, <code>records</code>,
        <code>counters</code> and <code>throttle</code>.</p>
        <div class="note">
          <strong>They will be empty, and that is correct.</strong> The file builds
          the shape only. Your clips arrive the first time Clip syncs, so an empty
          database here means it worked - not that it failed.
        </div>

        <h2>3. Put the files where your address points</h2>
        <p>Your address is <code>\(address)</code>, so the <code>api</code> folder
        has to end up at <code>\(destination)</code>.</p>
        <ul>
          <li><strong>By upload</strong> - send <code>clipassets.zip</code> and
              unpack it there, or drag the <code>api</code> folder over by FTP.</li>
          <li><strong>By shell</strong> - copy the <code>api</code> folder into
              place.</li>
        </ul>
        <p>Whatever the route, a browser hitting <code>\(address)/health</code>
        should answer with a short line of JSON.</p>

        <h2>4. Point Clip at it</h2>
        <ol>
          <li>In Clip: <strong>Settings &rarr; Sync &rarr; Server</strong>.</li>
          <li>Press <strong>Test</strong>. You want <em>"Your server answered"</em>.</li>
          <li>Press <strong>Create a Sync Token</strong>. Your history uploads, and
              the tables from step 2 stop being empty.</li>
        </ol>

        <h2>5. Your other Macs</h2>
        <ol>
          <li>On this Mac: <strong>Export Settings…</strong>, and send yourself the
              small <code>.clipsync</code> file.</li>
          <li>On the other one: <strong>Import Settings…</strong> and pick it. That
              Mac now points at your server with nothing retyped.</li>
          <li>Paste the token from this Mac and press Connect.</li>
        </ol>
        <p>The settings file carries the address and the database details, never the
        token. The address says which server; the token says which data.</p>

        <h2>If something is wrong</h2>
        <ul>
          <li><strong>Test cannot reach it</strong> - the files are not where the
              address points. Try <code>\(address)/health</code> in a browser.</li>
          <li><strong>"could not reach its database"</strong> - the name, the user or
              the password. Usually the host's prefix; see step 1.</li>
          <li><strong>A 500 with nothing else</strong> - the host is running PHP 7.
              Set that domain to PHP 8 or newer.</li>
          <li><strong>"That sync token is not valid"</strong> - the token belongs to
              a different server. Disconnect and create a new one.</li>
        </ul>

        <footer>Generated by Clip. These files are yours; nothing reports back.</footer>
        """
    }
}
