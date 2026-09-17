import SwiftUI

/// The single place every AI-dependent surface asks "should I show up".
///
/// AI features are Lego, per the user's own words: each block only appears
/// when the block under it - a working, validated connection - is there.
/// `AIService.isAvailable` is that one fact (a connection is present AND the
/// user has not switched AI off). This file exists so every surface that
/// depends on it says the SAME thing in the SAME words, instead of a dozen
/// call sites each writing their own sentence and drifting from each other
/// the next time one of them is edited.
@MainActor
enum AIGate {

    /// The one sentence shown wherever an AI surface is hidden or disabled.
    /// Every gated surface in the app uses this exact string - never a
    /// paraphrase - so a person sees one consistent instruction no matter
    /// which feature they reached for first.
    static let sentence = "Connect a model under Settings > AI"

    /// One AI-dependent surface, named so a probe can enumerate every one of
    /// them and check it actually reacts to `AIService.isAvailable`, rather
    /// than trusting that a grep for `isAvailable` found every call site.
    struct Surface {
        let name: String
        let isPresent: @MainActor () -> Bool
    }

    /// Every surface that has registered itself, in registration order.
    private(set) static var surfaces: [Surface] = []

    /// Called once per surface, from `registerSurfaces()` below. A second
    /// registration under the same name replaces the first rather than
    /// growing the list - `registerSurfaces()` is safe to call more than
    /// once (SwiftUI can re-run view code many times per session, and a
    /// test relaunch reuses the same process under `CLIP_HEADLESS`).
    static func register(_ name: String, isPresent: @escaping @MainActor () -> Bool) {
        surfaces.removeAll { $0.name == name }
        surfaces.append(Surface(name: name, isPresent: isPresent))
    }

    /// Registers every surface this app actually gates on `isAvailable`.
    ///
    /// Deliberately a flat list built once, at launch (`AppDelegate`), rather
    /// than each view registering itself from its own `body` - a view whose
    /// tab or sheet is not currently on screen never runs `body` at all, and
    /// a registry that only knows about *rendered* views would miss exactly
    /// the surfaces a "zero connections" probe most needs to see: the ones
    /// that are supposed to be absent right now.
    static func registerSurfaces() {
        register("Item detail - AI menu (improve, proofread, translate, "
                 + "summarise, explain, template, extract, rewrite, compose)") {
            AIService.shared.isAvailable
        }
        register("Action panel - running a paste action") {
            AIService.shared.isAvailable
        }
        register("Global shortcut - paste translated") {
            AIService.shared.isAvailable
        }
        register("Global shortcut - paste with an action") {
            AIService.shared.isAvailable
        }
        register("Settings > AI - Describe a theme") {
            AIService.shared.isAvailable
        }
    }

    #if CLIP_TESTING
    /// Test-facing: a probe reads every surface fresh each time rather than
    /// needing its own reset, since every closure re-evaluates live state -
    /// but a lane that wants a known-empty registry (to prove registration
    /// itself, not just presence) can start from here.
    static func resetForTesting() { surfaces.removeAll() }
    #endif
}

extension View {
    /// Hides this view unless a validated, switched-on AI connection is
    /// available.
    ///
    /// The default removes the control entirely rather than showing it
    /// disabled: most AI surfaces are buttons and menu entries that mean
    /// nothing to press with no model connected, and a live-looking but
    /// useless control invites exactly the click that finds out the hard
    /// way. `disabledWithSentence: true` keeps the control on screen,
    /// dimmed, with the shared sentence as its tooltip - for the rare place
    /// where hiding it entirely would read as the feature never existing.
    @ViewBuilder
    func requiresAI(disabledWithSentence: Bool = false) -> some View {
        if AIService.shared.isAvailable {
            self
        } else if disabledWithSentence {
            self.disabled(true).help(AIGate.sentence)
        } else {
            EmptyView()
        }
    }
}
