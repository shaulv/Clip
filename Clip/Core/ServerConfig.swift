import Foundation
import Security

/// Everything Clip needs to know about the user's own server.
///
/// These used to be values you edited by hand inside `config.php` on the server,
/// with one particular database name and one particular URL path baked into
/// the instructions as if everyone would use them. Neither is true: hosts differ, people already have
/// naming conventions, and editing PHP over a web file manager is the step most
/// likely to go wrong.
///
/// So every value lives here, and Clip writes the config file from them. The kit
/// you upload is already configured.
struct ServerConfig: Codable, Equatable {

    /// Where the API answers, e.g. `https://example.com/clip-api`.
    var address: String = ""

    /// From the application's point of view, on the server. Almost always
    /// `localhost`, because the site and the database sit on the same machine -
    /// but not on every host, which is why it is a field.
    var databaseHost: String = "localhost"
    var databaseName: String = ""
    var databaseUser: String = ""
    var databasePassword: String = ""

    /// A token is a bearer credential and is readable in transit over plain HTTP.
    var requireHTTPS: Bool = true

    /// Rows per sync response. Not a cap on what can be stored: the app pages
    /// until the cursor stops moving.
    var pageSize: Int = 200

    /// Creating a space is unauthenticated by design, so it is rate limited.
    var tokensPerHour: Int = 20

    /// Enough to generate a working config and reach the server.
    /// Whether a password is stored, without reading it.
    ///
    /// "Is it set?" and "what is it?" are different questions, and only the
    /// second one needs the Keychain. Keeping them apart is what lets the rest
    /// of the app answer "is this configured?" without ever holding the secret.
    var passwordIsStored: Bool = false

    /// A password is available if one was just typed, or one is already stored.
    var hasPassword: Bool { !databasePassword.isEmpty || passwordIsStored }

    var isComplete: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !databaseName.trimmingCharacters(in: .whitespaces).isEmpty
            && !databaseUser.trimmingCharacters(in: .whitespaces).isEmpty
            && hasPassword
    }

    /// What is still missing, so the UI can say so instead of just refusing.
    var missing: [String] {
        var out: [String] = []
        if address.trimmingCharacters(in: .whitespaces).isEmpty { out.append("the address") }
        if databaseName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("the database name") }
        if databaseUser.trimmingCharacters(in: .whitespaces).isEmpty { out.append("the database user") }
        if !hasPassword { out.append("the database password") }
        return out
    }

    /// The folder the API is reached at, taken from the address.
    ///
    /// Used only to tell the reader where to upload to, so it follows whatever
    /// they typed rather than assuming a folder name.
    var uploadPath: String {
        guard let url = URL(string: address), let host = url.host else { return "" }
        var path = url.path
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        return path.isEmpty ? "the site root" : "\(host)\(path)"
    }

    // MARK: - Storage
    //
    // The password goes to the Keychain, never the database. Everything else is
    // ordinary configuration.

    private static let key = "server.config"
    /// Public so `KeychainStore` can name this account in a failure sentence
    /// without needing to know anything else about `ServerConfig`.
    static let keychainAccount = "server.databasePassword"
    private static let passwordAccount = keychainAccount
    /// Records only THAT a password exists, never the password.
    private static let passwordSetKey = "serverPasswordIsSet"

    @MainActor
    static func load() -> ServerConfig {
        var config = ServerConfig()
        if let json = Database.shared.preference(key), !json.isEmpty,
           let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            config = saved
        }
        // The address has its own preference because SyncClient reads it on every
        // request; keeping one copy avoids the two disagreeing.
        config.address = Database.shared.preference("syncBaseURL") ?? config.address
        config.passwordIsStored = (Database.shared.preference(Self.passwordSetKey) ?? "") == "1"

        // The password is deliberately NOT read here.
        //
        // `load()` is called from the settings pane, the setup-kit writer, the
        // settings export and the QA state writer, and exactly one of those
        // needs the secret: the field that edits it. Fetching it every time
        // meant a Keychain read on every state write, which is slow, and it
        // put the plaintext password into memory in three places that had no
        // use for it. It also blocked the app outright: after a rebuild the
        // binary's signature changes, macOS asks the user to authorise
        // Keychain access, and an agent app with no window has nowhere to show
        // that prompt - so it hung at launch with no error.
        //
        // Callers that genuinely need it ask for it by name.
        return config
    }

    /// The configuration including the database password from the Keychain.
    ///
    /// Separate and explicitly named, so reading a secret is always a decision
    /// somebody made rather than a side effect of loading settings.
    @MainActor
    static func loadIncludingPassword() -> ServerConfig {
        var config = load()
        config.databasePassword = KeychainStore.get(passwordAccount) ?? ""
        return config
    }

    @MainActor
    func save() {
        var stored = self
        stored.databasePassword = ""            // never into the database
        if let data = try? JSONEncoder().encode(stored),
           let json = String(data: data, encoding: .utf8) {
            Database.shared.setPreference(Self.key, json)
        }
        Database.shared.setPreference("syncBaseURL",
                                      address.trimmingCharacters(in: .whitespaces))
        Database.shared.setPreference(Self.passwordSetKey,
                                      databasePassword.isEmpty ? "" : "1")
        if databasePassword.isEmpty {
            KeychainStore.remove(Self.passwordAccount)
            KeychainStore.markUnconfigured(Self.passwordAccount)
        } else {
            KeychainStore.markConfigured(Self.passwordAccount)
            let status = KeychainStore.set(databasePassword, for: Self.passwordAccount)
            if status != errSecSuccess {
                NoticeCenter.shared.report(
                    "The server password could not be saved.",
                    remedy: "Clip will try again automatically, or paste it again under "
                          + "Settings > Sync > Server.",
                    kind: .persistent, key: "keychain.needsRepair.\(Self.passwordAccount)")
            }
        }
    }

    // MARK: - The file the server runs

    /// Generates `config.php` from these values.
    ///
    /// Written by Clip rather than by hand, so the file that lands on the server
    /// is the one the app is already talking to. A typo here is a typo in one
    /// place, not two.
    var configPHP: String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        return """
        <?php
        /**
         * Clip sync service configuration.
         *
         * Written by Clip from Settings > Sync > Server. Edit it there rather than
         * here, so the app and the server cannot disagree about the same values.
         *
         * Keep this file where it is: the .htaccess beside it denies it to the web.
         */
        return [
            'db_host' => \(quoted(databaseHost)),
            'db_name' => \(quoted(databaseName)),
            'db_user' => \(quoted(databaseUser)),
            'db_pass' => \(quoted(databasePassword)),

            // A token is a bearer credential, readable in transit over plain HTTP.
            'require_https' => \(requireHTTPS ? "true" : "false"),

            // Rows per response. Not a cap on what a token may hold: the app pages
            // until the cursor stops moving.
            'page_size' => \(max(20, pageSize)),
            'page_bytes' => 4194304,

            // Creating a space needs no token by design, so it is rate limited.
            'tokens_per_hour' => \(max(1, tokensPerHour)),
        ];
        """
    }
}
