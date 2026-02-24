//
//  PermissionsManager_iOS.swift
//  MirrorCal-iOS
//

import UIKit
import EventKit
import Foundation

@MainActor
final class PermissionsManager_iOS {
    let eventStore: EKEventStore
    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }
    
    func currentAuthorizationStatus() -> EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }
    
    func requestFullAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return try await eventStore.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }
}
