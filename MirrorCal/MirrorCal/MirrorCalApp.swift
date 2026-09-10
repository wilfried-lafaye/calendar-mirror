//
//  MirrorCalApp.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import SwiftUI
import EventKit

/// Main application entry point for MirrorCal.
/// Configured as an LSUIElement (Menu Bar only, no Dock icon).
@main
struct MirrorCalApp: App {

    // MARK: - App Delegates

    /// AppDelegate for handling NSApplication-level events and Menu Bar setup
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Empty Settings scene - we use the Menu Bar exclusively
        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

/// AppDelegate handles Menu Bar setup, application lifecycle, and — since MirrorCal is a
/// menu bar agent that stays alive for the whole session — owns the persistent automatic
/// sync trigger: it listens to `EKEventStoreChangedNotification` for as long as the app
/// runs, so a change in any source calendar is mirrored within seconds, with no manual
/// "Sync Now" click and no date range to pick.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Menu bar manager responsible for the status item
    private var menuBarManager: MenuBarManager?

    /// Permissions manager for Calendar access
    private let permissionsManager = PermissionsManager()

    /// Token for the persistent `.EKEventStoreChanged` observer.
    private var eventStoreObserver: NSObjectProtocol?

    /// Coalesces bursts of `.EKEventStoreChanged` notifications (EventKit can fire several
    /// for a single user edit) into a single sync a couple of seconds later.
    private var pendingSyncWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Menu Bar
        menuBarManager = MenuBarManager()

        // Request calendar permissions on launch
        Task {
            await requestCalendarAccessIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
        }
    }

    /// Checks and requests calendar access if not already granted
    private func requestCalendarAccessIfNeeded() async {
        let status = permissionsManager.currentAuthorizationStatus()

        switch status {
        case .notDetermined:
            let granted = await permissionsManager.requestFullAccess()
            if granted {
                print("[MirrorCal] Calendar access granted")
                startAutoSync()
            } else {
                print("[MirrorCal] Calendar access denied")
            }
        case .fullAccess:
            print("[MirrorCal] Calendar access already granted")
            startAutoSync()
        case .writeOnly:
            print("[MirrorCal] Write-only access - requesting full access")
            if await permissionsManager.requestFullAccess() {
                startAutoSync()
            }
        case .denied, .restricted:
            print("[MirrorCal] Calendar access denied or restricted - user must enable in System Settings")
        @unknown default:
            print("[MirrorCal] Unknown authorization status")
        }
    }

    // MARK: - Automatic Sync

    /// Starts listening for calendar changes and runs an immediate catch-up sync.
    /// Safe to call more than once (e.g. after a late permission grant) — only the
    /// first call registers the observer.
    private func startAutoSync() {
        guard eventStoreObserver == nil else { return }

        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDebouncedSync()
            }
        }

        // Catch up on anything that changed while the app wasn't running.
        runSync(reason: "launch")
    }

    /// Cancels any pending debounced sync and schedules a new one a couple of seconds out,
    /// so a burst of EventKit notifications for one edit results in a single sync.
    private func scheduleDebouncedSync() {
        guard SyncEngine.shared.shouldRespondToCalendarChange() else { return }

        pendingSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runSync(reason: "calendar change")
        }
        pendingSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func runSync(reason: String) {
        SyncEngine.shared.performSync { [weak self] result in
            switch result {
            case .success(let syncResult):
                self?.menuBarManager?.updateSyncStatus(lastSync: Date())
                print("[MirrorCal] Auto-sync (\(reason)): \(syncResult.description)")
            case .failure(let error):
                print("[MirrorCal] Auto-sync (\(reason)) failed: \(error.localizedDescription)")
            }
        }
    }
}
