import Foundation

/// Where "Sign in with Google" syncs to.
///
/// **This is deliberately empty in the open-source tree.**
///
/// The upstream build points this at a service its author runs. Shipping that
/// address in a public repository would mean every fork syncing strangers into
/// somebody else's database, so the export strips it.
///
/// With no address here, Google sign-in reports itself as unavailable and the
/// other two methods are unaffected: "use your own server with this token"
/// works exactly as before, and so does backup import and export. That is the
/// right default. An app that ships with a sync server nobody chose is an app
/// that quietly sends your clipboard somewhere you never agreed to.
///
/// To run your own: stand up `sync-server-php` (see docs/SELF-HOSTING.md), then
/// return the address here. It does not need to be hidden - see the note below.
///
/// ## On hiding the address
///
/// The upstream build stores it XOR-ed so it is not visible to `strings`. That
/// is worth doing and worth being honest about: an address inside a
/// downloadable app cannot be a secret, because the app has to know where to
/// connect and a proxy watching one request recovers it. The address was never
/// the security boundary. Every endpoint requires either a valid sync token or
/// an identity token that Google signed and the server verified. Knowing where
/// the door is does not open it.
enum OfficialService {

    /// nil means "no official service in this build".
    static var url: URL? { nil }

    static let displayName = "Clip's own service"

    static var isConfigured: Bool { url != nil }
}
