//
//  SettingsView.swift
//  MirrorCal
//
//  Created by MirrorCal Team
//

import SwiftUI
import EventKit

/// Settings view for MirrorCal.
/// Allows users to select which calendars to mirror and trigger manual sync.
struct SettingsView: View {
    
    @StateObject private var viewModel = CalendarSelectionViewModel()
    @State private var isSyncing = false
    @State private var lastSyncResult: String?
    
    /// Keep SyncEngine alive during async operations
    @State private var syncEngine: SyncEngine?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content based on authorization status
            switch viewModel.authorizationStatus {
            case .fullAccess:
                calendarListView
            case .notDetermined:
                requestAccessView
            case .denied, .restricted:
                deniedAccessView
            case .writeOnly:
                writeOnlyAccessView
            @unknown default:
                unknownStatusView
            }
            
            Divider()
            
            // Sync Configuration
            syncConfigurationView
            
            Divider()
            
            // Footer with sync button
            footerView
        }
        .frame(minWidth: 450, idealWidth: 450, minHeight: 600, idealHeight: 600)
        .task {
            await viewModel.loadCalendars()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28))
                .foregroundStyle(.purple)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("MirrorCal")
                    .font(.headline)
                Text("Select calendars to mirror")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Selection summary
            if !viewModel.calendarGroups.isEmpty {
                Text("\(viewModel.selectedCalendarIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
        .padding()
    }

    // MARK: - Sync Configuration
    
    private var syncConfigurationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Destination Calendar Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Destination Calendar")
                    .font(.headline)
                
                if viewModel.allWritableCalendars.isEmpty {
                    Text("Loading calendars...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Picker("Select destination", selection: $viewModel.destinationCalendarID) {
                        Text("-- Select a calendar --").tag("")
                        ForEach(viewModel.allWritableCalendars, id: \.calendarIdentifier) { calendar in
                            HStack {
                                Circle()
                                    .fill(calendar.swiftUIColor)
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                            }
                            .tag(calendar.calendarIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if viewModel.destinationCalendarID.isEmpty {
                        Label("Please select a destination calendar", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
            
            Divider()
            
            // Sync Period
            Text("Synchronization Period")
                .font(.headline)
            
            HStack(alignment: .top, spacing: 20) {
                // Start Date Picker
                VStack(alignment: .leading, spacing: 8) {
                    Label("From", systemImage: "arrow.right.circle")
                        .foregroundStyle(.blue)
                        .font(.subheadline)
                    
                    DatePicker(
                        "Start Date",
                        selection: $viewModel.syncStartDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
                
                // Arrow separator
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 32)
                
                // End Date Picker
                VStack(alignment: .leading, spacing: 8) {
                    Label("To", systemImage: "arrow.left.circle")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    
                    DatePicker(
                        "End Date",
                        selection: $viewModel.syncEndDate,
                        in: viewModel.syncStartDate...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
            }
            .frame(maxWidth: .infinity)
            
            // Period summary
            Text("Events between \(formattedDate(viewModel.syncStartDate)) and \(formattedDate(viewModel.syncEndDate)) will be synced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Calendar List
    
    private var calendarListView: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading calendars...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.calendarGroups.isEmpty {
                ContentUnavailableView(
                    "No Calendars",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("No calendars are available to mirror.")
                )
            } else {
                List {
                    ForEach(viewModel.calendarGroups) { group in
                        Section {
                            ForEach(group.calendars) { calendar in
                                CalendarRowView(
                                    calendar: calendar,
                                    isSelected: viewModel.isSelected(calendar.calendarIdentifier),
                                    onToggle: {
                                        viewModel.toggleSelection(for: calendar.calendarIdentifier)
                                    }
                                )
                            }
                        } header: {
                            HStack {
                                Image(systemName: sourceIcon(for: group.sourceName))
                                    .foregroundStyle(.secondary)
                                    Text(group.sourceName)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
    
    // MARK: - Permission States
    
    private var requestAccessView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("Calendar Access Required")
                .font(.headline)
            
            Text("MirrorCal needs access to your calendars to mirror events.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button("Grant Access") {
                Task {
                    await viewModel.loadCalendars()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var deniedAccessView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            
            Text("Calendar Access Denied")
                .font(.headline)
            
            Text("Please enable calendar access in System Settings to use MirrorCal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button("Open System Settings") {
                viewModel.openPrivacySettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var writeOnlyAccessView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("Full Access Required")
                .font(.headline)
            
            Text("MirrorCal has write-only access. Please grant full access in System Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button("Open System Settings") {
                viewModel.openPrivacySettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var unknownStatusView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.gray)
            
            Text("Unknown Status")
                .font(.headline)
            
            Button("Retry") {
                Task {
                    await viewModel.loadCalendars()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            // Quick actions
            Menu {
                Button("Select All") {
                    viewModel.selectAll()
                }
                Button("Deselect All") {
                    viewModel.deselectAll()
                }
                Divider()
                Button("Refresh Calendars") {
                    Task {
                        await viewModel.loadCalendars()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            Spacer()
            
            // Last sync result
            if let result = lastSyncResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Sync button
            Button {
                performSync()
            } label: {
                HStack(spacing: 6) {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isSyncing ? "Syncing..." : "Sync Now")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSyncing || viewModel.selectedCalendarIDs.isEmpty)
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func performSync() {
        isSyncing = true
        lastSyncResult = nil
        
        // Create sync engine and keep reference alive via @State
        let engine = SyncEngine()
        engine.setSourceCalendars(viewModel.selectedCalendarIDs)
        
        // Configure sync window
        engine.startDate = viewModel.syncStartDate
        engine.endDate = viewModel.syncEndDate
        
        self.syncEngine = engine
        
        engine.performSync { [self] result in
            isSyncing = false
            switch result {
            case .success(let syncResult):
                lastSyncResult = syncResult.description
            case .failure(let error):
                lastSyncResult = "Error: \(error.localizedDescription)"
            }
            // Clear the reference after completion
            syncEngine = nil
        }
    }
    
    // MARK: - Helpers
    
    private func sourceIcon(for sourceName: String) -> String {
        let lowercased = sourceName.lowercased()
        if lowercased.contains("icloud") {
            return "icloud"
        } else if lowercased.contains("exchange") || lowercased.contains("outlook") {
            return "envelope"
        } else if lowercased.contains("google") {
            return "g.circle"
        } else if lowercased.contains("local") || lowercased.contains("on my mac") {
            return "laptopcomputer"
        } else {
            return "calendar"
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Calendar Row View

struct CalendarRowView: View {
    let calendar: EKCalendar
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Color indicator
            Circle()
                .fill(calendar.swiftUIColor)
                .frame(width: 12, height: 12)
            
            // Calendar title
            Text(calendar.title)
                .lineLimit(1)
            
            Spacer()
            
            // Selection toggle
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
