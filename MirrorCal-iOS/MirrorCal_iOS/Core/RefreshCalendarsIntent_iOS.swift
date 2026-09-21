//
//  RefreshCalendarsIntent_iOS.swift
//  MirrorCal-iOS
//

import AppIntents
import Foundation

/// Exposes a manual "Refresh Calendars" action to the Shortcuts app, Siri, and
/// Automations — the same sync used by the "Sync Now" button on the main screen.
struct RefreshCalendarsIntent_iOS: AppIntent {
    static let title: LocalizedStringResource = "Refresh Calendars"
    static let description = IntentDescription("Mirrors your source calendars into the destination calendar right now.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let sourceIDs = Set(UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs") ?? [])
        let engine = SyncEngine_iOS()
        engine.setSourceCalendars(sourceIDs)

        let syncResult = try await withCheckedThrowingContinuation { continuation in
            engine.performSync { continuation.resume(with: $0) }
        }

        UserDefaults.standard.set(Date(), forKey: "LastSyncTime")
        return .result(value: syncResult.description)
    }
}

/// Registers `RefreshCalendarsIntent_iOS` with the Shortcuts app so it's discoverable
/// (and usable in Automations) without the user needing to open MirrorCal first.
struct MirrorCalShortcuts_iOS: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshCalendarsIntent_iOS(),
            phrases: [
                "Refresh calendars in \(.applicationName)",
                "Sync \(.applicationName)"
            ],
            shortTitle: "Refresh Calendars",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
