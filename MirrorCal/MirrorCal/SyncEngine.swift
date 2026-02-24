//
//  SyncEngine.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import EventKit
import CoreData
import Foundation
import CryptoKit

/// The core synchronization engine for MirrorCal.
/// Handles unidirectional sync from source calendars to the Mirror calendar.
///
/// ## Thread Safety
/// All sync operations run on a dedicated background serial queue to:
/// - Avoid blocking the Main Thread
/// - Prevent race conditions
/// - Ensure atomic sync operations
///
/// ## Infinite Loop Prevention
/// When listening to `EKEventStoreChangedNotification`, the engine checks if
/// the changed calendar is the Mirror calendar and ignores self-triggered changes.
///
final class SyncEngine {
    
    // MARK: - Constants
    
    /// Name of the local Mirror calendar
    static let mirrorCalendarName = "MirrorCal"
    
    /// Start date for sync window
    var startDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    
    /// End date for sync window
    var endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    
    // MARK: - Properties
    
    /// EventKit store for calendar access
    private let eventStore: EKEventStore
    
    /// CoreData persistence controller
    private let persistence: PersistenceController
    
    /// Serial queue for all sync operations (prevents race conditions)
    private let syncQueue = DispatchQueue(label: "com.mirrorcal.syncengine", qos: .utility)
    
    /// The Mirror calendar (cached after first lookup/creation)
    private var mirrorCalendar: EKCalendar?
    
    /// Flag to prevent processing our own changes
    private var isSyncing = false
    
    /// Last sync completion time (for debounce protection) - STATIC to share across instances
    /// Access is serialized on syncQueue, so nonisolated(unsafe) is safe here
    nonisolated(unsafe) private static var lastSyncTime: Date?
    
    /// Minimum time between syncs (debounce) - Reduced to 5s since persistence handles duplication
    private static let minimumSyncInterval: TimeInterval = 5.0
    
    /// Source calendar identifiers to sync from
    private var sourceCalendarIDs: Set<String> = []
    
    // MARK: - Initialization
    
    init(eventStore: EKEventStore = EKEventStore(),
         persistence: PersistenceController = .shared) {
        self.eventStore = eventStore
        self.persistence = persistence
    }
    
    // MARK: - Public API
    
    /// Configures which calendars to sync from.
    /// - Parameter calendarIDs: Set of calendar identifiers to use as sources.
    func setSourceCalendars(_ calendarIDs: Set<String>) {
        syncQueue.async { [weak self] in
            self?.sourceCalendarIDs = calendarIDs
            print("[SyncEngine] Source calendars set: \(calendarIDs.count) calendars")
        }
    }
    
    /// Triggers a full synchronization.
    /// This is safe to call from any thread.
    func performSync() {
        syncQueue.async { [weak self] in
            self?.executeSync()
        }
    }
    
    /// Performs sync and calls completion when done.
    /// - Parameter completion: Called on the main queue when sync completes.
    func performSync(completion: @escaping (Result<SyncResult, Error>) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(.failure(SyncError.engineDeallocated))
                }
                return
            }
            
            do {
                let result = try self.executeSyncWithResult()
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Destination Calendar Management
    
    /// UserDefaults key for destination calendar ID
    private static let destinationCalendarKey = "destinationCalendarID"
    
    /// Gets the user-selected destination calendar from UserDefaults.
    /// - Returns: The destination calendar, or nil if not configured or not found.
    private func getDestinationCalendar() -> EKCalendar? {
        // Return cached calendar if still valid
        if let cached = mirrorCalendar,
           eventStore.calendar(withIdentifier: cached.calendarIdentifier) != nil {
            return cached
        }
        
        // Get the stored calendar ID from UserDefaults
        guard let storedID = UserDefaults.standard.string(forKey: Self.destinationCalendarKey),
              !storedID.isEmpty else {
            print("[SyncEngine] ERROR: No destination calendar configured")
            return nil
        }
        
        // Find the calendar by ID
        guard let calendar = eventStore.calendar(withIdentifier: storedID) else {
            print("[SyncEngine] ERROR: Destination calendar not found: \(storedID)")
            return nil
        }
        
        mirrorCalendar = calendar
        print("[SyncEngine] Using destination calendar: \(calendar.title) (\(calendar.calendarIdentifier))")
        return calendar
    }
    

    
    // MARK: - Sync Execution
    
    /// Main sync logic - runs on syncQueue.
    private func executeSync() {
        do {
            _ = try executeSyncWithResult()
        } catch {
            print("[SyncEngine] Sync failed: \(error.localizedDescription)")
        }
    }
    
    /// Main sync logic with result tracking.
    /// - Returns: A `SyncResult` with statistics.
    private func executeSyncWithResult() throws -> SyncResult {
        // Prevent re-entry
        guard !isSyncing else {
            print("[SyncEngine] Sync already in progress, skipping")
            return SyncResult(created: 0, updated: 0, deleted: 0, skipped: 0)
        }
        
        // Debounce: Skip if synced too recently (STATIC - works across all instances)
        if let lastSync = Self.lastSyncTime {
            let elapsed = Date().timeIntervalSince(lastSync)
            if elapsed < Self.minimumSyncInterval {
                print("[SyncEngine] ⏳ Debounce: Skipping sync (only \(String(format: "%.1f", elapsed))s since last sync)")
                return SyncResult(created: 0, updated: 0, deleted: 0, skipped: 0)
            }
        }
        
        isSyncing = true
        defer { 
            isSyncing = false
            Self.lastSyncTime = Date() // Record completion time for debounce
        }
        
        print("[SyncEngine] Starting sync...")
        print("[SyncEngine] === VERSION 3.0 - NUCLEAR SYNC WITH DEBOUNCE ===")
        
        // NOTE: We intentionally do NOT call eventStore.reset() here
        // Reset causes iCloud sync delays which lead to duplicate calendars
        // and missing events. The event store auto-refreshes adequately.
        
        let startTime = Date()
        
        // Get the user-configured destination calendar
        guard let destinationCalendar = getDestinationCalendar() else {
            throw SyncError.mirrorCalendarNotAvailable
        }
        
        // Check if destination is on iCloud (which has sync delays)
        let sourceType = destinationCalendar.source?.sourceType ?? .local
        let sourceName = destinationCalendar.source?.title ?? "Unknown"
        
        print("[SyncEngine] ========================================")
        print("[SyncEngine] DESTINATION: \(destinationCalendar.title)")
        print("[SyncEngine] Source: \(sourceName) (type: \(sourceType.rawValue))")
        if sourceType == .calDAV {
            print("[SyncEngine] ⚠️ WARNING: iCloud/CalDAV calendar - sync delays may cause issues!")
            print("[SyncEngine] ⚠️ Consider using a LOCAL calendar for more reliable sync")
        }
        print("[SyncEngine] ========================================")
        
        // Get source calendars - IMPORTANT: EXCLUDE destination calendar to prevent sync loop!
        let sourceCalendars = eventStore.calendars(for: .event).filter {
            sourceCalendarIDs.contains($0.calendarIdentifier) &&
            $0.calendarIdentifier != destinationCalendar.calendarIdentifier // CRITICAL: Exclude destination!
        }
        
        print("[SyncEngine] Source calendars (\(sourceCalendars.count)):")
        for cal in sourceCalendars {
            print("[SyncEngine]   - \(cal.title) (\(cal.calendarIdentifier))")
        }
        
        // Check for conflict
        if sourceCalendarIDs.contains(destinationCalendar.calendarIdentifier) {
            print("[SyncEngine] ⚠️ WARNING: Destination calendar was in source list - excluded to prevent loop!")
        }
        
        guard !sourceCalendars.isEmpty else {
            print("[SyncEngine] No source calendars configured")
            return SyncResult(created: 0, updated: 0, deleted: 0, skipped: 0)
        }
        
        // Use configured time window, normalized to full days
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: self.startDate)
        let endDate = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: self.endDate) ?? self.endDate
        
        print("[SyncEngine] Date range: \(startDate) to \(endDate)")
        
        // Fetch source events
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: sourceCalendars
        )
        let sourceEvents = eventStore.events(matching: predicate)
        print("[SyncEngine] Found \(sourceEvents.count) source events in range")
        
        // ... existing sync logic ...
        
        // ============================================================
        // NUCLEAR SYNC STRATEGY WITH PERSISTENCE (v3.1)
        // 1. Delete events by TRACKED ID (bypasses iCloud query delays)
        // 2. Fallback to wide date range sweep (for older/manual events)
        // 3. Recreate events and update tracked IDs
        // ============================================================
        
        eventStore.refreshSourcesIfNecessary()
        
        var deleted = 0
        var deleteErrors = 0
        
        // 1. Load tracked IDs from previous sync
        let trackedIDs = loadTrackedEventIDs(for: destinationCalendar.calendarIdentifier)
        print("[SyncEngine] Loaded \(trackedIDs.count) tracked IDs from previous sync")
        
        // 2. Smart Deletion: Try to delete by ID first (fast & reliable)
        var idsProcessed = Set<String>()
        
        for id in trackedIDs {
            if let event = eventStore.event(withIdentifier: id) {
                do {
                    let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
                    try eventStore.remove(event, span: span, commit: false)
                    deleted += 1
                    idsProcessed.insert(id)
                } catch {
                    print("[SyncEngine] Error removing tracked event: \(error.localizedDescription)")
                    deleteErrors += 1
                }
            } else {
                // Event not found by ID - likely already deleted or iCloud hasn't synced it BACK to us
                // But if it exists, the duplicate will be caught by the sweeper below
            }
        }
        
        // 3. Fallback Sweeper: Catch any untracked events in the window
        let fourYears: TimeInterval = 4 * 365 * 24 * 3600
        let predicateStart = Date(timeIntervalSinceNow: -fourYears)
        let predicateEnd = Date(timeIntervalSinceNow: fourYears)
        
        let mirrorPredicate = eventStore.predicateForEvents(
            withStart: predicateStart,
            end: predicateEnd,
            calendars: [destinationCalendar]
        )
        let existingEvents = eventStore.events(matching: mirrorPredicate)
        
        for event in existingEvents {
            // Only delete if we haven't already processed this event
            if !idsProcessed.contains(event.calendarItemIdentifier) {
                do {
                    let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
                    try eventStore.remove(event, span: span, commit: false)
                    deleted += 1
                } catch {
                    deleteErrors += 1
                }
            }
        }
        
        // Commit all deletions
        if deleted > 0 {
            do {
                try eventStore.commit()
                print("[SyncEngine] ✅ Committed deletion of \(deleted) events (errors: \(deleteErrors))")
            } catch {
                print("[SyncEngine] ❌ Error committing deletions: \(error.localizedDescription)")
            }
        }
        
        // 4. Create new events and track their IDs
        print("[SyncEngine] Creating \(sourceEvents.count) events (batch mode):")
        var created = 0
        var saveErrors = 0
        var newTrackedIDs: [String] = [] // Accumulate new IDs
        
        for (index, sourceEvent) in sourceEvents.enumerated() {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM/dd HH:mm"
            let dateStr = dateFormatter.string(from: sourceEvent.startDate ?? Date())
            
            let mirrorEvent = EKEvent(eventStore: eventStore)
            copyEventProperties(from: sourceEvent, to: mirrorEvent)
            mirrorEvent.calendar = destinationCalendar
            
            do {
                try eventStore.save(mirrorEvent, span: .thisEvent, commit: false)
                print("[SyncEngine]   \(index + 1). '\(sourceEvent.title ?? "?")' @ \(dateStr) → saved")
                created += 1
                
                // IMPORTANT: Append the ID. Note that for batch save, ID is temporary but
                // should persist after commit for local reference. For iCloud it maps to a real ID.
                newTrackedIDs.append(mirrorEvent.calendarItemIdentifier)
            } catch {
                saveErrors += 1
                print("[SyncEngine]   \(index + 1). ❌ '\(sourceEvent.title ?? "?")' @ \(dateStr) → Error: \(error.localizedDescription)")
            }
        }
        
        // BATCH COMMIT
        if created > 0 {
            do {
                try eventStore.commit()
                print("[SyncEngine] ✅ Batch committed \(created) events (errors: \(saveErrors))")
                
                // 5. Persist the new list of IDs
                saveTrackedEventIDs(newTrackedIDs, for: destinationCalendar.calendarIdentifier)
                print("[SyncEngine] 💾 Saved \(newTrackedIDs.count) event IDs for next sync")
                
            } catch {
                print("[SyncEngine] ❌ Batch commit FAILED: \(error.localizedDescription)")
            }
        } else {
            // Even if 0 created, clear the tracked list if we deleted everything
             saveTrackedEventIDs([], for: destinationCalendar.calendarIdentifier)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        print("[SyncEngine] ✅ Sync complete in \(String(format: "%.2f", duration))s: \(created) created, \(deleted) deleted")
        
        return SyncResult(created: created, updated: 0, deleted: deleted, skipped: 0)
    }
    
    // MARK: - Persistence Helpers
    
    private func trackedIDsKey(for calendarID: String) -> String {
        return "MirrorCal_TrackedIDs_\(calendarID)"
    }
    
    private func saveTrackedEventIDs(_ ids: [String], for calendarID: String) {
        UserDefaults.standard.set(ids, forKey: trackedIDsKey(for: calendarID))
    }
    
    private func loadTrackedEventIDs(for calendarID: String) -> [String] {
        return UserDefaults.standard.stringArray(forKey: trackedIDsKey(for: calendarID)) ?? []
    }
    
    // MARK: - Event Operations
    
    /// Creates a new event in the Mirror calendar.
    /// - Parameters:
    ///   - sourceEvent: The source event to mirror.
    ///   - calendar: The Mirror calendar.
    /// - Returns: The external identifier of the created event, or nil on failure.
    private func createMirrorEvent(for sourceEvent: EKEvent, in calendar: EKCalendar) -> String? {
        let mirrorEvent = EKEvent(eventStore: eventStore)
        
        // Copy relevant properties
        copyEventProperties(from: sourceEvent, to: mirrorEvent)
        mirrorEvent.calendar = calendar
        
        do {
            try eventStore.save(mirrorEvent, span: .thisEvent, commit: true)
            return mirrorEvent.calendarItemExternalIdentifier
        } catch {
            print("[SyncEngine] Error creating mirror event: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Updates an existing mirror event.
    /// - Parameters:
    ///   - sourceEvent: The source event with new data.
    ///   - mapping: The CoreData mapping for this event pair.
    ///   - newHash: The new hash value.
    ///   - calendar: The Mirror calendar.
    /// - Returns: `true` if update succeeded.
    @discardableResult
    private func updateMirrorEvent(for sourceEvent: EKEvent, mapping: EventMapping, newHash: String, in calendar: EKCalendar) -> Bool {
        guard let mirrorID = mapping.mirrorID else {
            print("[SyncEngine] Warning: Mapping has no mirrorID")
            return false
        }
        
        // Find the mirror event by external ID
        // Note: We need to search within calendar since externalID lookup isn't direct
        let predicate = eventStore.predicateForEvents(
            withStart: Date.distantPast,
            end: Date.distantFuture,
            calendars: [calendar]
        )
        
        guard let mirrorEvent = eventStore.events(matching: predicate)
            .first(where: { $0.calendarItemExternalIdentifier == mirrorID }) else {
            print("[SyncEngine] Warning: Mirror event not found for ID: \(mirrorID)")
            return false
        }
        
        // Update properties
        copyEventProperties(from: sourceEvent, to: mirrorEvent)
        
        do {
            try eventStore.save(mirrorEvent, span: .thisEvent, commit: true)
            return true
        } catch {
            print("[SyncEngine] Error updating mirror event: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Copies relevant properties from source to target event.
    private func copyEventProperties(from source: EKEvent, to target: EKEvent) {
        target.title = source.title
        target.startDate = source.startDate
        target.endDate = source.endDate
        target.isAllDay = source.isAllDay
        target.location = source.location
        target.notes = source.notes
        target.url = source.url
        
        // Copy alarms if desired (optional - you might want to disable for mirrors)
        // target.alarms = source.alarms?.map { $0.copy() as! EKAlarm }
        
        // Note: We intentionally do NOT copy:
        // - attendees (they belong to the source event)
        // - recurrence rules (each occurrence is mirrored individually)
        // - calendar (we set this to the mirror calendar)
    }
    
    // MARK: - Cleanup
    
    /// Purges mirror events that are not in the valid set.
    /// - Parameters:
    ///   - validMirrorIDs: Set of mirror IDs that should exist.
    ///   - mirrorCalendar: The Mirror calendar.
    ///   - context: CoreData context.
    /// - Returns: Number of events deleted.
    private func cleanupOrphanedEvents(
        validMirrorIDs: Set<String>,
        mirrorCalendar: EKCalendar,
        context: NSManagedObjectContext
    ) -> Int {
        var deletedCount = 0
        
        // 1. Delete events from Calendar that are not valid
        // We scan a wide range to catch events that might have moved out of the sync window
        // Limit range to avoid potential EventKit issues with distantPast/Future
        let fourYears: TimeInterval = 4 * 365 * 24 * 3600
        let cleanupStart = Date(timeIntervalSinceNow: -fourYears)
        let cleanupEnd = Date(timeIntervalSinceNow: fourYears)
        
        let predicate = eventStore.predicateForEvents(
            withStart: cleanupStart,
            end: cleanupEnd,
            calendars: [mirrorCalendar]
        )
        
        let allMirrorEvents = eventStore.events(matching: predicate)
        var eventsToDelete: [EKEvent] = []
        
        for event in allMirrorEvents {
            if !validMirrorIDs.contains(event.calendarItemExternalIdentifier) {
                eventsToDelete.append(event)
            }
        }
        
        // Batch delete from EventKit
        for event in eventsToDelete {
            do {
                try eventStore.remove(event, span: .thisEvent, commit: false)
                deletedCount += 1
            } catch {
                print("[SyncEngine] Error removing zombie event: \(error.localizedDescription)")
            }
        }
        
        if !eventsToDelete.isEmpty {
            do {
                try eventStore.commit()
                print("[SyncEngine] Purged \(eventsToDelete.count) zombie events")
            } catch {
                print("[SyncEngine] Error committing deletions: \(error.localizedDescription)")
            }
        }
        
        // 2. Clean up CoreData mappings
        let allMappings = persistence.fetchAllMappings(in: context)
        for mapping in allMappings {
            if let mirrorID = mapping.mirrorID {
                if !validMirrorIDs.contains(mirrorID) {
                    context.delete(mapping)
                }
            } else {
                // Invalid mapping
                context.delete(mapping)
            }
        }
        
        return deletedCount
    }
    

    
    // MARK: - Hash Calculation
    
    /// Calculates a hash for an event based on its key properties.
    /// Used for change detection without needing to compare all fields.
    ///
    /// Properties included in hash:
    /// - Title
    /// - Start date (ISO8601)
    /// - End date (ISO8601)
    /// - Location
    /// - All-day flag
    ///
    /// - Parameter event: The event to hash.
    /// - Returns: A SHA256 hash string.
    static func calculateHash(for event: EKEvent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        var components: [String] = []
        components.append(event.title ?? "")
        components.append(formatter.string(from: event.startDate))
        components.append(formatter.string(from: event.endDate))
        components.append(event.location ?? "")
        components.append(event.isAllDay ? "allDay" : "timed")
        components.append(event.notes ?? "")
        
        let combined = components.joined(separator: "|")
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Notification Handling
    
    /// Checks if a calendar change notification is relevant (not our own Mirror).
    /// Call this before triggering a sync from `EKEventStoreChangedNotification`.
    func shouldRespondToCalendarChange() -> Bool {
        // If we're currently syncing, ignore the notification
        return !isSyncing
    }
}

// MARK: - Supporting Types

/// Result of a sync operation.
struct SyncResult {
    let created: Int
    let updated: Int
    let deleted: Int
    let skipped: Int
    
    var total: Int { created + updated + deleted + skipped }
    
    var description: String {
        "\(created) created, \(updated) updated, \(deleted) deleted, \(skipped) unchanged"
    }
}

/// Errors that can occur during sync.
enum SyncError: LocalizedError {
    case mirrorCalendarNotAvailable
    case noSourceCalendars
    case engineDeallocated
    
    var errorDescription: String? {
        switch self {
        case .mirrorCalendarNotAvailable:
            return "Could not find or create the MirrorCal calendar"
        case .noSourceCalendars:
            return "No source calendars configured"
        case .engineDeallocated:
            return "Sync engine was deallocated during operation"
        }
    }
}
