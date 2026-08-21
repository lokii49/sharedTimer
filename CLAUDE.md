# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

SharedTimer — iOS SwiftUI app for timers and date countdowns that can be shared via iMessage. Xcode project at `sharedTimer/sharedTimer.xcodeproj`. No SPM packages, no CocoaPods — pure Xcode targets.

## Build / test / run

Requires Xcode + a Mac. From `sharedTimer/`:

```
xcodebuild -project sharedTimer.xcodeproj -list          # list targets/schemes
xcodebuild -scheme sharedTimer -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme sharedTimer -destination 'platform=iOS Simulator,name=iPhone 16' test
xcodebuild -scheme sharedTimer -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:sharedTimerUITests/sharedTimerUITests/testExample test
```

Schemes: `sharedTimer` (main app), `sharedTimerClip` (App Clip), `sharedTimerMessages` (iMessage extension), `sharedTimerWidget` (widget/Live Activity — embedded, not independently runnable). Prefer opening the project in Xcode and running on a simulator/device for anything involving notifications, Live Activities, or the Messages extension — those don't function meaningfully under plain `xcodebuild test`.

`sharedTimerTests` and `sharedTimerClipTests` are empty boilerplate (no test methods). `sharedTimerUITests` has the two default launch tests only. There is no meaningful automated test coverage right now — verify behavior manually in the simulator.

## Architecture

Four app targets share one data model by **file duplication**, not a shared framework/package:

- `sharedTimer/` — main app (list of timers, create/pause/resume/extend/delete)
- `sharedTimerClip/` — App Clip, opened via the `t.html` share link; shows a single live countdown
- `sharedTimerMessages/` — iMessage extension; compose-and-share sheet plus a running view shown when a shared link/card is opened inside Messages
- `sharedTimerWidget/` — WidgetKit extension: home-screen widget (`SharedTimerWidget.swift`) + Live Activity / Dynamic Island (`TimerLiveActivityWidget.swift`), bundled via `SharedTimerWidgetBundle`

`TimerModel.swift`, `TimerStore.swift`, `NotificationScheduler.swift`, `TimerActivityAttributes.swift`, `LiveActivityController.swift`, and `TimerFieldsView.swift` are copy-pasted verbatim (only the file-header comment differs) into whichever targets need them. **When changing shared logic, apply the same edit to every copy** — check with `diff` across targets before considering a change done:

```
diff sharedTimer/TimerModel.swift sharedTimerClip/TimerModel.swift
diff sharedTimer/TimerModel.swift sharedTimerWidget/TimerModel.swift
diff sharedTimer/TimerModel.swift sharedTimerMessages/TimerModel.swift
```

### Core model (`TimerModel.swift`)

- `TimerPayload` — the one data type for both timer and countdown modes (`TimerKind`). Holds `endDate`, `duration`, optional `pausedRemaining` (non-nil = paused). `remaining`, `isExpired`, `progress(at:)`, `paused()`, `resumed()`, `extended(by:)` are all pure, date-parameterized functions — no wall-clock reads except through the `at:`/default-`Date()` args, which keeps them usable inside `TimelineView`.
- `TimerPayload.url()` / `.from(url:)` encode/decode a payload into query params on `https://lokii49.github.io/sharedTimer/t.html` — this is the link shared in Messages and opened by the App Clip. Changing the payload's wire fields requires updating `docs/t.html`'s JS parsing (`qs(...)` calls) in lockstep.
- `TimeFormat` — day-aware duration formatting (`3d 04:12:09` / `4:12:09` / `12:09`) shared by every surface; also duplicated in `docs/t.html`'s `formatRemaining`/`formatTargetDate` JS.

### Persistence & cross-target sync

`TimerStore` reads/writes an array of `TimerPayload` as JSON in `UserDefaults(suiteName: "group.com.lokesh.sharedTimer")` — the App Group is what lets the main app, Messages extension, App Clip, and widget all see the same timers. Every target's entitlements file must list that same group ID. `TimerStore.persist` prunes payloads that are non-paused and expired more than 24h ago.

### Notifications & Live Activities

`NotificationScheduler` and `LiveActivityController` are invoked together at every mutation point (create, pause/resume, extend, delete) across all four targets — grep call sites in `ContentView.swift`, `MessagesViewController.swift`, and `sharedTimerClip/ContentView.swift` before changing the mutation flow, since each surface reimplements the same "save → cancel old notification → reschedule → update/start/end Live Activity" sequence independently rather than through one shared coordinator.

### Web fallback (`docs/t.html`)

Static page (served via GitHub Pages, per the hardcoded host in `TimerPayload.url()`) that renders a live countdown from URL query params alone, for recipients without the app. Keep its param names and formatting logic in sync with `TimerModel.swift` by hand — there's no code sharing between Swift and this JS.
