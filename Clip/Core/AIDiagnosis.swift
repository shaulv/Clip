import Foundation

/// Turns whatever went wrong into a sentence that says what to do next.
///
/// Every AI failure used to reach the user as `error.localizedDescription`,
/// which for an HTTP error is the provider's own words: "This model's maximum
/// context length is 8192 tokens, however you requested 9433 tokens". That is
/// accurate, addressed to a developer, and gives the person holding the app no
/// idea that the fix is to select less text. The classification here is
/// deliberately coarse - five things actually go wrong - and each one names the
/// action that resolves it.
enum AIDiagnosis {

    struct Reading {
        /// One line, plain, addressed to the person.
        let message: String
        /// What to do about it, when there is something to do.
        let remedy: String?
        /// True when the input itself is the problem, so the UI can point at it.
        let isAboutLength: Bool
    }

    static func read(_ error: Error, inputLength: Int? = nil) -> Reading {
        if let ai = error as? AIError { return read(ai, inputLength: inputLength) }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return Reading(
                    message: "The model did not answer in time.",
                    remedy: "Try again, or switch to a faster model in Settings > AI.",
                    isAboutLength: false)
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return Reading(message: "This Mac is offline.",
                               remedy: "Reconnect and try again.", isAboutLength: false)
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return Reading(
                    message: "Could not reach the provider's address.",
                    remedy: "Check the endpoint under Settings > AI > Connections.",
                    isAboutLength: false)
            default: break
            }
        }
        return Reading(message: error.localizedDescription, remedy: nil, isAboutLength: false)
    }

    private static func read(_ error: AIError, inputLength: Int?) -> Reading {
        switch error {
        case .notConfigured:
            return Reading(message: "No AI connection is active.",
                           remedy: "Add one under Settings > AI.", isAboutLength: false)
        case .missingKey:
            return Reading(message: "This connection has no API key saved.",
                           remedy: "Open it under Settings > AI and paste the key.",
                           isAboutLength: false)
        case .keyUnreadable:
            // The terminal sentence: self-repair already ran and could not
            // fix it, which is the only way a person reads this at all.
            // Reuses `KeychainStore.repairAccess`'s own wording for a failed
            // attempt, so the app never says two different things about the
            // one problem.
            return Reading(
                message: "Clip could not restore the saved key.",
                remedy: "Paste it again in Settings > AI, or right-click the menu bar "
                      + "icon and choose Repair AI Key Access.",
                isAboutLength: false)
        case .keyMissing:
            return Reading(
                message: "The saved key for this connection is gone.",
                remedy: "Open it under Settings > AI and paste the key again.",
                isAboutLength: false)
        case .cancelled:
            return Reading(message: "Canceled.", remedy: nil, isAboutLength: false)
        case .malformed(let detail):
            return Reading(message: "The model's reply could not be used.",
                           remedy: detail.isEmpty ? nil : detail, isAboutLength: false)
        case .http(let code, let body):
            return http(code, body, inputLength: inputLength)
        }
    }

    /// The HTTP cases worth telling apart, by what the user has to do.
    private static func http(_ code: Int, _ body: String, inputLength: Int?) -> Reading {
        let lower = body.lowercased()

        // Length is the one every provider phrases differently and the one the
        // user can always fix themselves, so it is matched on meaning rather
        // than on any single provider's wording.
        let lengthWords = ["context length", "context_length", "maximum context",
                           "too many tokens", "too long", "reduce the length",
                           "max_tokens", "token limit", "input is too large",
                           "request too large", "exceeds the maximum"]
        if lengthWords.contains(where: lower.contains) || code == 413 {
            let size = inputLength.map { " It comes to about \(estimatedTokens(ofLength: $0)) tokens (roughly \($0) characters)." } ?? ""
            return Reading(
                message: "That's more text than this model can read at once.\(size)",
                remedy: """
                    Select a shorter passage, or choose a model with a larger context \
                    window under Settings > AI.
                    """,
                isAboutLength: true)
        }
        switch code {
        case 401, 403:
            return Reading(message: "The provider rejected the API key.",
                           remedy: "Check or replace it under Settings > AI > Connections.",
                           isAboutLength: false)
        case 404:
            return Reading(
                message: "The provider does not have that model any more.",
                remedy: "Open the connection and press Refresh to list what it does have.",
                isAboutLength: false)
        case 410:
            // Documented at `ModelCatalog.swift` as the code a provider uses
            // when it retires a model rather than simply not recognising the
            // id (404) - this account's own default model returned exactly
            // this the day it was tried.
            return Reading(
                message: "The provider retired this model.",
                remedy: "Pick another in Settings > AI.",
                isAboutLength: false)
        case 429:
            return Reading(message: "The provider is rate limiting this key.",
                           remedy: "Wait a moment and try again, or use your backup connection.",
                           isAboutLength: false)
        case 500...599:
            return Reading(message: "The provider is having trouble (HTTP \(code)).",
                           remedy: "Not something this Mac can fix. Try again shortly.",
                           isAboutLength: false)
        default:
            return Reading(message: "The provider refused the request (HTTP \(code)).",
                           remedy: body.isEmpty ? nil : String(body.prefix(200)),
                           isAboutLength: false)
        }
    }

    /// A rough token count, good enough to warn with and honest about it.
    ///
    /// Real tokenisation needs the model's own vocabulary, which Clip does not
    /// have and should not download. Four characters per token is the figure
    /// every provider quotes for English prose; it is wrong for code and wrong
    /// for Hebrew, which is why the UI labels it an estimate rather than a count.
    static func estimatedTokens(ofLength characters: Int) -> Int {
        max(1, Int((Double(characters) / 4.0).rounded()))
    }

    static func estimatedTokens(in text: String) -> Int {
        estimatedTokens(ofLength: text.count)
    }
}
