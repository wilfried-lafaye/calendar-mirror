//
//  RefreshCalendarsIntent.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import AppIntents

/// Exposes a manual "Refresh Calendars" action to the Shortcuts app, Siri, and
/// Automations — the same `SyncEngine.shared` sync used by the menu bar's
/// "Sync Now" item (⌘R) and the Settings sync button.
struct RefreshCalendarsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Calendars"
    static let description = IntentDescription("Mirrors your source calendars into the destination calendar right now.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let syncResult = try await withCheckedThrowingContinuation { continuation in
            SyncEngine.shared.performSync { continuation.resume(with: $0) }
        }
        return .result(value: syncResult.description)
    }
}

/// Registers `RefreshCalendarsIntent` with the Shortcuts app so it's discoverable
/// (and usable in Automations) without the user needing to open MirrorCal first.
struct MirrorCalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshCalendarsIntent(),
            phrases: [
                "Refresh calendars in \(.applicationName)",
                "Sync \(.applicationName)"
            ],
            shortTitle: "Refresh Calendars",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
