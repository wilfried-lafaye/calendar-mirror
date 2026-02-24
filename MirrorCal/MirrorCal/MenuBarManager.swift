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
        
        // Sync status (placeholder)
        let syncStatusItem = NSMenuItem(title: "Last sync: Never", action: nil, keyEquivalent: "")
        syncStatusItem.isEnabled = false
        menu?.addItem(syncStatusItem)
        
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
    
    // MARK: - Public Methods
    
    /// Updates the sync status displayed in the menu
    /// - Parameter date: The last sync date, or nil if never synced
    func updateSyncStatus(lastSync date: Date?) {
        guard let menu = menu else { return }
        
        // Find the status item (index 2 after header and separator)
        if menu.items.count > 2 {
            let statusItem = menu.items[2]
            if let date = date {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                let relativeTime = formatter.localizedString(for: date, relativeTo: Date())
                statusItem.title = "Last sync: \(relativeTime)"
            } else {
                statusItem.title = "Last sync: Never"
            }
        }
    }
}
