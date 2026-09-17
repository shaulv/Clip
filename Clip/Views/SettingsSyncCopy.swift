import SwiftUI

/// SyncPane's explanatory/data-summary copy (T4-M3 split of
/// SettingsSyncPane.swift): the What syncs sub-page, the Danger zone
/// sub-page, and the settings-cadence rows they both draw from. Pure
/// extraction: no behaviour or string changes, only the file boundary
/// moved (design-taste rule 12).
extension SyncPane {

    // MARK: - Sub-page: What syncs

    @ViewBuilder
    var whatSyncsSections: some View {
        Group {
            Group {
                switch sync.connection {
                case .google:
                    ExplainedSection("What syncs", note: """
                        Clips, prompts, notes, skills, versions, tabs, themes, \
                        shortcuts and preferences.

                        Images, videos and files stay on this Mac, and so do \
                        your AI API keys.
                        """) {
                        LabeledContent("Items on this Mac", value: "\(store.items.count)")
                        if let space = sync.space {
                            LabeledContent("Items in the account", value: "\(space.items)")
                            LabeledContent("Syncing between", value: space.deviceSummary)
                        }
                        settingsCadenceRows
                    }
                    devicesSection
                case .token:
                    ExplainedSection("What syncs", note: """
                        Clips, prompts, notes, skills, versions, tabs, themes, \
                        shortcuts and preferences. No limit on how much a \
                        token holds.

                        Images, videos and files stay on this Mac, and so do \
                        your AI API keys.
                        """) {
                        LabeledContent("Items on this Mac", value: "\(store.items.count)")
                        settingsCadenceRows
                    }
                    if sync.space != nil {
                        ExplainedSection("When data arrives", note: """
                            This is the direction your data flows, and it applies to every \
                            sync, not only the first.
                            """) {
                            Toggle("Combine this Mac's items with the token's", isOn: Binding(
                                get: { sync.mergeOnSync },
                                set: { sync.mergeOnSync = $0 }
                            ))
                            Text(sync.mergeOnSync ? Self.mergeWarning : Self.replaceWarning)
                                .font(.caption)
                                .foregroundStyle(sync.mergeOnSync ? Color.secondary : Color.orange)
                        }
                    }
                case .none:
                    ExplainedSection("What syncs", note: """
                        Connect with Google or a sync token from the Sync tab to see \
                        this Mac's own sync details here.
                        """) {
                        Text("Not connected.").font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                }
            }
        }
    }

    // MARK: - Sub-page: Danger zone

    @ViewBuilder
    var dangerSections: some View {
        Group {
            Group {
                switch sync.connection {
                case .google:
                    ExplainedSection("Delete account", note: """
                        Deletes your account on \(OfficialService.displayName) and everything \
                        it holds, for every Mac signed in to it. Nothing on this Mac is deleted.
                        """) {
                        Button("Delete Account…", role: .destructive) { confirmingDelete = true }
                            .disabled(busy)
                        if let deleteResult {
                            Text(deleteResult).font(.caption).foregroundStyle(SettingsPalette.note)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .token:
                    ExplainedSection("Disconnect") {
                        Button("Disconnect This Mac…") { confirmingDisconnect = true }
                        Text("""
                            Clears the connection and stops syncing. Everything already \
                            here stays, and so does the saved token. It is not removed \
                            by disconnecting. Your other Macs keep using it.
                            """)
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                    ExplainedSection("Forget token") {
                        Button("Forget Token on This Mac…", role: .destructive) {
                            confirmingForgetToken = true
                        }
                        Text("""
                            Removes the saved token from this Mac's Keychain. A separate, \
                            confirmed step. Disconnecting alone never does this.
                            """)
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                case .none:
                    ExplainedSection("Danger zone",
                                      note: "Nothing to disconnect. This Mac is not connected.") {
                        Text("Connect with Google or a sync token from the Sync tab to see "
                             + "disconnect options here.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                }
            }
        }
    }

    /// The custom interval, said in whichever unit reads naturally.
    ///
    /// "Every 1440 minutes" is a number people have to divide; "every 24 hours"
    /// is one they can picture.
    var customIntervalLabel: String {
        let minutes = SettingsSyncCadence.customMinutes
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return "Every \(days) day\(days == 1 ? "" : "s")"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "Every \(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "Every \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// How often settings go out - rows, not a section of their own.
    ///
    /// Shared by both connected states rather than copied into each: how often
    /// settings are sent has nothing to do with how the connection was made,
    /// and two copies would answer the same question differently within a
    /// release or two.
    ///
    /// It was its own "Settings and themes" card, which read as a second kind
    /// of sync when it is the same sync with a slower clock (user, 06/09:
    /// "the settings sync is a part of the general sync and no need to
    /// separate it ... the user will select the sync loop timing").
    @ViewBuilder
    var settingsCadenceRows: some View {
        Group {
            Text("""
                Preferences, themes, tabs and shortcuts go out on a timer \
                rather than instantly, so dragging a color slider does not \
                flood your other Macs.
                """)
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Send settings", selection: Binding(
                get: { settingsSync.cadence },
                set: { settingsSync.cadence = $0 }
            )) {
                ForEach(SettingsSyncCadence.allCases) { Text($0.title).tag($0) }
            }
            .settingsFieldHover(cornerRadius: 6)
            if settingsSync.cadence == .custom {
                Stepper(value: Binding(
                    get: { SettingsSyncCadence.customMinutes },
                    set: { minutes in
                        SettingsSyncCadence.customMinutes = minutes
                        // The timer is built from the interval, so changing the
                        // number has to rebuild it. Without this the new value
                        // is stored and the old period keeps firing.
                        settingsSync.restartForCustomInterval()
                    }
                ), in: 1...10_080, step: 5) {
                    Text(customIntervalLabel)
                }
            }

            Text(settingsSync.cadence.note)
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)

            if let ceiling = settingsSync.cadence.dailyCeiling {
                Text("""
                    At most \(ceiling) update\(ceiling == 1 ? "" : "s") a day from this \
                    Mac, and only when something actually changed.
                    """)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pushed = settingsSync.lastPushedAt {
                LabeledContent("Last sent",
                               value: pushed.formatted(date: .omitted, time: .shortened))
            }
            HStack {
                Button("Send Settings Now") { Task { await settingsSync.pushNow() } }
                Spacer()
            }
            Text("""
                Your API keys are never included. They stay in the macOS Keychain \
                on this Mac, and so does the sync token itself.
                """)
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
