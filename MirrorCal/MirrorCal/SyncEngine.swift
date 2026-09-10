//
//  SyncEngine.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

@preconcurrency import EventKit
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
/// ## Single Instance
/// Use `SyncEngine.shared` everywhere (the persistent app-level listener and the
/// manual "Sync Now" button both go through the same instance). This is what makes
/// the `isSyncing` reentrancy guard actually meaningful — two independent instances
/// would each think they're the only one running.
///
/// ## Infinite Loop Prevention
/// When listening to `EKEventStoreChangedNotification`, the engine checks if
/// the changed calendar is the Mirror calendar and ignores self-triggered changes.
///
/// ## Sync Window
/// The sync window is no longer user-configurable. It's a rolling window recomputed
/// from "now" on every sync (see `currentSyncWindow`), which is what lets automatic
/// sync work without the user ever picking dates — and stays safely under EventKit's
/// ~4 year maximum span for `predicateForEvents(withStart:end:calendars:)`.
///
/// ## Incremental Diff (not "nuclear" delete/recreate)
/// Each sync computes a stable key per source event/occurrence, compares it against
/// the `EventMapping` CoreData table, and only creates/updates/deletes what actually
/// changed. A sync where nothing changed is a no-op (no EventKit writes at all), which
/// is what makes it safe to trigger this very frequently (on every calendar change).
final class SyncEngine: @unchecked Sendable {

    // MARK: - Shared Instance

    /// The single SyncEngine instance used throughout the app. Always go through this
    /// instead of creating a new SyncEngine() — see "Single Instance" above.
    static let shared = SyncEngine()

    // MARK: - Constants

    /// UserDefaults key holding the set of selected source calendar identifiers.
    /// Shared with `CalendarSelectionViewModel`.
    private static let sourceCalendarsKey = "selectedSourceCalendarIDs"

    /// UserDefaults key for destination calendar ID
    private static let destinationCalendarKey = "destinationCalendarID"

    /// Guards the one-time migration away from the old "nuclear" (delete-all/recreate-all)
    /// sync path. Events created by that path have no `EventMapping`, so the first sync
    /// under the new diff engine needs to wipe them once — otherwise they'd be invisible
    /// to the diff and every source event would be duplicated.
    private static let hasMigratedKey = "MirrorCal_HasMigratedToIncrementalSync_v1"

    // MARK: - Properties

    /// EventKit store for calendar access
    private let eventStore: EKEventStore

    /// CoreData persistence controller
    private let persistence: PersistenceController

    /// Serial queue for all sync operations (prevents race conditions)
    private let syncQueue = DispatchQueue(label: "com.mirrorcal.syncengine", qos: .utility)

    /// The Mirror (destination) calendar (cached after first lookup)
    private var mirrorCalendar: EKCalendar?

    /// Flag to prevent processing our own changes / running two syncs concurrently.
    /// Only ever read/written from `syncQueue`.
    private var isSyncing = false

    /// Set when a sync is requested while one is already running. Consumed right after
    /// the in-flight sync finishes, so a change that arrives mid-sync is never silently
    /// dropped — it triggers exactly one follow-up sync instead of being lost.
    private var pendingRerunRequested = false

    // MARK: - Initialization

    init(eventStore: EKEventStore = EKEventStore(),
         persistence: PersistenceController = .shared) {
        self.eventStore = eventStore
        self.persistence = persistence
    }

    // MARK: - Public API

    /// Triggers a full synchronization.
    /// This is safe to call from any thread.
    func performSync() {
        syncQueue.async { [weak self] in
            self?.executeSync()
        }
    }

    /// Performs sync and calls completion when done.
    /// - Parameter completion: Called on the main actor when sync completes.
    func performSync(completion: @escaping @MainActor (Result<SyncResult, Error>) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else {
                Task { @MainActor in completion(.failure(SyncError.engineDeallocated)) }
                return
            }

            do {
                let result = try self.executeSyncWithResult()
                Task { @MainActor in completion(.success(result)) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    /// Wipes every mirrored event and every `EventMapping`, then performs a fresh sync
    /// from scratch. Intended as an explicit, user-triggered repair tool (e.g. "Force
    /// Full Resync" in Settings) — never called automatically.
    func performFullResync(completion: @escaping @MainActor (Result<SyncResult, Error>) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else {
                Task { @MainActor in completion(.failure(SyncError.engineDeallocated)) }
                return
            }

            guard let destinationCalendar = self.getDestinationCalendar() else {
                Task { @MainActor in completion(.failure(SyncError.mirrorCalendarNotAvailable)) }
                return
            }

            self.wipeAllMirrorEvents(in: destinationCalendar, window: Self.currentSyncWindow())

            let context = self.persistence.newBackgroundContext()
            context.performAndWait {
                for mapping in self.persistence.fetchAllMappings(in: context) {
                    context.delete(mapping)
                }
                self.persistence.save(context: context)
            }

            do {
                let result = try self.executeSyncWithResult()
                Task { @MainActor in completion(.success(result)) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    /// Checks if a calendar change notification is relevant (not our own Mirror).
    /// Call this before triggering a sync from `EKEventStoreChangedNotification`.
    func shouldRespondToCalendarChange() -> Bool {
        return !isSyncing
    }

    // MARK: - Sync Window

    /// The automatic, rolling sync window: recomputed relative to "now" on every call, so
    /// it never needs a manual date pick and always slides forward. Kept safely under
    /// EventKit's documented ~4 year maximum span between start and end for
    /// `predicateForEvents(withStart:end:calendars:)`.
    static func currentSyncWindow(now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let rawStart = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let rawEnd = calendar.date(byAdding: .year, value: 3, to: now) ?? now
        let start = calendar.startOfDay(for: rawStart)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: rawEnd) ?? rawEnd
        return (start, end)
    }

    /// Human-readable description of the current sync window, for read-only display in Settings.
    static var syncWindowDescription: String {
        let window = currentSyncWindow()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: window.start)) – \(formatter.string(from: window.end))"
    }

    // MARK: - Source Calendars

    /// Reads the currently selected source calendar IDs fresh from UserDefaults on every
    /// call, rather than caching them — so a persistent SyncEngine.shared instance always
    /// syncs with whatever is currently configured in Settings, with no extra plumbing.
    private func currentSourceCalendarIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.sourceCalendarsKey) ?? [])
    }

    // MARK: - Destination Calendar Management

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

    /// Main sync logic with result tracking. Runs on syncQueue.
    /// - Returns: A `SyncResult` with statistics.
    private func executeSyncWithResult() throws -> SyncResult {
        // Prevent re-entry. Instead of dropping the request, remember it and re-run once
        // the in-flight sync completes (see `defer` below).
        guard !isSyncing else {
            pendingRerunRequested = true
            print("[SyncEngine] Sync already in progress — will re-run after it completes")
            return SyncResult(created: 0, updated: 0, deleted: 0, skipped: 0)
        }

        isSyncing = true
        defer {
            isSyncing = false
            if pendingRerunRequested {
                pendingRerunRequested = false
                syncQueue.async { [weak self] in self?.executeSync() }
            }
        }

        let startTime = Date()

        guard let destinationCalendar = getDestinationCalendar() else {
            throw SyncError.mirrorCalendarNotAvailable
        }

        let sourceCalendarIDs = currentSourceCalendarIDs()

        // Get source calendars — EXCLUDE destination to prevent an infinite loop.
        let sourceCalendars = eventStore.calendars(for: .event).filter {
            sourceCalendarIDs.contains($0.calendarIdentifier) &&
            $0.calendarIdentifier != destinationCalendar.calendarIdentifier
        }

        guard !sourceCalendars.isEmpty else {
            print("[SyncEngine] No source calendars configured")
            return SyncResult(created: 0, updated: 0, deleted: 0, skipped: 0)
        }

        eventStore.refreshSourcesIfNecessary()

        let window = Self.currentSyncWindow()

        // One-time migration away from the old "nuclear" sync: events it created have no
        // EventMapping, so they'd otherwise be invisible to the diff below and every
        // source event would get duplicated on first run.
        if !UserDefaults.standard.bool(forKey: Self.hasMigratedKey) {
            wipeAllMirrorEvents(in: destinationCalendar, window: window)
            UserDefaults.standard.set(true, forKey: Self.hasMigratedKey)
        }

        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: sourceCalendars)
        let sourceEvents = eventStore.events(matching: predicate)

        let context = persistence.newBackgroundContext()
        let result = context.performAndWait {
            diffSync(sourceEvents: sourceEvents, destinationCalendar: destinationCalendar, context: context)
        }

        let duration = Date().timeIntervalSince(startTime)
        print("[SyncEngine] ✅ Sync complete in \(String(format: "%.2f", duration))s: \(result.description)")

        return result
    }

    /// Compares `sourceEvents` against the `EventMapping` table and applies only the
    /// create/update/delete operations actually needed. Must be called from within
    /// `context.performAndWait`.
    private func diffSync(sourceEvents: [EKEvent], destinationCalendar: EKCalendar, context: NSManagedObjectContext) -> SyncResult {
        let existingMappings = persistence.fetchAllMappings(in: context)
        var mappingsByKey: [String: EventMapping] = [:]
        for mapping in existingMappings {
            if let key = mapping.sourceID {
                mappingsByKey[key] = mapping
            }
        }

        var seenKeys = Set<String>()
        var created = 0, updated = 0, skipped = 0, deleted = 0

        for sourceEvent in sourceEvents {
            let key = Self.sourceKey(for: sourceEvent)
            seenKeys.insert(key)
            let newHash = Self.calculateHash(for: sourceEvent)

            if let mapping = mappingsByKey[key] {
                if let mirrorID = mapping.mirrorID, let mirrorEvent = eventStore.event(withIdentifier: mirrorID) {
                    if mapping.lastKnownHash == newHash {
                        skipped += 1
                        continue
                    }
                    copyEventProperties(from: sourceEvent, to: mirrorEvent)
                    do {
                        try eventStore.save(mirrorEvent, span: .thisEvent, commit: false)
                        mapping.lastKnownHash = newHash
                        updated += 1
                    } catch {
                        print("[SyncEngine] Error updating mirror event: \(error.localizedDescription)")
                    }
                } else {
                    // The mirror event is gone (e.g. the user deleted it manually) — recreate it.
                    if let newMirrorID = createMirrorEvent(for: sourceEvent, in: destinationCalendar) {
                        mapping.mirrorID = newMirrorID
                        mapping.lastKnownHash = newHash
                        created += 1
                    }
                }
            } else {
                if let newMirrorID = createMirrorEvent(for: sourceEvent, in: destinationCalendar) {
                    persistence.createMapping(
                        sourceID: key,
                        mirrorID: newMirrorID,
                        hash: newHash,
                        calendarID: sourceEvent.calendar?.calendarIdentifier ?? "",
                        in: context
                    )
                    created += 1
                }
            }
        }

        // Anything tracked but not seen this pass has left the source (deleted, or slid
        // out of the sync window) — remove its mirror event and its mapping.
        for mapping in existingMappings {
            guard let key = mapping.sourceID, !seenKeys.contains(key) else { continue }
            if let mirrorID = mapping.mirrorID, let mirrorEvent = eventStore.event(withIdentifier: mirrorID) {
                do {
                    let span: EKSpan = mirrorEvent.hasRecurrenceRules ? .futureEvents : .thisEvent
                    try eventStore.remove(mirrorEvent, span: span, commit: false)
                    deleted += 1
                } catch {
                    print("[SyncEngine] Error removing mirror event: \(error.localizedDescription)")
                }
            }
            persistence.deleteMapping(mapping, in: context)
        }

        if created > 0 || updated > 0 || deleted > 0 {
            do {
                try eventStore.commit()
            } catch {
                print("[SyncEngine] ❌ EventKit commit failed: \(error.localizedDescription)")
            }
        }
        persistence.save(context: context)

        return SyncResult(created: created, updated: updated, deleted: deleted, skipped: skipped)
    }

    /// Deletes every event currently in `calendar` within `window`, without going through
    /// the diff (no mapping lookups) — used for the one-time legacy migration and for
    /// the explicit "Force Full Resync" repair path.
    private func wipeAllMirrorEvents(in calendar: EKCalendar, window: (start: Date, end: Date)) {
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        let events = eventStore.events(matching: predicate)
        guard !events.isEmpty else { return }

        for event in events {
            do {
                let span: EKSpan = event.hasRecurrenceRules ? .futureEvents : .thisEvent
                try eventStore.remove(event, span: span, commit: false)
            } catch {
                print("[SyncEngine] Error wiping mirror event: \(error.localizedDescription)")
            }
        }

        do {
            try eventStore.commit()
            print("[SyncEngine] 🧹 Wiped \(events.count) mirror event(s)")
        } catch {
            print("[SyncEngine] ❌ Error committing wipe: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Operations

    /// Creates a new event in the Mirror calendar (uncommitted — caller batches the commit).
    /// - Returns: The mirror event's local identifier, or nil on failure.
    private func createMirrorEvent(for sourceEvent: EKEvent, in calendar: EKCalendar) -> String? {
        let mirrorEvent = EKEvent(eventStore: eventStore)
        copyEventProperties(from: sourceEvent, to: mirrorEvent)
        mirrorEvent.calendar = calendar

        do {
            try eventStore.save(mirrorEvent, span: .thisEvent, commit: false)
            return mirrorEvent.calendarItemIdentifier
        } catch {
            print("[SyncEngine] Error creating mirror event: \(error.localizedDescription)")
            return nil
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

        // Note: We intentionally do NOT copy:
        // - attendees (they belong to the source event)
        // - recurrence rules (each occurrence is mirrored individually)
        // - calendar (we set this to the mirror calendar)
    }

    // MARK: - Identity & Hashing

    // Only ever read from `syncQueue`, which serializes all sync work — safe despite
    // ISO8601DateFormatter not being Sendable (same reasoning as the debounce timestamp
    // this class used to keep as `nonisolated(unsafe)`).
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// A stable key identifying one source *occurrence*.
    ///
    /// `calendarItemIdentifier`/`calendarItemExternalIdentifier` identify the calendar
    /// item (the whole recurring series), not a specific occurrence — a query over a date
    /// range returns the same identifier for every occurrence of a series. The start date
    /// is included so each occurrence gets its own mapping instead of collapsing onto one.
    ///
    /// `calendarItemExternalIdentifier` (stable across devices/iCloud resyncs) is preferred;
    /// it can be nil for events on a purely local ("On My Mac") calendar, in which case we
    /// fall back to `calendarItemIdentifier`.
    private static func sourceKey(for event: EKEvent) -> String {
        let stableID = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        return "\(stableID)|\(iso8601Formatter.string(from: event.startDate))"
    }

    /// Calculates a hash for an event based on its key properties.
    /// Used for change detection without needing to compare all fields.
    ///
    /// Properties included in hash:
    /// - Title
    /// - Start date (ISO8601)
    /// - End date (ISO8601)
    /// - Location
    /// - All-day flag
    /// - Notes
    ///
    /// - Parameter event: The event to hash.
    /// - Returns: A SHA256 hash string.
    static func calculateHash(for event: EKEvent) -> String {
        let formatter = iso8601Formatter

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
