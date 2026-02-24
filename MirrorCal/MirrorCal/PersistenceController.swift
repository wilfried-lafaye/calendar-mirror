//
//  PersistenceController.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import CoreData
import Foundation

/// Manages the CoreData stack for MirrorCal.
/// This controller handles all persistent storage for event mappings between
/// source calendars and the mirror calendar.
///
/// ## Thread Safety
/// - Use `viewContext` for Main Thread (UI) operations only
/// - Use `performBackgroundTask` for all sync operations
///
final class PersistenceController: @unchecked Sendable {
    
    // MARK: - Singleton
    
    /// Shared instance for the app's persistence layer
    static let shared = PersistenceController()
    
    /// Preview instance for SwiftUI previews with in-memory store
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        // Add sample data for previews if needed
        return controller
    }()
    
    // MARK: - Properties
    
    /// The CoreData persistent container
    let container: NSPersistentContainer
    
    /// Main thread context for UI operations
    var viewContext: NSManagedObjectContext {
        container.viewContext
    }
    
    // MARK: - Initialization
    
    /// Initialize the persistence controller
    /// - Parameter inMemory: If true, uses an in-memory store (for previews/testing)
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "MirrorCal")
        
        if inMemory {
            // Use in-memory store for previews and tests
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        
        // Configure the container
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                // In production, handle this more gracefully
                // For now, we crash as the app cannot function without CoreData
                fatalError("[PersistenceController] Failed to load CoreData: \(error), \(error.userInfo)")
            }
            
            print("[PersistenceController] Loaded store: \(description.url?.absoluteString ?? "unknown")")
        }
        
        // Configure view context
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }
    
    // MARK: - Background Context
    
    /// Creates a new background context for async operations.
    /// Always use this for sync operations to avoid blocking the Main Thread.
    /// - Returns: A new `NSManagedObjectContext` configured for background use.
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }
    
    /// Performs a block on a background context.
    /// - Parameter block: The work to perform on the background context.
    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }
    
    // MARK: - Save
    
    /// Saves the view context if there are changes.
    /// Call this after making changes on the main thread.
    func saveViewContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("[PersistenceController] Error saving viewContext: \(nsError), \(nsError.userInfo)")
            }
        }
    }
    
    /// Saves a given context if there are changes.
    /// - Parameter context: The context to save.
    func save(context: NSManagedObjectContext) {
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("[PersistenceController] Error saving context: \(nsError), \(nsError.userInfo)")
            }
        }
    }
    
    // MARK: - EventMapping Queries
    
    /// Fetches an EventMapping by its source event's external identifier.
    /// This is an indexed lookup for optimal performance.
    ///
    /// - Parameters:
    ///   - sourceID: The `calendarItemExternalIdentifier` of the source event.
    ///   - context: The context to fetch from. Defaults to `viewContext`.
    /// - Returns: The matching `EventMapping` or `nil` if not found.
    func fetchMapping(forSourceID sourceID: String, in context: NSManagedObjectContext? = nil) -> EventMapping? {
        let ctx = context ?? viewContext
        let request = EventMapping.fetchRequest()
        request.predicate = NSPredicate(format: "sourceID == %@", sourceID)
        request.fetchLimit = 1
        
        do {
            let results = try ctx.fetch(request)
            return results.first
        } catch {
            print("[PersistenceController] Error fetching mapping for sourceID \(sourceID): \(error)")
            return nil
        }
    }
    
    /// Fetches an EventMapping by its mirror event's external identifier.
    ///
    /// - Parameters:
    ///   - mirrorID: The `calendarItemExternalIdentifier` of the mirror event.
    ///   - context: The context to fetch from. Defaults to `viewContext`.
    /// - Returns: The matching `EventMapping` or `nil` if not found.
    func fetchMapping(forMirrorID mirrorID: String, in context: NSManagedObjectContext? = nil) -> EventMapping? {
        let ctx = context ?? viewContext
        let request = EventMapping.fetchRequest()
        request.predicate = NSPredicate(format: "mirrorID == %@", mirrorID)
        request.fetchLimit = 1
        
        do {
            let results = try ctx.fetch(request)
            return results.first
        } catch {
            print("[PersistenceController] Error fetching mapping for mirrorID \(mirrorID): \(error)")
            return nil
        }
    }
    
    /// Fetches all EventMappings for a specific source calendar.
    ///
    /// - Parameters:
    ///   - calendarID: The `calendarIdentifier` of the source calendar.
    ///   - context: The context to fetch from. Defaults to `viewContext`.
    /// - Returns: Array of `EventMapping` objects for that calendar.
    func fetchMappings(forCalendarID calendarID: String, in context: NSManagedObjectContext? = nil) -> [EventMapping] {
        let ctx = context ?? viewContext
        let request = EventMapping.fetchRequest()
        request.predicate = NSPredicate(format: "sourceCalendarID == %@", calendarID)
        
        do {
            return try ctx.fetch(request)
        } catch {
            print("[PersistenceController] Error fetching mappings for calendar \(calendarID): \(error)")
            return []
        }
    }
    
    /// Fetches all EventMappings.
    ///
    /// - Parameter context: The context to fetch from. Defaults to `viewContext`.
    /// - Returns: Array of all `EventMapping` objects.
    func fetchAllMappings(in context: NSManagedObjectContext? = nil) -> [EventMapping] {
        let ctx = context ?? viewContext
        let request = EventMapping.fetchRequest()
        
        do {
            return try ctx.fetch(request)
        } catch {
            print("[PersistenceController] Error fetching all mappings: \(error)")
            return []
        }
    }
    
    // MARK: - EventMapping Creation
    
    /// Creates a new EventMapping in the specified context.
    ///
    /// - Parameters:
    ///   - sourceID: The source event's `calendarItemExternalIdentifier`.
    ///   - mirrorID: The mirror event's `calendarItemExternalIdentifier`.
    ///   - hash: The hash of the source event's content for change detection.
    ///   - calendarID: The source calendar's identifier.
    ///   - context: The context to create in. Defaults to `viewContext`.
    /// - Returns: The newly created `EventMapping`.
    @discardableResult
    func createMapping(
        sourceID: String,
        mirrorID: String,
        hash: String,
        calendarID: String,
        in context: NSManagedObjectContext? = nil
    ) -> EventMapping {
        let ctx = context ?? viewContext
        let mapping = EventMapping(context: ctx)
        mapping.sourceID = sourceID
        mapping.mirrorID = mirrorID
        mapping.lastKnownHash = hash
        mapping.sourceCalendarID = calendarID
        return mapping
    }
    
    // MARK: - Deletion
    
    /// Deletes an EventMapping.
    ///
    /// - Parameters:
    ///   - mapping: The mapping to delete.
    ///   - context: The context to delete from. Uses the mapping's context if nil.
    func deleteMapping(_ mapping: EventMapping, in context: NSManagedObjectContext? = nil) {
        let ctx = context ?? mapping.managedObjectContext ?? viewContext
        ctx.delete(mapping)
    }
    
    /// Deletes all mappings for a specific source calendar.
    ///
    /// - Parameters:
    ///   - calendarID: The calendar identifier to delete mappings for.
    ///   - context: The context to delete from.
    func deleteMappings(forCalendarID calendarID: String, in context: NSManagedObjectContext? = nil) {
        let mappings = fetchMappings(forCalendarID: calendarID, in: context)
        let ctx = context ?? viewContext
        for mapping in mappings {
            ctx.delete(mapping)
        }
    }
}
