//
//  MirrorCalApp.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import SwiftUI

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

/// AppDelegate handles Menu Bar setup and application lifecycle.
/// We use AppDelegate because Menu Bar (NSStatusItem) requires AppKit integration.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    
    /// Menu bar manager responsible for the status item
    private var menuBarManager: MenuBarManager?
    
    /// Permissions manager for Calendar access
    private let permissionsManager = PermissionsManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Menu Bar
        menuBarManager = MenuBarManager()
        
        // Request calendar permissions on launch
        Task {
            await requestCalendarAccessIfNeeded()
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
            } else {
                print("[MirrorCal] Calendar access denied")
            }
        case .fullAccess:
            print("[MirrorCal] Calendar access already granted")
        case .writeOnly:
            print("[MirrorCal] Write-only access - requesting full access")
            _ = await permissionsManager.requestFullAccess()
        case .denied, .restricted:
            print("[MirrorCal] Calendar access denied or restricted - user must enable in System Settings")
        @unknown default:
            print("[MirrorCal] Unknown authorization status")
        }
    }
}
