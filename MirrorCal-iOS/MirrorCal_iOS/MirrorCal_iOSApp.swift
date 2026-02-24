//
//  MirrorCal_iOSApp.swift
//  MirrorCal-iOS
//

import SwiftUI

@main
struct MirrorCal_iOSApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    let persistenceController = PersistenceController_iOS.shared
    
    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                MainView_iOS()
                    .environment(\.managedObjectContext, persistenceController.viewContext)
            } else {
                OnboardingView_iOS(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
    }
}
