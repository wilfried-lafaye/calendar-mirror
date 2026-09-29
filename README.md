# MirrorCal

MirrorCal is a native Apple application (available for **macOS** and **iOS**) that allows you to seamlessly synchronize and mirror events from multiple source calendars into a single destination calendar.

It is perfect for combining professional, personal, and family calendars into one unified view without mixing accounts.

## Features

- **Multi-Source Synchronization**: Select multiple calendars (iCloud, Google, Exchange, Outlook, Local) to mirror events from.
- **Unified Destination**: Choose a single destination calendar where all copied events will reside.
- **Automatic Sync (macOS)**: MirrorCal listens to calendar changes and mirrors them within seconds, with a catch-up sync at launch. There is no date range to pick: the window is recalculated at every sync (from 90 days in the past to 3 years ahead). An optional *Launch at Login* keeps it running.
- **Smart Incremental Sync (macOS)**: Each mirrored event is tracked in a local mapping and compared with a SHA256 hash. Only created, modified or deleted events are written, and a sync with no change writes nothing. *Force Full Resync* is available as a repair option.
- **Recurrence Support**: Properly handles recurring events and deletions.
- **Safe Deletion & Sweeping**: Includes mechanisms to clean up orphaned events safely.
- **Shortcuts & Siri**: A "refresh calendars" action (App Intents) on macOS and iOS, usable from the Shortcuts app, Siri and Automations.
- **Local & Private**: MirrorCal operates entirely on your device via the native EventKit framework. No server, no data collection.
- **Cross-Platform**: Includes both a lightweight macOS menu bar app and a full iOS application.

### macOS vs iOS

| | macOS (menu bar app) | iOS |
|---|---|---|
| Trigger | Automatic (calendar changes, launch) + **Sync Now** (⌘R) | **Sync Now** button, and automatically on calendar changes while the app is open |
| Sync period | Automatic rolling window (-90 days / +3 years) | Set by you (*From* / *To*), by default the current week |
| Update strategy | Incremental (create / update / skip / delete) | The mirrored events of the period are deleted and recreated at each sync |
| Shortcuts / Siri | Yes | Yes |

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
├── install.sh              # Builds the macOS app (Release) and installs it in /Applications
├── README.md               # This file
└── privacy.html            # Privacy Policy (hosted on GitHub Pages)
```

## Requirements

- **macOS App**: macOS 15.0+
- **iOS App**: iOS 17.0+
- Xcode 16.0+

## Installation (macOS)

Clone the repository and run the install script. It builds the app in Release mode with `xcodebuild` and copies `MirrorCal.app` into `/Applications`:

```bash
./install.sh
```

The iOS app is built and run from Xcode (`MirrorCal-iOS/MirrorCal_iOS.xcodeproj`).

## Privacy Policy

MirrorCal respects your privacy. It does not collect or transmit any calendar data off your device. 

Read the full [Privacy Policy](https://wilfried-lafaye.github.io/calendar-mirror/privacy.html).

## How it works

1. Open MirrorCal and grant Calendar access.
2. Select the **Source Calendars** you want to mirror.
3. Select your **Destination Calendar** (we recommend creating an empty local calendar specifically for this).

Then:

- **macOS**: nothing else to do. MirrorCal syncs at launch and each time a source calendar changes. You can also trigger a sync with **Sync Now** (⌘R in the menu bar, or in Settings).
- **iOS**: set the **Synchronization Period** (*From* / *To*, by default the current week), then tap **Sync Now**. While the app is open, it also re-syncs when your calendars change.

MirrorCal reads the events from your sources and creates identical copies in the destination calendar. If an event is updated or deleted in the source, the change is reflected in the destination at the next sync.

## AI Assistance

This project was developed with the help of an AI coding assistant, **Claude** (Anthropic), notably for the macOS automatic synchronization engine and the Shortcuts / App Intents support. This is also visible in the commit history (`Co-Authored-By` trailers).

## License

This project is tailored for personal use.
