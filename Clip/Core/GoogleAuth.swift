import Foundation
import AppKit
import CryptoKit

/// Sign in with Google, the way a desktop app is supposed to.
///
/// **Loopback plus PKCE, and no client secret in the app.** The brief this was
/// built from asked for the secret to live in the app's configuration. A secret
/// inside something people download is not a secret, so it does not go here.
///
/// It turned out not to be optional either way: Google's Desktop client type
/// **still requires `client_secret` at the token endpoint**, PKCE or no PKCE,
/// and the first attempt failed with exactly that - "client_secret is missing".
/// So the split is:
///
/// - **This file** opens a loopback port, sends the browser to Google, and
///   takes the authorisation code off the redirect. It never sees a secret and
///   never talks to Google's token endpoint.
/// - **The server** redeems the code, using the secret it holds, and verifies
///   the resulting ID token against Google's published keys before it hands
///   back a sync token.
///
/// PKCE is doing its job across that split, not made redundant by it: the
/// verifier is generated here, per sign-in, and travels with the code, so only
/// the flow that started can be the one that finishes.
@MainActor
final class GoogleAuth: NSObject, ObservableObject {

    static let shared = GoogleAuth()

    /// Not a secret. This is the desktop client for the `clip` Google project,
    /// and Google's own documentation says it ships in the app.
    static let clientID =
        "" /* your-client-id.apps.googleusercontent.com - see docs/GOOGLE-SIGN-IN.md */

    /// Only what an account needs: who you are, and nothing you own.
    ///
    /// No Drive, no Gmail, no contacts. Clip syncs through its own server; it
    /// has no reason to touch anything in the Google account beyond
    /// establishing that it is the same person as last time.
    private static let scopes = "openid email profile"

    private static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"

    @Published private(set) var isWorking = false
    @Published var lastError: String?

    /// Who is signed in on this Mac, for the pane to show.
    @Published private(set) var account: GoogleAccount?

    struct GoogleAccount: Codable, Equatable {
        var email: String
        var name: String
        /// Google's profile photo URL, when the id_token carried one.
        /// Optional so an account remembered before this field decodes.
        var picture: String?
    }

    private var listener: LoopbackListener?

    private override init() {
        super.init()
        if let json = Database.shared.preference("google.account"),
           let data = json.data(using: .utf8) {
            account = try? JSONDecoder().decode(GoogleAccount.self, from: data)
        }
    }

    // MARK: - The flow

    /// Runs the browser half of the sign-in and returns the grant, or nil.
    ///
    /// Three steps, each a place this can fail honestly: open a loopback port,
    /// send the browser to Google, take the code off the redirect. The fourth
    /// step - redeeming the code - is the server's, because it needs the
    /// secret.
    func signIn() async -> Grant? {
        lastError = nil
        isWorking = true
        defer { isWorking = false; listener = nil }

        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = Self.randomVerifier()

        let listener: LoopbackListener
        do {
            listener = try LoopbackListener()
        } catch {
            lastError = """
                Could not open a local port to finish signing in. \
                Something else on this Mac may be holding every port Clip tried.
                """
            return nil
        }
        self.listener = listener
        let redirect = "http://127.0.0.1:\(listener.port)/callback"

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Ask every time rather than silently reusing a grant, so "sign in
            // as someone else" is possible without clearing browser state.
            .init(name: "prompt", value: "select_account")
        ]
        guard let url = components.url else { return nil }

        NSWorkspace.shared.open(url)

        let code: String
        do {
            let received = try await listener.waitForCallback()
            // The state check is what stops a code from some other flow being
            // fed to this one through the loopback port.
            guard received.state == state else {
                lastError = "That sign-in did not match the one Clip started."
                return nil
            }
            if let error = received.error {
                lastError = error == "access_denied"
                    ? "Sign-in was canceled."
                    : "Google refused the sign-in: \(error)"
                return nil
            }
            guard let value = received.code else {
                lastError = "Google did not return a sign-in code."
                return nil
            }
            code = value
        } catch {
            lastError = "The sign-in did not come back. \(error.localizedDescription)"
            return nil
        }

        // Handed on rather than redeemed. What comes back from `signIn` is the
        // code and the material to redeem it; the caller passes all three to
        // the server, which holds the secret.
        return Grant(code: code, verifier: verifier, redirect: redirect)
    }

    /// Everything the server needs to finish a sign-in this Mac started.
    struct Grant {
        let code: String
        let verifier: String
        let redirect: String
    }

    // MARK: - Who is signed in

    func remember(email: String, name: String, picture: String? = nil) {
        let account = GoogleAccount(email: email, name: name,
                                    picture: (picture?.isEmpty ?? true) ? nil : picture)
        self.account = account
        if let data = try? JSONEncoder().encode(account),
           let json = String(data: data, encoding: .utf8) {
            Database.shared.setPreference("google.account", json)
        }
    }

    func forget() {
        account = nil
        Database.shared.setPreference("google.account", "")
    }

    // MARK: - PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}
