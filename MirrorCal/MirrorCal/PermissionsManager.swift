//
//  PermissionsManager.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import AppKit
import EventKit
import Foundation

/// Manages Calendar (EventKit) permissions for the application.
/// Handles checking current authorization status and requesting Full Access.
@MainActor
final class PermissionsManager {
    
    // MARK: - Properties
    
    /// Shared EventKit store instance
    /// This is the central access point for all calendar operations.
    let eventStore: EKEventStore
    
    // MARK: - Initialization
    
    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }
    
    // MARK: - Authorization Status
    
    /// Returns the current authorization status for calendar access.
    /// - Returns: The current `EKAuthorizationStatus` for events.
    func currentAuthorizationStatus() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }
    
    /// Checks if the app has full access to calendars.
    /// - Returns: `true` if full access is granted, `false` otherwise.
    var hasFullAccess: Bool {
        return currentAuthorizationStatus() == .fullAccess
    }
    
    /// Checks if permission has been determined (user has made a choice).
    /// - Returns: `true` if the user has made a permission decision.
    var isPermissionDetermined: Bool {
        return currentAuthorizationStatus() != .notDetermined
    }
    
    // MARK: - Request Access
    
    /// Requests Full Access to Calendar events.
    /// This is required for reading and writing calendar events.
    ///
    /// - Returns: `true` if access was granted, `false` otherwise.
    ///
    /// - Note: On macOS 14+, we use `requestFullAccessToEvents()`.
    ///         This requires the `NSCalendarsFullAccessUsageDescription` key in Info.plist.
    func requestFullAccess() async -> Bool {
        do {
            // requestFullAccessToEvents() is available on macOS 14.0+
            // For older versions, you would use requestAccess(to:) but we target macOS 14+
            let granted = try await eventStore.requestFullAccessToEvents()
            return granted
        } catch {
            print("[PermissionsManager] Error requesting calendar access: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Convenience
    
    /// Returns a human-readable description of the current authorization status.
    /// - Returns: A string describing the permission state.
    func authorizationStatusDescription() -> String {
        switch currentAuthorizationStatus() {
        case .notDetermined:
            return "Not Determined - Permission not yet requested"
        case .restricted:
            return "Restricted - Access restricted by system policy"
        case .denied:
            return "Denied - User denied access"
        case .fullAccess:
            return "Full Access - Read and write access granted"
        case .writeOnly:
            return "Write Only - Can write but not read events"
        @unknown default:
            return "Unknown status"
        }
    }
    
    /// Opens System Settings to the Privacy & Security > Calendars section.
    /// Useful when the user needs to manually grant permissions.
    @MainActor
    func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
