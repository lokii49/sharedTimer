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

Five app targets share one data model by **file duplication**, not a shared framework/package:

- `sharedTimer/` — main app (list of timers, create/pause/resume/extend/delete)
- `sharedTimerClip/` — App Clip, opened via the `t.html` share link; shows a single live countdown
- `sharedTimerMessages/` — iMessage extension; compose-and-share sheet plus a running view shown when a shared link/card is opened inside Messages
- `sharedTimerWidget/` — WidgetKit extension: home-screen widget (`SharedTimerWidget.swift`) + Live Activity / Dynamic Island (`TimerLiveActivityWidget.swift`), bundled via `SharedTimerWidgetBundle`
- `sharedTimerWatch Watch App/` — watchOS companion app, embedded in `sharedTimer`. Thin `WatchConnectivity` mirror, not a peer — see "Watch app" below.

`TimerModel.swift`, `TimerStore.swift`, `NotificationScheduler.swift`, `TimerActivityAttributes.swift`, `LiveActivityController.swift`, `TimerFieldsView.swift`, `Sky.swift`, `CloudLink.swift`, `CloudSyncController.swift`, and `DisplayNameStore.swift` are copy-pasted verbatim (only the file-header comment differs) into whichever targets need them — the last three only into `sharedTimer`/`sharedTimerMessages` (the two targets that mutate a shared timer a person is looking at), not into `sharedTimerClip`/`sharedTimerWidget`/the watch app. **When changing shared logic, apply the same edit to every copy** — check with `diff` across targets before considering a change done. `sharedTimerWatch Watch App` only carries `TimerModel.swift` (no `TimerStore`/`NotificationScheduler`/`LiveActivityController` — see "Watch app" below), so include it in `TimerModel.swift` diffs only:

```
diff sharedTimer/TimerModel.swift sharedTimerClip/TimerModel.swift
diff sharedTimer/TimerModel.swift sharedTimerWidget/TimerModel.swift
diff sharedTimer/TimerModel.swift sharedTimerMessages/TimerModel.swift
diff sharedTimer/TimerModel.swift "sharedTimerWatch Watch App/TimerModel.swift"
```

### Core model (`TimerModel.swift`)

- `TimerPayload` — the one data type for both timer and countdown modes (`TimerKind`). Holds `endDate`, `duration`, optional `pausedRemaining` (non-nil = paused). `remaining`, `isExpired`, `progress(at:)`, `paused()`, `resumed()`, `extended(by:)` are all pure, date-parameterized functions — no wall-clock reads except through the `at:`/default-`Date()` args, which keeps them usable inside `TimelineView`.
- `TimerPayload.url()` / `.from(url:)` encode/decode a payload into query params on `https://lokii49.github.io/sharedTimer/t.html` — this is the link shared in Messages and opened by the App Clip. Changing the payload's wire fields requires updating `docs/t.html`'s JS parsing (`qs(...)` calls) in lockstep.
- `TimeFormat` — day-aware duration formatting (`3d 04:12:09` / `4:12:09` / `12:09`) shared by every surface; also duplicated in `docs/t.html`'s `formatRemaining`/`formatTargetDate` JS.

### Persistence & cross-target sync

`TimerStore` reads/writes an array of `TimerPayload` as JSON in `UserDefaults(suiteName: "group.com.lokesh.sharedTimer")` — the App Group is what lets the main app, Messages extension, App Clip, and widget all see the same timers. Every target's entitlements file must list that same group ID. `TimerStore.persist` prunes payloads that are non-paused and expired more than 24h ago.

### Notifications & Live Activities

`NotificationScheduler` and `LiveActivityController` are invoked together at every mutation point (create, pause/resume, extend, delete) across all four targets — grep call sites in `ContentView.swift`, `MessagesViewController.swift`, `sharedTimerClip/ContentView.swift`, and `TimerIntents.swift` (Siri/Shortcuts creation) before changing the mutation flow, since each surface reimplements the same "save → cancel old notification → reschedule → update/start/end Live Activity" sequence independently rather than through one shared coordinator.

### Home Screen Quick Actions (`SceneDelegate.swift`, `Shortcuts.plist`)

Long-press app icon → New Timer / New Countdown. Static `UIApplicationShortcutItems` merged into the generated Info.plist via `Shortcuts.plist` + `INFOPLIST_FILE` (kept alongside `GENERATE_INFOPLIST_FILE = YES`). Routes through `ContentView`'s `.quickActionTriggered` notification (warm launch) or `SceneDelegate.pendingShortcutType` drained in `.onAppear` (cold launch — `willConnectTo` runs before the notification subscriber exists).

### Watch app (`WatchSyncController.swift`, both sides)

App Groups do **not** sync between an iPhone and its paired Watch (separate devices, separate
container filesystems) — verified against Apple's own guidance, not assumed. So the watch app
is not a fifth `TimerStore` reader; it's a thin `WatchConnectivity` mirror of whatever
`sharedTimer/WatchSyncController.swift` last pushed via `updateApplicationContext`. Mutations
made on the watch relay back to the phone as a `WCSession` message and are applied there
through the exact same `TimerStore`/`NotificationScheduler`/`LiveActivityController`/
`CloudSyncController.pushUp` sequence every other surface uses — the watch target itself never
touches any of those (ActivityKit isn't even available on watchOS), and doesn't carry
`TimerStore.swift`/`NotificationScheduler.swift`/`LiveActivityController.swift`/
`CloudSyncController.swift` at all. `WatchSyncController.pushCurrentState()` (phone side) is
called explicitly at every `TimerStore`-mutating point in `ContentView.swift` and
`AppDelegate.swift` — same "explicit call at each mutation site, never automatic" invariant
`CloudSyncController.swift`'s own header documents, for the same reason (this file, too, must
never be reachable from `TimerStore.swift` itself).

### Web fallback (`docs/t.html`)

Static page (served via GitHub Pages, per the hardcoded host in `TimerPayload.url()`) that renders a live countdown from URL query params alone, for recipients without the app. Keep its param names and formatting logic in sync with `TimerModel.swift` by hand — there's no code sharing between Swift and this JS.
