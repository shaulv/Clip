import Foundation

/// Reads the title out of a copied link's own page.
///
/// A link row showing `figma.com` tells you which site and nothing else - and a
/// history of twenty Figma links is twenty identical rows. The page's title is
/// what a person actually recognises, so it is worth one small request to get it.
///
/// That request is the reason this is a preference rather than always-on: asking
/// a site for its title tells that site you copied the link. It is stated plainly
/// in Privacy, and it can be turned off.
///
/// It is also the reason this file is security-relevant even though it never
/// stores a secret: it is a request the app makes to a URL a user copied, not a
/// URL a user chose to visit. A copied link is not a trusted input - it can point
/// at the machine's own loopback address, a metadata endpoint on link-local, or
/// an internal service on a private range, and it can redirect there even when
/// the original URL looked public. Refusing those targets, before ever opening a
/// connection, is what keeps "fetch the title of a copied link" from becoming an
/// SSRF probe of the user's own LAN.
enum LinkMetadata {

    /// Only ever reads the head of the document.
    ///
    /// A title lives in the first few kilobytes. Downloading a whole page - which
    /// can be megabytes - to read forty characters would make copying a link feel
    /// like loading a website, which is exactly what a clipboard manager must not
    /// do. This is now enforced by actually cutting the connection once this many
    /// bytes have been read, not by asking nicely and slicing the answer after.
    private static let byteLimit = 96 * 1024
    private static let timeout: TimeInterval = 8
    /// A public host can still redirect somewhere private. Each hop is
    /// re-validated against the same range check as the original URL, and the
    /// chain is cut short well before it could matter.
    fileprivate static let maxRedirects = 2

    #if CLIP_TESTING
    /// The one host a run may reach despite the private/loopback guard below,
    /// so security-probe.py can point the byte-cap and redirect checks at a
    /// local test server it starts itself, without disabling the guard the
    /// checks exist to prove. `nil` in every other run, and this whole branch
    /// is compiled out of Release - nothing an attacker controls can set it,
    /// the same seam `TestIsolation` uses.
    static var testAllowedHost: String?
    /// Actual bytes read off the wire for the most recent fetch, so a probe
    /// can assert the cap was enforced at the transport layer - not merely
    /// that the returned string is short, which a fully-downloaded-then-
    /// sliced response would also satisfy.
    static var lastBytesReadForTesting = 0
    /// Counts only past the host guard, so a probe can tell "refused before
    /// any request was made" (this stays 0) apart from "the request ran and
    /// simply found nothing" (this increments either way).
    static var requestsAttemptedForTesting = 0
    #endif

    /// Fetches the page title, or nil if there isn't a usable one.
    static func title(for url: URL) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let host = url.host, hostIsSafe(host) else {
            return nil
        }
        #if CLIP_TESTING
        requestsAttemptedForTesting += 1
        #endif

        let delegate = RedirectGuardDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // Range is a request, not a promise: a server may send the lot anyway,
        // which is exactly why the read below is capped by actually counting
        // bytes as they arrive, not by trusting this header.
        request.setValue("bytes=0-\(byteLimit)", forHTTPHeaderField: "Range")
        // Some sites serve a different, title-less page to unknown clients.
        request.setValue("Mozilla/5.0 (Macintosh) Clip/1.0", forHTTPHeaderField: "User-Agent")

        guard let (byteStream, response) = try? await session.bytes(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            return nil
        }

        // Streamed, not buffered: the connection is cancelled the moment
        // byteLimit bytes have actually been read, so a server that ignores
        // Range and keeps sending megabytes never gets to hand the whole body
        // over before this returns - the old code called
        // `URLSession.shared.data(for:)` first and sliced afterwards, which
        // let the full response land in memory regardless of the header.
        var data = Data()
        data.reserveCapacity(byteLimit)
        do {
            readLoop: for try await byte in byteStream {
                data.append(byte)
                if data.count >= byteLimit {
                    byteStream.task.cancel()
                    break readLoop
                }
            }
        } catch {
            // The cancel above is expected to surface here as an error on the
            // stream; anything already read is still usable.
        }
        #if CLIP_TESTING
        lastBytesReadForTesting = data.count
        #endif
        let html = String(decoding: data, as: UTF8.self)
        return parseTitle(from: html)
    }

    /// True when `host` is safe to contact right now: not loopback,
    /// link-local, private, unspecified or multicast, whether it was given as
    /// a literal address or has to be resolved first. `RedirectGuardDelegate`
    /// below calls this again for every redirect hop, since a host that
    /// passes here can still hand back a `Location` pointed at one that would
    /// not.
    fileprivate static func hostIsSafe(_ host: String) -> Bool {
        #if CLIP_TESTING
        if let allowed = testAllowedHost, host.caseInsensitiveCompare(allowed) == .orderedSame {
            return true
        }
        #endif
        if let literal = IPAddress(host) {
            return !literal.isBlocked
        }
        // Not a literal address - resolve it and check every address the name
        // maps to. A hostile or merely misconfigured DNS answer can legally
        // include more than one, and only one of them needs to be private for
        // the request to reach somewhere it should not.
        let addresses = resolvedAddresses(for: host)
        guard !addresses.isEmpty else {
            // Could not resolve at all: refuse rather than let the request
            // perform a resolution this check never got to see.
            return false
        }
        return addresses.allSatisfy { !$0.isBlocked }
    }

    /// Resolves `host` to every address it maps to, via the same resolver
    /// `URLSession` itself would use, so this check sees what the request
    /// would actually connect to rather than a separate, possibly stale,
    /// answer.
    private static func resolvedAddresses(for host: String) -> [IPAddress] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                  &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if ok == 0, let ip = IPAddress(String(cString: buffer)) {
                addresses.append(ip)
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    /// Pulls the best title out of a page's markup.
    ///
    /// `og:title` first: it is what the author chose for the link to be called
    /// elsewhere, so it is usually cleaner than `<title>`, which tends to carry
    /// the site name and a notification count.
    static func parseTitle(from html: String) -> String? {
        for pattern in [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#,
            #"<meta[^>]+name=["']twitter:title["'][^>]+content=["']([^"']+)["']"#,
            #"<title[^>]*>([\s\S]*?)</title>"#
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { continue }

            let title = clean(String(html[range]))
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Turns raw markup text into something worth showing in a row.
    private static func clean(_ raw: String) -> String {
        var text = raw

        // The handful of entities that actually turn up in titles.
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&nbsp;", " "), ("&mdash;", "-"), ("&ndash;", "-")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities, which no fixed table can cover.
        if let regex = try? NSRegularExpression(pattern: #"&#(\d{2,5});"#) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: text),
                      let digits = Range(match.range(at: 1), in: text),
                      let code = UInt32(text[digits]), let scalar = Unicode.Scalar(code) else { continue }
                text.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }

        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A title long enough to fill the row is no more use than no title.
        let limit = 120
        if text.count > limit {
            text = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}

/// Refuses a redirect that would take the request somewhere `hostIsSafe`
/// would have refused as the original target, and caps the chain at
/// `maxRedirects` hops regardless. Returning `nil` from this delegate method
/// tells `URLSession` to treat the redirect response itself as the final
/// answer rather than follow it - it does not throw, so the guard above is
/// what actually stops a private-range hop from ever being requested.
private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
    private var hopCount = 0

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        hopCount += 1
        guard hopCount <= LinkMetadata.maxRedirects,
              let host = request.url?.host, LinkMetadata.hostIsSafe(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// A parsed IPv4 or IPv6 address, kept as its raw bytes in network order so
/// the range checks below read as the ranges they are (RFC 1918, RFC 3927,
/// RFC 4193 and friends) rather than as string matching on `host`, which a
/// differently-formatted literal (leading zeros, a compressed IPv6 form, an
/// IPv4-mapped IPv6 address) could slip past.
private struct IPAddress {
    let isIPv4: Bool
    let bytes: [UInt8]

    init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            isIPv4 = true
            bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            isIPv4 = false
            bytes = withUnsafeBytes(of: v6) { Array($0) }
            return
        }
        return nil
    }

    var isBlocked: Bool {
        isIPv4 ? ipv4IsBlocked(bytes) : ipv6IsBlocked(bytes)
    }
}

/// `octets` is 4 bytes in network order (`octets[0]` is the first number a
/// person writes, e.g. `127` in `127.0.0.1`).
private func ipv4IsBlocked(_ octets: [UInt8]) -> Bool {
    let a = octets[0], b = octets[1]
    if a == 0 { return true }                          // 0.0.0.0/8 - unspecified/"this network"
    if a == 127 { return true }                        // 127.0.0.0/8 - loopback
    if a == 10 { return true }                          // 10.0.0.0/8 - private
    if a == 169, b == 254 { return true }               // 169.254.0.0/16 - link-local
    if a == 172, (16...31).contains(b) { return true }  // 172.16.0.0/12 - private
    if a == 192, b == 168 { return true }               // 192.168.0.0/16 - private
    if a >= 224 { return true }                         // 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
    return false
}

/// `bytes` is 16 bytes in network order.
private func ipv6IsBlocked(_ bytes: [UInt8]) -> Bool {
    if bytes.allSatisfy({ $0 == 0 }) { return true }                 // :: - unspecified
    if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // ::1 - loopback
    if (bytes[0] & 0xfe) == 0xfc { return true }                     // fc00::/7 - unique local
    if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }   // fe80::/10 - link-local
    if bytes[0] == 0xff { return true }                              // ff00::/8 - multicast
    // ::ffff:0:0/96 - an IPv4 address wearing an IPv6 wrapper. Re-check the
    // embedded IPv4 bytes, or a blocked v4 address slips through in this
    // shape alone.
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
        return ipv4IsBlocked(Array(bytes[12..<16]))
    }
    return false
}
