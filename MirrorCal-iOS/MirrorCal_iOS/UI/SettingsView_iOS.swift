//
//  SettingsView_iOS.swift
//  MirrorCal-iOS
//

import SwiftUI
import EventKit

struct SettingsView_iOS: View {
    @State private var calendars: [EKCalendar] = []
    @State private var selectedSourceIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sourceCalendarIDs") ?? [])
    @State private var destinationCalendarID: String = UserDefaults.standard.string(forKey: "destinationCalendarID") ?? ""
    @State private var syncStartDate: Date = UserDefaults.standard.object(forKey: "syncStartDate") as? Date ?? Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
    @State private var syncEndDate: Date = {
        let start = UserDefaults.standard.object(forKey: "syncStartDate") as? Date ?? Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return UserDefaults.standard.object(forKey: "syncEndDate") as? Date ?? Calendar.current.date(byAdding: .day, value: 6, to: start)!
    }()
    @State private var isLoading = true
    @State private var permissionDenied = false
    @State private var writeOnlyAccess = false
    @State private var debugMessage = ""
    
    private let eventStore = EKEventStore()
    
    /// Grouped calendars by source
    private var calendarGroups: [(sourceName: String, calendars: [EKCalendar])] {
        let grouped = Dictionary(grouping: calendars) { $0.source.title }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (sourceName: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
    }
    
    var body: some View {
        Form {
            if permissionDenied {
                permissionDeniedSection
            } else if writeOnlyAccess {
                writeOnlySection
            } else {
                sourceCalendarsSection
                destinationSection
                syncPeriodSection
                
                // Selection summary
                if !calendars.isEmpty {
                    Section {
                        HStack {
                            Text("\(selectedSourceIDs.count) source(s) selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if destinationCalendarID.isEmpty {
                                Label("No destination", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Configuration")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select All") { selectAll() }
                    Button("Deselect All") { deselectAll() }
                    Divider()
                    Button("Refresh Calendars") { loadCalendars() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear(perform: loadCalendars)
        // Auto-save: persist changes whenever values change
        .onChange(of: selectedSourceIDs) { _ in autoSave() }
        .onChange(of: destinationCalendarID) { _ in autoSave() }
        .onChange(of: syncStartDate) { _ in autoSave() }
        .onChange(of: syncEndDate) { _ in autoSave() }
    }
    
    // MARK: - Permission States
    
    private var permissionDeniedSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                Text("Calendar Access Denied")
                    .font(.headline)
                Text("Please enable calendar access in Settings to use MirrorCal.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
    
    private var writeOnlySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text("Full Access Required")
                    .font(.headline)
                Text("MirrorCal has write-only access. Please grant full access in Settings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
    
    // MARK: - Source Calendars (grouped by source)
    
    private var sourceCalendarsSection: some View {
        Section(header: Text("Source Calendars"), footer: Text("Select the calendars you want to mirror events FROM.")) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading calendars...")
                    Spacer()
                }
            } else if calendars.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No calendars found")
                        .foregroundColor(.secondary)
                    if !debugMessage.isEmpty {
                        Text(debugMessage)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    Button("Try Again") { loadCalendars() }
                        .font(.caption)
                }
            } else {
                ForEach(calendarGroups, id: \.sourceName) { group in
                    Section(header: HStack {
                        Image(systemName: sourceIcon(for: group.sourceName))
                            .foregroundColor(.secondary)
                        Text(group.sourceName)
                    }) {
                        ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                                HStack {
                                    Circle()
                                        .fill(Color(calendar.cgColor))
                                        .frame(width: 12, height: 12)
                                    Text(calendar.title)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Destination Calendar
    
    private var destinationSection: some View {
        Section(header: Text("Destination Calendar"), footer: Text("All events in this calendar will be replaced by mirrored events.")) {
            Picker("Destination", selection: Binding(
                get: { calendars.isEmpty ? "" : destinationCalendarID },
                set: { destinationCalendarID = $0 }
            )) {
                Text("Select a calendar").tag("")
                ForEach(calendars.filter { $0.allowsContentModifications }, id: \.calendarIdentifier) { calendar in
                    HStack {
                        Circle()
                            .fill(Color(calendar.cgColor))
                            .frame(width: 12, height: 12)
                        Text("\(calendar.title) (\(calendar.source.title))")
                    }.tag(calendar.calendarIdentifier)
                }
            }
        }
    }
    
    // MARK: - Sync Period
    
    private var syncPeriodSection: some View {
        Section(header: Text("Synchronization Period"), footer: Text("Events between these dates will be synced.")) {
            DatePicker("From", selection: $syncStartDate, displayedComponents: .date)
            DatePicker("To", selection: $syncEndDate, in: syncStartDate..., displayedComponents: .date)
            
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("\(daysBetween()) days of events will be synced")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Actions
    
    private func selectAll() {
        selectedSourceIDs = Set(calendars.map { $0.calendarIdentifier })
    }
    
    private func deselectAll() {
        selectedSourceIDs.removeAll()
    }
    
    private func autoSave() {
        UserDefaults.standard.set(Array(selectedSourceIDs), forKey: "sourceCalendarIDs")
        UserDefaults.standard.set(destinationCalendarID, forKey: "destinationCalendarID")
        UserDefaults.standard.set(syncStartDate, forKey: "syncStartDate")
        UserDefaults.standard.set(syncEndDate, forKey: "syncEndDate")
    }
    
    // MARK: - Helpers
    
    private func daysBetween() -> Int {
        let components = Calendar.current.dateComponents([.day], from: syncStartDate, to: syncEndDate)
        return max(components.day ?? 0, 0)
    }
    
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedSourceIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedSourceIDs.insert(id)
                } else {
                    selectedSourceIDs.remove(id)
                }
            }
        )
    }
    
    private func sourceIcon(for sourceName: String) -> String {
        let lowercased = sourceName.lowercased()
        if lowercased.contains("icloud") { return "icloud" }
        else if lowercased.contains("exchange") || lowercased.contains("outlook") { return "envelope" }
        else if lowercased.contains("google") { return "g.circle" }
        else { return "calendar" }
    }
    
    private func loadCalendars() {
        isLoading = true
        permissionDenied = false
        writeOnlyAccess = false
        debugMessage = ""
        
        Task {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .notDetermined:
                do {
                    let granted: Bool
                    if #available(iOS 17.0, *) {
                        granted = try await eventStore.requestFullAccessToEvents()
                    } else {
                        granted = try await eventStore.requestAccess(to: .event)
                    }
                    if granted { redirectLoad() }
                    else { await MainActor.run { permissionDenied = true; isLoading = false } }
                } catch {
                    await MainActor.run { debugMessage = error.localizedDescription; permissionDenied = true; isLoading = false }
                }
            case .authorized, .fullAccess:
                redirectLoad()
            case .writeOnly:
                await MainActor.run { writeOnlyAccess = true; isLoading = false }
            default:
                await MainActor.run { permissionDenied = true; isLoading = false }
            }
        }
    }
    
    private func redirectLoad() {
        eventStore.refreshSourcesIfNecessary()
        let fetched = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
        Task { @MainActor in
            calendars = fetched
            isLoading = false
            if fetched.isEmpty { debugMessage = "Store returned 0 calendars despite access." }
            // Validate stored selection
            let validIDs = Set(fetched.map { $0.calendarIdentifier })
            if !destinationCalendarID.isEmpty && !validIDs.contains(destinationCalendarID) {
                destinationCalendarID = ""
            }
        }
    }
}
