import Foundation
import Combine

/// The one place the app says something about itself.
///
/// Messages used to have no home: errors were drawn inside a row that was
/// later removed, and nothing at all told someone who had never connected a
/// model what connecting one would buy. Then a second problem appeared: the
/// row held ONE message, forgot it after twelve seconds, and was drawn only
/// inside the panel. A database that could not be opened at launch, or a
/// Keychain item that stopped being readable while the panel was shut, was
/// never seen by anyone.
///
/// So there are now three lifetimes, not one timer:
/// - `.transient` is news: a paste that failed, a drop that landed. Twelve
///   seconds, then gone.
/// - `.persistent` is a condition: sync cannot reach the server, a saved key
///   cannot be read. It stays until the code that raised it calls
///   `resolve(_:)`, can be dismissed with the X for this launch, and lights
///   the menu-bar badge so it is discoverable with the panel closed.
/// - `.integrity` is data at risk: the database would not open, a migration
///   failed, a reconcile refused to delete. Not dismissible, outranks
///   everything, lights the badge, and raises one alert per launch when no
///   panel is open to show it.
///
/// A notice may carry ONE action. The bar renders it as the capsule button
/// that used to be hard-wired to "Turn on AI".
@MainActor
final class NoticeCenter: ObservableObject {

    static let shared = NoticeCenter()

    enum Kind: String, Comparable {
        case invitation
        case transient
        case persistent
        case integrity

        /// Higher wins the single visible slot. News interrupts a standing
        /// condition for its twelve seconds, then the condition returns: a
        /// persistent notice that hid every "Added ..." and "Copied" line
        /// made the panel look broken while sync was merely offline. Data at
        /// risk still outranks everything.
        var rank: Int {
            switch self {
            case .invitation: return 0
            case .persistent: return 1
            case .transient: return 2
            case .integrity: return 3
            }
        }
        static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }

        /// A standing condition: lights the menu-bar badge and is listed first
        /// in the status menu. Rank is about the visible slot, this is about
        /// what persists, and since news outranks a condition the two differ.
        var isCondition: Bool { self == .persistent || self == .integrity }

        /// The old name, kept so call sites that only knew "failure" read
        /// naturally: a failure is a transient notice.
        static let failure = Kind.transient
    }

    /// Something the person can do about it, in one press.
    struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    struct Notice: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let message: String
        /// What to do about it. Optional, because some failures have no
        /// remedy worth printing and "try again" is not one.
        let remedy: String?
        let action: Action?
        /// A second thing the person can do, alongside `action`. Added for
        /// the Accessibility permission row (M8.6), which needs both "reset
        /// and ask again" and "open System Settings" in the one row rather
        /// than picking one and burying the other in the remedy sentence.
        /// Additive and defaulted to nil, so the two other constructors in
        /// this file and every existing call to `report(...)` keep compiling
        /// unchanged. `var`, not `let`: the synthesized memberwise
        /// initializer only turns a defaulted property into an overridable
        /// parameter for `var` (SE-0242) - as a `let` it compiled, but every
        /// call site passing `secondaryAction:` explicitly failed with
        /// "extra argument", because the initializer never gained that
        /// parameter at all.
        var secondaryAction: Action? = nil
        /// Stable key so the same condition reported twice replaces itself
        /// rather than stacking, and so `resolve` can find it.
        let key: String?
        let raisedAt: Date
        /// M22: whether the condition behind this notice still holds. Checked
        /// on panel open, after every action, and on a slow tick while any
        /// such notice is up; the moment it returns false the notice resolves
        /// itself, so a banner never outlives its purpose. nil = the owner
        /// resolves it explicitly, as before.
        var stillNeeded: (@MainActor () -> Bool)? = nil

        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }

        /// Compatibility for the one call site that asked "does this open
        /// the AI settings": true when the action is the AI-settings one.
        var opensAISettings: Bool { action?.title == NoticeCenter.turnOnAITitle }
    }

    /// The one notice the bar shows: the highest-ranked unresolved one, newest
    /// first within a rank.
    @Published private(set) var current: Notice?
    /// Everything unresolved, highest rank first. The Diagnostics window lists
    /// it; the bar shows how many more there are.
    @Published private(set) var pending: [Notice] = []
    /// Whether anything is up that should light the menu-bar badge.
    @Published private(set) var badgeVisible = false
    @Published private(set) var badgeMessage: String?

    /// Fired once when an `.integrity` notice is raised and the panel is not
    /// open, so `AppDelegate` can put up the one alert an agent app has.
    var onIntegrityWithoutPanel: ((Notice) -> Void)?
    private var integrityAlertShownThisLaunch = false

    private var expiries: [UUID: Timer] = [:]
    private var dismissedKeysThisLaunch: Set<String> = []

    private init() {}

    // MARK: - Reporting

    /// The general entry point. `key` makes a condition idempotent: reporting
    /// the same key again replaces the earlier notice in place.
    @discardableResult
    func report(_ message: String, remedy: String? = nil, kind: Kind = .transient,
                key: String? = nil, action: Action? = nil, secondaryAction: Action? = nil,
                stillNeeded: (@MainActor () -> Bool)? = nil) -> Notice {
        if let key {
            pending.removeAll { $0.key == key }
            // A dismissed persistent condition stays quiet for this launch,
            // unless it has been upgraded to integrity, which cannot be hushed.
            if kind == .persistent, dismissedKeysThisLaunch.contains(key) {
                let hushed = Notice(id: UUID(), kind: kind, message: message, remedy: remedy,
                                    action: action, secondaryAction: secondaryAction, key: key, raisedAt: Date())
                refreshBadge(including: hushed)
                return hushed
            }
        }
        var notice = Notice(id: UUID(), kind: kind, message: message, remedy: remedy,
                            action: action, secondaryAction: secondaryAction, key: key, raisedAt: Date())
        notice.stillNeeded = stillNeeded
        pending.append(notice)
        armRecheckIfNeeded()
        if kind == .transient {
            let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.remove(notice.id) }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiries[notice.id] = timer
        }
        recompute()
        Database.shared.log("notice", "\(kind.rawValue): \(message)")
        if kind == .integrity, !integrityAlertShownThisLaunch, !PanelController.shared.isOpen {
            integrityAlertShownThisLaunch = true
            onIntegrityWithoutPanel?(notice)
        }
        return notice
    }

    /// Reads an error the way the rest of the app does, so the wording is the
    /// same wherever a provider fails.
    func report(_ error: Error) {
        let reading = AIDiagnosis.read(error)
        report(reading.message, remedy: reading.remedy)
    }

    /// A storage failure, read into a sentence by `StorageDiagnosis`.
    @discardableResult
    func report(_ failure: StorageFailure, action: Action? = nil) -> Notice {
        let reading = StorageDiagnosis.read(failure)
        return report(reading.message, remedy: reading.remedy, kind: reading.kind,
                      key: reading.key, action: action ?? reading.action)
    }

    // MARK: - Self-resolving conditions (M22)

    private var recheckTimer: Timer?
    /// Test-visible: how many ticks have run and whether a timer is armed.
    private(set) var recheckTicks = 0
    var recheckArmed: Bool { recheckTimer != nil }

    /// Drops every pending notice whose `stillNeeded` says the condition is
    /// gone. Cheap: predicates are simple reads (a permission, a flag, a
    /// set membership). Called on panel open, after a notice action runs,
    /// and every 2 s while such a notice is pending.
    func recheck() {
        let gone = pending.filter { n in
            guard let still = n.stillNeeded else { return false }
            return !still()
        }
        guard !gone.isEmpty else { armRecheckIfNeeded(); return }
        for n in gone {
            expiries[n.id]?.invalidate(); expiries[n.id] = nil
            Database.shared.log("notice", "resolved itself: \(n.message)")
        }
        let ids = Set(gone.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        recompute()
        armRecheckIfNeeded()
    }

    private func armRecheckIfNeeded() {
        let needsTick = pending.contains { $0.stillNeeded != nil }
        if needsTick, recheckTimer == nil {
            // Scheduled on the main run loop's default mode (like the QA
            // bridge's own poll) and also common modes, so it fires while a
            // menu or modal has the loop.
            let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recheckTicks += 1
                    self?.recheck()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            recheckTimer = t
        } else if !needsTick, let t = recheckTimer {
            t.invalidate(); recheckTimer = nil
        }
    }

    /// The condition behind `key` is over. Nothing happens if it was never up.
    func resolve(_ key: String) {
        let before = pending.count
        pending.removeAll { $0.key == key }
        if pending.count != before { recompute() }
    }

    // MARK: - The invitation

    // `nonisolated`: `Notice.opensAISettings` reads this from a non-isolated
    // context (the struct itself carries no actor), and under Swift 6 a
    // main-actor-isolated `static let` cannot be referenced there even though
    // the value is an immutable, Sendable `String`. Opting the constant itself
    // out of isolation is correct, not a workaround - nothing about "Turn on
    // AI" depends on the main actor.
    nonisolated static let turnOnAITitle = "Turn on AI"

    /// Whether the "turn AI on" invitation should be up.
    var shouldInvite: Bool {
        guard !PreferencesModel.shared.aiPromoDismissed else { return false }
        return !AIService.shared.isAvailable
    }

    /// Shown once per off-period, not once per install. Only the X is
    /// permanent; turning AI on takes the row down and arms it again.
    private var shownForThisOffPeriod = false

    func refreshInvitation() {
        if AIService.shared.isAvailable {
            pending.removeAll { $0.kind == .invitation }
            shownForThisOffPeriod = false
            recompute()
            return
        }
        guard !pending.contains(where: { $0.kind == .invitation }),
              !shownForThisOffPeriod, shouldInvite else { return }
        shownForThisOffPeriod = true
        pending.append(Notice(id: UUID(), kind: .invitation, message: Self.invitation, remedy: nil,
                              action: Action(title: Self.turnOnAITitle) {
                                  SettingsWindowController.shared.show(tab: .ai)
                              },
                              key: "invitation", raisedAt: Date()))
        recompute()
    }

    #if CLIP_TESTING
    /// Arms the once-per-off-period flag, standing in for a fresh install.
    func armInvitationForTesting() { shownForThisOffPeriod = false }
    /// Lets a probe re-arm the one-per-launch integrity alert.
    func resetIntegrityAlertForTesting() { integrityAlertShownThisLaunch = false }
    /// Fires every transient expiry now, standing in for twelve seconds.
    func expireTransientsForTesting() {
        for n in pending where n.kind == .transient { remove(n.id) }
    }
    #endif

    static let invitation = "Connect a model and one keystroke translates, rewrites or fixes what you paste, in the app you are typing in."

    // MARK: - Dismissal

    /// The X on the visible notice. For the invitation this is permanent, in
    /// those words, because an invitation that comes back is an
    /// advertisement. A persistent condition stays quiet for this launch. An
    /// integrity notice cannot be dismissed at all; the X is not drawn for it.
    func dismiss() {
        guard let notice = current else { return }
        dismiss(notice.id)
    }

    /// The same rule, applied to a specific notice rather than only the one
    /// currently showing. The Diagnostics window (M1.4) lists every pending
    /// notice at once, each with its own Dismiss, and that has to reach a
    /// notice sitting lower than `current` without waiting for it to surface.
    func dismiss(_ id: UUID) {
        guard let notice = pending.first(where: { $0.id == id }) else { return }
        switch notice.kind {
        case .invitation:
            PreferencesModel.shared.aiPromoDismissed = true
            remove(notice.id)
        case .transient:
            remove(notice.id)
        case .persistent:
            if let key = notice.key { dismissedKeysThisLaunch.insert(key) }
            remove(notice.id)
        case .integrity:
            break
        }
    }

    /// Everything goes, including the timers. Test and reset use only; a
    /// condition that is still true will be re-reported by its owner.
    func clear() {
        for t in expiries.values { t.invalidate() }
        expiries.removeAll()
        pending.removeAll()
        recompute()
    }

    // MARK: - Internals

    private func remove(_ id: UUID) {
        expiries[id]?.invalidate()
        expiries[id] = nil
        pending.removeAll { $0.id == id }
        recompute()
    }

    private func recompute() {
        pending.sort { a, b in
            if a.kind != b.kind { return a.kind > b.kind }
            return a.raisedAt > b.raisedAt
        }
        current = pending.first
        refreshBadge(including: nil)
    }

    private func refreshBadge(including hushed: Notice?) {
        let lit = pending.first { $0.kind.isCondition } ?? hushed
        badgeVisible = lit != nil
        badgeMessage = lit?.message
    }
}
