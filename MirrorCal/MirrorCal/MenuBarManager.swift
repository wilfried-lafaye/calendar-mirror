//
//  MenuBarManager.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import AppKit
import SwiftUI

/// Manages the Menu Bar status item and its menu.
/// This class handles all Menu Bar UI interactions.
@MainActor
final class MenuBarManager {
    
    // MARK: - Properties
    
    /// The status item displayed in the Menu Bar
    private var statusItem: NSStatusItem?
    
    /// The menu shown when clicking the status item
    private var menu: NSMenu?
    
    /// The Settings window (kept alive while open)
    private var settingsWindow: NSWindow?

    /// The "Sync Now" menu item (kept around to toggle its title/enabled state while syncing)
    private var syncNowItem: NSMenuItem?

    /// The "Last sync: ..." menu item (kept around so `updateSyncStatus` doesn't rely on a fixed index)
    private var lastSyncItem: NSMenuItem?

    /// Called when the user picks "Sync Now" (or its ⌘R key equivalent) from the menu.
    var onSyncNow: (() -> Void)?

    // MARK: - Initialization

    init() {
        setupStatusItem()
    }
    
    // MARK: - Setup
    
    /// Creates and configures the status bar item
    private func setupStatusItem() {
        // Create status item with variable length
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Configure the button
        if let button = statusItem?.button {
            // Use SF Symbol for the calendar icon
            button.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "MirrorCal")
            button.image?.isTemplate = true // Adapts to light/dark mode
            button.toolTip = "MirrorCal"
        }
        
        // Create and attach the menu
        setupMenu()
    }
    
    /// Creates and configures the dropdown menu
    private func setupMenu() {
        menu = NSMenu()
        menu?.autoenablesItems = false
        
        // Header item (disabled, just for display)
        let headerItem = NSMenuItem(title: "MirrorCal", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu?.addItem(headerItem)
        
        menu?.addItem(NSMenuItem.separator())

        // Sync Now — manual refresh, with a ⌘R keyboard shortcut
        let syncNowItem = NSMenuItem(
            title: "Sync Now",
            action: #selector(syncNow),
            keyEquivalent: "r"
        )
        syncNowItem.target = self
        menu?.addItem(syncNowItem)
        self.syncNowItem = syncNowItem

        // Sync status (placeholder)
        let lastSyncItem = NSMenuItem(title: "Last sync: Never", action: nil, keyEquivalent: "")
        lastSyncItem.isEnabled = false
        menu?.addItem(lastSyncItem)
        self.lastSyncItem = lastSyncItem

        menu?.addItem(NSMenuItem.separator())
        
        // Settings menu item
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu?.addItem(settingsItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quit menu item
        let quitItem = NSMenuItem(
            title: "Quit MirrorCal",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu?.addItem(quitItem)
        
        // Attach menu to status item
        self.statusItem?.menu = menu
    }
    
    // MARK: - Actions
    
    /// Opens the Settings window using NSWindow with NSHostingController
    @objc private func openSettings() {
        // If window already exists and is visible, just bring it to front
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create the SwiftUI view
        let settingsView = SettingsView()
        
        // Create NSHostingController to bridge SwiftUI to AppKit
        let hostingController = NSHostingController(rootView: settingsView)
        
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "MirrorCal Settings"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        
        // Keep reference to prevent deallocation
        settingsWindow = window
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Terminates the application
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Triggers a manual sync (menu click or the ⌘R key equivalent)
    @objc private func syncNow() {
        onSyncNow?()
    }

    // MARK: - Public Methods

    /// Updates the sync status displayed in the menu
    /// - Parameter date: The last sync date, or nil if never synced
    func updateSyncStatus(lastSync date: Date?) {
        guard let lastSyncItem = lastSyncItem else { return }

        if let date = date {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relativeTime = formatter.localizedString(for: date, relativeTo: Date())
            lastSyncItem.title = "Last sync: \(relativeTime)"
        } else {
            lastSyncItem.title = "Last sync: Never"
        }
    }

    /// Reflects whether a sync is currently running by disabling "Sync Now" (which also
    /// suppresses its ⌘R key equivalent) and swapping its title.
    /// - Parameter inProgress: Whether a sync is currently running
    func setSyncInProgress(_ inProgress: Bool) {
        guard let syncNowItem = syncNowItem else { return }
        syncNowItem.title = inProgress ? "Syncing..." : "Sync Now"
        syncNowItem.isEnabled = !inProgress
    }
}
