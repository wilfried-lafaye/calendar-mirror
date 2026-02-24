# MirrorCal

MirrorCal is a native Apple application (available for **macOS** and **iOS**) that allows you to seamlessly synchronize and mirror events from multiple source calendars into a single destination calendar.

It is perfect for combining professional, personal, and family calendars into one unified view without mixing accounts.

## Features

- **Multi-Source Synchronization**: Select multiple calendars (iCloud, Google, Exchange, Outlook, Local) to mirror events from.
- **Unified Destination**: Choose a single destination calendar where all copied events will reside.
- **Smart Update Detection**: Uses SHA256 hashing to detect changes. Only modified events are updated.
- **Recurrence Support**: Properly handles recurring events and deletions.
- **Safe Deletion & Sweeping**: Includes mechanisms to clean up orphaned events safely.
- **Local & Private**: MirrorCal operates entirely on your device via the native EventKit framework. No server, no data collection.
- **Cross-Platform**: Includes both a lightweight macOS menu bar app and a full iOS application.

## Project Structure (Monorepo)

This repository is structured as a monorepo containing both the macOS and iOS applications, sharing core data models.

```text
calendar-mirror/
├── Shared/                 # Shared resources (CoreData models, etc)
├── MirrorCal/              # macOS Application (Menu Bar app)
│   ├── MirrorCalApp.swift  
│   └── ...
├── MirrorCal-iOS/          # iOS Application
│   ├── MirrorCal_iOSApp.swift
│   └── ...
├── README.md               # This file
└── privacy.html            # Privacy Policy (hosted on GitHub Pages)
```

## Requirements

- **macOS App**: macOS 15.0+
- **iOS App**: iOS 17.0+
- Xcode 16.0+

## Privacy Policy

MirrorCal respects your privacy. It does not collect or transmit any calendar data off your device. 

Read the full [Privacy Policy](https://wilfried-lafaye.github.io/calendar-mirror/privacy.html).

## How it works

1. Open MirrorCal and grant Calendar access.
2. Select the **Source Calendars** you want to mirror.
3. Select your **Destination Calendar** (we recommend creating an empty local calendar specifically for this).
4. Set the **Synchronization Period** (e.g., from today to +7 days).
5. Click **Sync Now**.

MirrorCal will read the events from your sources and create identical copies in the destination calendar. If an event is updated or deleted in the source, the change will be reflected in the destination upon the next sync.

## License

This project is tailored for personal use.
