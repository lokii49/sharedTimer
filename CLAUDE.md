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

`AlarmPlayer.swift` (loops the bundled `alarm.caf` via `AVAudioPlayer` on a `.playback`-category session, so it ignores the silent switch like a native alarm) is the same verbatim-copy pattern, in `sharedTimer`/`sharedTimerMessages`/`sharedTimerClip` only — the three targets with a foreground countdown view and their own `NotificationScheduler.swift`. Each of those `NotificationScheduler.swift` copies also points `content.sound` at `alarm.caf` instead of `.default`, so a resting notification uses the same tone as the foreground loop:

```
diff sharedTimer/AlarmPlayer.swift sharedTimerMessages/AlarmPlayer.swift
diff sharedTimer/AlarmPlayer.swift sharedTimerClip/AlarmPlayer.swift
```

On iOS 26 a `.timer` finishing gets AlarmKit's own full-screen alert (foreground included), so `ContentView` only sounds the in-app `AlarmPlayer` loop when `AlarmController.shouldSoundInAppAlarm(for:)` is true: a `.countdown` (never AlarmKit), or a `.timer` with AlarmKit permission **not** granted. A `.timer` AlarmKit is handling never triggers the loop — deliberately keyed on auth state, not `AlarmManager.alarms` membership, because a stopped-from-the-panel alarm leaves the list and would otherwise re-bang the in-app loop the next time the app opens.

`TimerAlarmMetadata.swift` (the `AlarmMetadata` payload on an AlarmKit alarm) is a verbatim pair — `sharedTimer` (schedules the alarm) + `sharedTimerWidget` (renders its Live Activity):

```
diff sharedTimer/TimerAlarmMetadata.swift sharedTimerWidget/TimerAlarmMetadata.swift
```

### Core model (`TimerModel.swift`)

- `TimerPayload` — the one data type for both timer and countdown modes (`TimerKind`). Holds `endDate`, `duration`, optional `pausedRemaining` (non-nil = paused). `remaining`, `isExpired`, `progress(at:)`, `paused()`, `resumed()`, `extended(by:)` are all pure, date-parameterized functions — no wall-clock reads except through the `at:`/default-`Date()` args, which keeps them usable inside `TimelineView`.
- `TimerPayload.url()` / `.from(url:)` encode/decode a payload into query params on `https://lokii49.github.io/sharedTimer/t.html` — this is the link shared in Messages and opened by the App Clip. Wire params: `id`, `label`, `end`, `dur`, `kind`, `paused` (only if paused), `alarm` (only `alarm=0`, i.e. only when the alarm toggle is off). Changing the payload's wire fields requires updating `docs/t.html`'s JS parsing (`qs(...)` calls) in lockstep.
- `TimeFormat` — day-aware duration formatting (`3d 04:12:09` / `4:12:09` / `12:09`) shared by every surface; also duplicated in `docs/t.html`'s `formatRemaining`/`formatTargetDate` JS.

### Persistence & cross-target sync

`TimerStore` reads/writes an array of `TimerPayload` as JSON in `UserDefaults(suiteName: "group.com.lokesh.sharedTimer")` — the App Group is what lets the main app, Messages extension, App Clip, and widget all see the same timers. Every target's entitlements file must list that same group ID. `TimerStore.persist` prunes payloads that are non-paused and expired more than 24h ago.

### Notifications, Alarms & Live Activities

Deployment target is **iOS 26.1** (all shipping targets — bumped from 17.0 for AlarmKit).

`TimerPayload.alarmEnabled` (the compose-sheet "Alarm when it ends" toggle, default true, in `TimerFieldsView`) gates the whole loud path: when **false**, a finished timer/countdown raises only a `.default`-sound notification — never AlarmKit, never the in-app `AlarmPlayer` loop. It's a payload field → carried in the share link (`alarm=0`, emitted only when off), CloudKit (`alarmEnabled` record field), and decoded back-compat as `true` everywhere. `docs/t.html` reads `alarm` into a body data-attribute only (no audio there). `StartTimerIntent` / `StartCountdownIntent` expose it as an `alarm` parameter.

Finished-alert mechanism is chosen **by `TimerKind`** (when `alarmEnabled`):

- **`.timer` → AlarmKit** (`sharedTimer/AlarmController.swift`, **main app target only**). Rings through the silent switch and Focus, shows a full-screen Stop / Repeat panel, survives a force-quit. AlarmKit also runs its **own** countdown Live Activity (rendered by `sharedTimerWidget/TimerAlarmActivityWidget.swift` via `AlarmAttributes<TimerAlarmMetadata>`), so the custom `TimerActivityAttributes` Live Activity is **not** started for `.timer` — starting both is the "too many Live Activities" bug. The "Repeat" button uses AlarmKit's built-in `.countdown` secondary-button behavior (no App Intent); `AlarmController.reconcileRepeat` folds a Repeat back into `TimerStore` on next foreground.
- **`.countdown` → `NotificationScheduler`** + custom `TimerActivityAttributes` Live Activity, exactly as before. A months-out date target wants a gentle notification, not a ringing alarm.

`NSAlarmKitUsageDescription` lives **directly in `sharedTimer/Shortcuts.plist`** (the `INFOPLIST_FILE`), not as an `INFOPLIST_KEY_*` build setting — Xcode 26's `INFOPLIST_KEY_*` allowlist silently drops that key, so the setting compiled away and no permission prompt ever showed. Verify with `plutil -p <built>.app/Info.plist | grep Alarm` after touching it.

`AlarmController` is **main-app-only on purpose** (breaks the "duplicate into every target" rule): AlarmKit is unavailable in app extensions, so `sharedTimerClip` / `sharedTimerMessages` stay wholly on the `NotificationScheduler` path. If AlarmKit is denied / unavailable / at capacity, `AlarmController.reschedule` falls back to `NotificationScheduler` for that `.timer` too. `AlarmController` must never be reachable from `TimerStore.swift` (same invariant as `CloudSyncController` / `WatchSyncController` — `TimerStore` compiles into the Widget).

The main app's mutation sites funnel through `ContentView.armAlerts(for:)` (`onAppear`, `apply`, `pullCloudChanges`) or inline the same three-line sequence (`AppDelegate` push handler, `WatchSyncController` watch-relay, `TimerIntents.StartTimerIntent`). `sharedTimerMessages/MessagesViewController.swift` and `sharedTimerClip/ContentView.swift` still reimplement the older "cancel notification → reschedule → start/update/end Live Activity" sequence directly — grep all of these before changing the mutation flow. `NotificationScheduler.swift` / `LiveActivityController.swift` / `TimerActivityAttributes.swift` are **unchanged** by the AlarmKit work and stay verbatim-identical across their copies.

### Home Screen Quick Actions (`SceneDelegate.swift`, `Shortcuts.plist`)

Long-press app icon → New Timer / New Countdown. Static `UIApplicationShortcutItems` merged into the generated Info.plist via `Shortcuts.plist` + `INFOPLIST_FILE` (kept alongside `GENERATE_INFOPLIST_FILE = YES`). Routes through `ContentView`'s `.quickActionTriggered` notification (warm launch) or `SceneDelegate.pendingShortcutType` drained in `.onAppear` (cold launch — `willConnectTo` runs before the notification subscriber exists).

### Watch app (`WatchSyncController.swift`, both sides)

App Groups do **not** sync between an iPhone and its paired Watch (separate devices, separate
container filesystems) — verified against Apple's own guidance, not assumed. So the watch app
is not a fifth `TimerStore` reader; it's a thin `WatchConnectivity` mirror of whatever
`sharedTimer/WatchSyncController.swift` last pushed via `updateApplicationContext`. Mutations
made on the watch relay back to the phone as a `WCSession` message and are applied there
through the exact same `TimerStore`/`AlarmController`/`LiveActivityController`/
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
