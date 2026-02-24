//
//  PersistenceController_iOS.swift
//  MirrorCal-iOS
//

import CoreData
import Foundation

final class PersistenceController_iOS: @unchecked Sendable {
    static let shared = PersistenceController_iOS()
    
    let container: NSPersistentContainer
    var viewContext: NSManagedObjectContext { container.viewContext }
    
    static let preview: PersistenceController_iOS = {
        let controller = PersistenceController_iOS(inMemory: true)
        return controller
    }()
    
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "MirrorCal")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }
}
