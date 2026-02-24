//
//  MainView_iOS.swift
//  MirrorCal-iOS
//

import SwiftUI
import EventKit

struct MainView_iOS: View {
    @State private var isSyncing = false
    @State private var lastSyncResult: String?
    @State private var lastSyncTime: Date? = UserDefaults.standard.object(forKey: "LastSyncTime") as? Date
    @State private var sourceCount: Int = UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs")?.count ?? 0
    @State private var destinationName: String = "Not set"
    @State private var showSettings = false
    
    @State private var syncEngine: SyncEngine_iOS?
    private let eventStore = EKEventStore()
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                
                VStack(spacing: 25) {
                    // Status Card
                    VStack(spacing: 15) {
                        Image(systemName: isSyncing ? "arrow.triangle.2.circlepath" : "calendar.badge.checkmark")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                            .symbolEffect(.rotate, isActive: isSyncing)
                        
                        Text(isSyncing ? "Syncing..." : "Ready to Mirror")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        if let result = lastSyncResult {
                            Text(result)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(result.contains("Error") ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                                .cornerRadius(8)
                        }
                        
                        if let lastSync = lastSyncTime {
                            Text("Last sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(40)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(25)
                    .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
                    
                    // Sync Button
                    Button(action: performManualSync) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Sync Now")
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(isSyncing ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    .disabled(isSyncing)
                    .padding(.horizontal, 40)
                    
                    // Settings Button (always visible)
                    Button(action: { showSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure Calendars")
                                .fontWeight(.medium)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(15)
                    }
                    .padding(.horizontal, 40)
                    
                    // Quick Stats
                    HStack(spacing: 20) {
                        StatView_iOS(title: "Source", value: "\(sourceCount) Cal.", icon: "arrow.right.circle")
                        StatView_iOS(title: "Destination", value: destinationName, icon: "target")
                    }
                    .padding(.horizontal, 40)
                    
                    Spacer()
                }
                .padding(.top, 20)
            }
            .navigationTitle("MirrorCal")
            .navigationDestination(isPresented: $showSettings) {
                SettingsView_iOS()
            }
            .onAppear(perform: refreshStats)
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                // Auto-sync when calendar data changes (like macOS)
                guard let engine = syncEngine, engine.shouldRespondToCalendarChange() else { return }
                performManualSync()
            }
        }
    }
    
    private func refreshStats() {
        sourceCount = UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs")?.count ?? 0
        if let destID = UserDefaults.standard.string(forKey: "destinationCalendarID"),
           !destID.isEmpty,
           let cal = eventStore.calendar(withIdentifier: destID) {
            destinationName = cal.title
        } else {
            destinationName = "Not set"
        }
        
        // Keep a sync engine alive for auto-sync
        if syncEngine == nil {
            let engine = SyncEngine_iOS()
            let sourceIDs = Set(UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs") ?? [])
            engine.setSourceCalendars(sourceIDs)
            syncEngine = engine
        }
    }
    
    private func performManualSync() {
        let sourceIDs = Set(UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs") ?? [])
        
        let engine = SyncEngine_iOS()
        engine.setSourceCalendars(sourceIDs)
        syncEngine = engine
        
        withAnimation { isSyncing = true }
        
        engine.performSync { result in
            withAnimation {
                isSyncing = false
                switch result {
                case .success(let syncResult):
                    lastSyncResult = "✅ \(syncResult.description)"
                    lastSyncTime = Date()
                    UserDefaults.standard.set(lastSyncTime, forKey: "LastSyncTime")
                case .failure(let error):
                    lastSyncResult = "❌ Error: \(error.localizedDescription)"
                }
                refreshStats()
            }
        }
    }
}

struct StatView_iOS: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(15)
    }
}
