//
//  CalendarSelectionViewModel.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import EventKit
import SwiftUI
import Combine

/// ViewModel for managing calendar selection in Settings.
/// Fetches calendars from EventKit, groups by source, and persists selection to UserDefaults.
@MainActor
final class CalendarSelectionViewModel: ObservableObject {
    
    // MARK: - Constants
    
    /// UserDefaults key for storing selected calendar IDs
    private static let selectedCalendarsKey = "selectedSourceCalendarIDs"
    
    /// UserDefaults key for storing the destination calendar ID
    private static let destinationCalendarKey = "destinationCalendarID"
    
    /// Calendars to exclude from SOURCE selection (our mirror + system calendars)
    private static let excludedCalendarTitles: Set<String> = [
        "MirrorCal",
        "Birthdays",
        "Siri Suggestions"
    ]
    
    // MARK: - Published Properties
    
    /// Grouped calendars by source for display (source calendars)
    @Published var calendarGroups: [CalendarGroup] = []
    
    /// All writable calendars for destination picker
    @Published var allWritableCalendars: [EKCalendar] = []
    
    /// Set of selected calendar identifiers (sources)
    @Published var selectedCalendarIDs: Set<String> = [] {
        didSet {
            saveSelection()
        }
    }
    
    /// Selected destination calendar ID
    @Published var destinationCalendarID: String = "" {
        didSet {
            UserDefaults.standard.set(destinationCalendarID, forKey: Self.destinationCalendarKey)
        }
    }
    
    /// Sync Start Date (default: Today - 7 days)
    @Published var syncStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())! {
        didSet { UserDefaults.standard.set(syncStartDate, forKey: "syncStartDate") }
    }
    
    /// Sync End Date (default: Today + 1 year)
    @Published var syncEndDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date())! {
        didSet { UserDefaults.standard.set(syncEndDate, forKey: "syncEndDate") }
    }
    
    /// Current authorization status
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    
    /// Loading state
    @Published var isLoading = false
    
    /// Error message if any
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    
    private let eventStore: EKEventStore
    private let permissionsManager: PermissionsManager
    
    // MARK: - Initialization
    
    init(eventStore: EKEventStore = EKEventStore(),
         permissionsManager: PermissionsManager? = nil) {
        self.eventStore = eventStore
        self.permissionsManager = permissionsManager ?? PermissionsManager(eventStore: eventStore)
        
        // Load saved selection
        loadSelection()
        
        // Load saved destination calendar ID
        if let destID = UserDefaults.standard.string(forKey: Self.destinationCalendarKey) {
            destinationCalendarID = destID
        }
        
        // Load saved sync window settings
        if let start = UserDefaults.standard.object(forKey: "syncStartDate") as? Date {
            syncStartDate = start
        }
        
        if let end = UserDefaults.standard.object(forKey: "syncEndDate") as? Date {
            syncEndDate = end
        }
        
        // Check initial authorization status
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }
    
    // MARK: - Public Methods
    
    /// Loads calendars from EventKit and groups them by source.
    func loadCalendars() async {
        isLoading = true
        errorMessage = nil
        
        // Check/request permission first
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        
        if authorizationStatus != .fullAccess {
            if authorizationStatus == .notDetermined {
                let granted = await permissionsManager.requestFullAccess()
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if !granted {
                    isLoading = false
                    return
                }
            } else {
                isLoading = false
                return
            }
        }
        
        // Fetch and group calendars
        let allCalendars = eventStore.calendars(for: .event)
        
        // All writable calendars for destination picker (no exclusions)
        allWritableCalendars = allCalendars
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
        
        // Filter out excluded calendars for SOURCE selection
        let filteredCalendars = allCalendars.filter { calendar in
            !Self.excludedCalendarTitles.contains(calendar.title) &&
            calendar.allowsContentModifications // Exclude read-only system calendars
        }
        
        // Group by source
        var groupedBySource: [String: [EKCalendar]] = [:]
        
        for calendar in filteredCalendars {
            let sourceName = calendar.source?.title ?? "Other"
            groupedBySource[sourceName, default: []].append(calendar)
        }
        
        // Convert to CalendarGroup array and sort
        calendarGroups = groupedBySource.map { sourceName, calendars in
            CalendarGroup(
                sourceName: sourceName,
                calendars: calendars.sorted { $0.title < $1.title }
            )
        }.sorted { $0.sourceName < $1.sourceName }
        
        // IMPORTANT: Validate stored destination calendar ID
        // Clear it if the calendar no longer exists (was deleted)
        if !destinationCalendarID.isEmpty {
            let exists = allWritableCalendars.contains { $0.calendarIdentifier == destinationCalendarID }
            if !exists {
                print("[CalendarSelectionViewModel] Stored destination calendar '\(destinationCalendarID)' no longer exists - clearing")
                destinationCalendarID = ""
            }
        }
        
        isLoading = false
    }
    
    /// Toggles selection state for a calendar.
    /// - Parameter calendarID: The calendar identifier to toggle.
    func toggleSelection(for calendarID: String) {
        if selectedCalendarIDs.contains(calendarID) {
            selectedCalendarIDs.remove(calendarID)
        } else {
            selectedCalendarIDs.insert(calendarID)
        }
    }
    
    /// Checks if a calendar is selected.
    /// - Parameter calendarID: The calendar identifier to check.
    /// - Returns: `true` if selected.
    func isSelected(_ calendarID: String) -> Bool {
        selectedCalendarIDs.contains(calendarID)
    }
    
    /// Returns the set of selected calendar IDs for use by SyncEngine.
    func getSelectedCalendarIDs() -> Set<String> {
        selectedCalendarIDs
    }
    
    /// Selects all available calendars.
    func selectAll() {
        let allIDs = calendarGroups.flatMap { $0.calendars.map { $0.calendarIdentifier } }
        selectedCalendarIDs = Set(allIDs)
    }
    
    /// Deselects all calendars.
    func deselectAll() {
        selectedCalendarIDs.removeAll()
    }
    
    /// Opens System Settings to the Calendars privacy section.
    func openPrivacySettings() {
        permissionsManager.openCalendarPrivacySettings()
    }
    
    // MARK: - Persistence
    
    /// Saves the current selection to UserDefaults.
    private func saveSelection() {
        let array = Array(selectedCalendarIDs)
        UserDefaults.standard.set(array, forKey: Self.selectedCalendarsKey)
    }
    
    /// Loads the saved selection from UserDefaults.
    private func loadSelection() {
        if let array = UserDefaults.standard.stringArray(forKey: Self.selectedCalendarsKey) {
            selectedCalendarIDs = Set(array)
        }
    }
}

// MARK: - Supporting Types

/// A group of calendars from the same source.
struct CalendarGroup: Identifiable {
    let id = UUID()
    let sourceName: String
    let calendars: [EKCalendar]
}

// MARK: - EKCalendar Extension for SwiftUI

extension EKCalendar: @retroactive Identifiable {
    public var id: String { calendarIdentifier }
}

extension EKCalendar {
    /// Converts the calendar's CGColor to a SwiftUI Color.
    var swiftUIColor: Color {
        if let cgColor = cgColor {
            return Color(cgColor: cgColor)
        }
        return Color.gray
    }
}
