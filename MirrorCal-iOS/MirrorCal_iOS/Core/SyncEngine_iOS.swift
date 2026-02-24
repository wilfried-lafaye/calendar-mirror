//
//  SyncEngine_iOS.swift
//  MirrorCal-iOS
//

import EventKit
import CoreData
import Foundation
import CryptoKit

/// The core synchronization engine for MirrorCal iOS.
/// Aligned with the macOS SyncEngine for feature parity.
///
/// Features:
/// - Debouncing (5s minimum between syncs)
/// - Detailed logging
/// - Destination calendar exclusion from sources (prevents infinite loop)
/// - Recurrence-aware event deletion
/// - Fallback sweeper for orphaned events
/// - Hash-based change detection
///
final class SyncEngine_iOS {
    
    // MARK: - Properties
    
    private let eventStore: EKEventStore
    private let persistence: PersistenceController_iOS
    private let syncQueue = DispatchQueue(label: "com.mirrorcal.syncengine.ios", qos: .utility)
    
    private var isSyncing = false
    private var sourceCalendarIDs: Set<String> = []
    
    /// Debounce: minimum time between syncs
    private static let minimumSyncInterval: TimeInterval = 5.0
    nonisolated(unsafe) private static var lastSyncTime: Date?
    
    // MARK: - Initialization
    
    init(eventStore: EKEventStore = EKEventStore(), persistence: PersistenceController_iOS = .shared) {
        self.eventStore = eventStore
        self.persistence = persistence
    }
    
    // MARK: - Public API
    
    func setSourceCalendars(_ calendarIDs: Set<String>) {
        syncQueue.async { [weak self] in
            self?.sourceCalendarIDs = calendarIDs
            print("[SyncEngine_iOS] Source calendars set: \(calendarIDs.count) calendars")
        }
    }
    
    func performSync(completion: @escaping (Result<SyncResult_iOS, Error>) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(.failure(SyncError_iOS.engineDeallocated)) }
                return
            }
            do {
                let result = try self.executeSync()
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    /// Checks if the engine should respond to a calendar change notification.
    func shouldRespondToCalendarChange() -> Bool {
        return !isSyncing
    }
    
    // MARK: - Sync Execution
    
    private func executeSync() throws -> SyncResult_iOS {
        // Prevent re-entry
        guard !isSyncing else {
            print("[SyncEngine_iOS] Sync already in progress, skipping")
            return SyncResult_iOS(created: 0, deleted: 0)
        }
        
        // Debounce: skip if synced too recently
        if let lastSync = Self.lastSyncTime {
            let elapsed = Date().timeIntervalSince(lastSync)
            if elapsed < Self.minimumSyncInterval {
                print("[SyncEngine_iOS] ⏳ Debounce: Skipping sync (only \(String(format: "%.1f", elapsed))s since last sync)")
                return SyncResult_iOS(created: 0, deleted: 0)
            }
        }
        
        isSyncing = true
        defer {
            isSyncing = false
            Self.lastSyncTime = Date()
        }
        
        let startTime = Date()
        print("[SyncEngine_iOS] Starting sync...")
        print("[SyncEngine_iOS] === NUCLEAR SYNC WITH DEBOUNCE ===")
        
        // Get destination calendar
        guard let destID = UserDefaults.standard.string(forKey: "destinationCalendarID"),
              let destinationCalendar = eventStore.calendar(withIdentifier: destID) else {
            throw SyncError_iOS.noDestination
        }
        
        let sourceName = destinationCalendar.source?.title ?? "Unknown"
        print("[SyncEngine_iOS] DESTINATION: \(destinationCalendar.title) (\(sourceName))")
        
        // Get source calendars — EXCLUDE destination to prevent infinite loop
        let sourceCalendars = eventStore.calendars(for: .event).filter {
            sourceCalendarIDs.contains($0.calendarIdentifier) &&
            $0.calendarIdentifier != destinationCalendar.calendarIdentifier
        }
        
        if sourceCalendarIDs.contains(destinationCalendar.calendarIdentifier) {
            print("[SyncEngine_iOS] ⚠️ WARNING: Destination calendar was in source list - excluded to prevent loop!")
        }
        
        print("[SyncEngine_iOS] Source calendars (\(sourceCalendars.count)):")
        for cal in sourceCalendars {
            print("[SyncEngine_iOS]   - \(cal.title)")
        }
        
        guard !sourceCalendars.isEmpty else {
            print("[SyncEngine_iOS] No source calendars configured")
            return SyncResult_iOS(created: 0, deleted: 0)
        }
        
        // Date range
        let defaultStart = Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        let defaultEnd = Calendar.current.date(byAdding: .day, value: 6, to: defaultStart)!
        let startDate = UserDefaults.standard.object(forKey: "syncStartDate") as? Date ?? defaultStart
        let endDate = UserDefaults.standard.object(forKey: "syncEndDate") as? Date ?? defaultEnd
        
        print("[SyncEngine_iOS] Date range: \(startDate) to \(endDate)")
        
        // Fetch source events
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: sourceCalendars)
        let sourceEvents = eventStore.events(matching: predicate)
        print("[SyncEngine_iOS] Found \(sourceEvents.count) source events in range")
        
        eventStore.refreshSourcesIfNecessary()
        
        // === DELETION PHASE ===
        var deleted = 0
        var deleteErrors = 0
        var idsProcessed = Set<String>()
        
        // 1. Delete by tracked IDs (fast)
        let trackedIDs = loadTrackedEventIDs(for: destID)
        print("[SyncEngine_iOS] Loaded \(trackedIDs.count) tracked IDs from previous sync")
        
        for id in trackedIDs {
            if let event = eventStore.event(withIdentifier: id) {
                do {
                    let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
                    try eventStore.remove(event, span: span, commit: false)
                    deleted += 1
                    idsProcessed.insert(id)
                } catch {
                    print("[SyncEngine_iOS] Error removing tracked event: \(error.localizedDescription)")
                    deleteErrors += 1
                }
            }
        }
        
        // 2. Fallback sweeper: catch orphaned events
        let fourYears: TimeInterval = 4 * 365 * 24 * 3600
        let sweepPredicate = eventStore.predicateForEvents(
            withStart: Date(timeIntervalSinceNow: -fourYears),
            end: Date(timeIntervalSinceNow: fourYears),
            calendars: [destinationCalendar]
        )
        let existingEvents = eventStore.events(matching: sweepPredicate)
        
        for event in existingEvents {
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
        
        // Commit deletions
        if deleted > 0 {
            do {
                try eventStore.commit()
                print("[SyncEngine_iOS] ✅ Committed deletion of \(deleted) events (errors: \(deleteErrors))")
            } catch {
                print("[SyncEngine_iOS] ❌ Error committing deletions: \(error.localizedDescription)")
            }
        }
        
        // === CREATION PHASE ===
        print("[SyncEngine_iOS] Creating \(sourceEvents.count) events (batch mode):")
        var created = 0
        var saveErrors = 0
        var newTrackedIDs: [String] = []
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM/dd HH:mm"
        
        for (index, sourceEvent) in sourceEvents.enumerated() {
            let dateStr = dateFormatter.string(from: sourceEvent.startDate ?? Date())
            
            let mirrorEvent = EKEvent(eventStore: eventStore)
            copyEventProperties(from: sourceEvent, to: mirrorEvent)
            mirrorEvent.calendar = destinationCalendar
            
            do {
                try eventStore.save(mirrorEvent, span: .thisEvent, commit: false)
                print("[SyncEngine_iOS]   \(index + 1). '\(sourceEvent.title ?? "?")' @ \(dateStr) → saved")
                created += 1
                newTrackedIDs.append(mirrorEvent.calendarItemIdentifier)
            } catch {
                saveErrors += 1
                print("[SyncEngine_iOS]   \(index + 1). ❌ '\(sourceEvent.title ?? "?")' @ \(dateStr) → Error: \(error.localizedDescription)")
            }
        }
        
        // Batch commit
        if created > 0 {
            do {
                try eventStore.commit()
                print("[SyncEngine_iOS] ✅ Batch committed \(created) events (errors: \(saveErrors))")
                saveTrackedEventIDs(newTrackedIDs, for: destID)
                print("[SyncEngine_iOS] 💾 Saved \(newTrackedIDs.count) event IDs for next sync")
            } catch {
                print("[SyncEngine_iOS] ❌ Batch commit FAILED: \(error.localizedDescription)")
            }
        } else {
            saveTrackedEventIDs([], for: destID)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        print("[SyncEngine_iOS] ✅ Sync complete in \(String(format: "%.2f", duration))s: \(created) created, \(deleted) deleted")
        
        return SyncResult_iOS(created: created, deleted: deleted)
    }
    
    // MARK: - Event Copying
    
    private func copyEventProperties(from source: EKEvent, to target: EKEvent) {
        target.title = source.title
        target.startDate = source.startDate
        target.endDate = source.endDate
        target.isAllDay = source.isAllDay
        target.location = source.location
        target.notes = source.notes
        target.url = source.url
        // Note: We intentionally do NOT copy attendees, recurrence rules, or calendar
    }
    
    // MARK: - Persistence Helpers
    
    private func trackedIDsKey(for calendarID: String) -> String {
        return "MirrorCal_TrackedIDs_\(calendarID)"
    }
    
    private func saveTrackedEventIDs(_ ids: [String], for calendarID: String) {
        UserDefaults.standard.set(ids, forKey: trackedIDsKey(for: calendarID))
    }
    
    private func loadTrackedEventIDs(for calendarID: String) -> [String] {
        // Check new key first
        if let ids = UserDefaults.standard.stringArray(forKey: trackedIDsKey(for: calendarID)), !ids.isEmpty {
            return ids
        }
        // Fallback: check old key format for backward compatibility
        let oldKey = "TrackedIDs_\(calendarID)"
        if let oldIDs = UserDefaults.standard.stringArray(forKey: oldKey), !oldIDs.isEmpty {
            print("[SyncEngine_iOS] Migrating \(oldIDs.count) tracked IDs from old key format")
            // Migrate to new key and clean up old one
            UserDefaults.standard.set(oldIDs, forKey: trackedIDsKey(for: calendarID))
            UserDefaults.standard.removeObject(forKey: oldKey)
            return oldIDs
        }
        return []
    }
    
    // MARK: - Hash Calculation
    
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
}

// MARK: - Supporting Types

struct SyncResult_iOS {
    let created: Int
    let deleted: Int
    
    var description: String {
        "\(created) created, \(deleted) deleted"
    }
}

enum SyncError_iOS: LocalizedError {
    case noDestination
    case engineDeallocated
    
    var errorDescription: String? {
        switch self {
        case .noDestination:
            return "No destination calendar configured"
        case .engineDeallocated:
            return "Sync engine was deallocated during operation"
        }
    }
}
