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

`CloudSyncController.swift` carries three non-obvious CloudKit gotchas, each cost real debugging time to find and each is easy to silently reintroduce:

- **Never use `CKContainer.default()`.** It's documented to resolve the container from the `com.apple.developer.icloud-container-identifiers` entitlement array, but that lookup was observed to fail specifically inside the Messages extension's sandbox — even with the entitlement correct in the source file, Xcode's Signing & Capabilities, and the Developer Portal App ID capability — silently falling back to CloudKit's own undocumented last-resort default (`"iCloud." + bundle identifier`, e.g. `iCloud.com.lokesh.sharedTimer.sharedTimerMessages`, which isn't a real container) and failing every operation with `CKError "Bad Container"` (5/1014). Use the explicit `private static let container = CKContainer(identifier: "iCloud.com.lokesh.sharedTimer")` instead, everywhere.
- **`CKShare.url` is never populated on the local object you constructed and passed to `CKModifyRecordsOperation`**, even after a successful save — `modifyRecordsResultBlock` only reports overall success/failure, it never updates the records you passed in. The server-assigned fields (including the share URL) only exist on the record `perRecordSaveBlock` hands back; read `.url` from that saved instance, not the original `share` variable. Same split applies to per-record *failures*: the overall operation can report `.success` while a specific record (e.g. the share, if its root record already has one attached — CloudKit allows only one share per record) failed — that's only visible in `perRecordSaveBlock`, never in `modifyRecordsResultBlock`.
- **`ensureZoneExists` does not cache "already created" locally.** It used to (a flag in App Group `UserDefaults`, set once after the first success), but that cache goes stale the moment the target container changes — e.g. exactly the `CKContainer.default()` fix above, where the flag stayed `true` from whatever container `.default()` used to resolve to, silently skipping zone creation against the *new* container forever after and producing `CKError "Zone Not Found"` (26/2036) that looks like an unrelated fresh bug. `CKModifyRecordZonesOperation` saving a zone that already exists is a documented safe no-op, so it always actually calls through now. Don't reintroduce the cache.

`AlarmPlayer.swift` (loops the bundled `alarm.caf` via `AVAudioPlayer` on a `.playback`-category session, so it ignores the silent switch like a native alarm) is the same verbatim-copy pattern, in `sharedTimer`/`sharedTimerMessages`/`sharedTimerClip` only — the three targets with a foreground countdown view and their own `NotificationScheduler.swift`. Each of those `NotificationScheduler.swift` copies also points `content.sound` at `alarm.caf` instead of `.default`, so a resting notification uses the same tone as the foreground loop:

```
diff sharedTimer/AlarmPlayer.swift sharedTimerMessages/AlarmPlayer.swift
diff sharedTimer/AlarmPlayer.swift sharedTimerClip/AlarmPlayer.swift
```

On iOS 26 a payload AlarmKit owns (`AlarmController.ownsAlert`, below) gets AlarmKit's own full-screen alert (foreground included), so `ContentView` only sounds the in-app `AlarmPlayer` loop when `AlarmController.shouldSoundInAppAlarm(for:)` is true: the alarm toggle is on but AlarmKit permission is **not** granted. A payload AlarmKit is handling never triggers the loop — deliberately keyed on auth state, not `AlarmManager.alarms` membership, because a stopped-from-the-panel alarm leaves the list and would otherwise re-bang the in-app loop the next time the app opens.

`VibrationPlayer` (same file as `AlarmPlayer`, same 3-copy footprint) is a second, independent foreground loop for `TimerPayload.vibrationEnabled` (the compose-sheet "Vibrate when it ends" toggle) — a repeating `kSystemSoundID_Vibrate`. In the main app it's a **fallback only**: `AlarmController.shouldVibrateInApp(for:)` gates it to "vibration wanted, AlarmKit not authorized" (mirroring `shouldSoundInAppAlarm`), because a payload AlarmKit owns already vibrates via its own full-screen alert — starting `VibrationPlayer` too would double-buzz live and re-buzz with a stale "Stop" banner on every reopen (`TimerStore.isFinishAcknowledged` also gates this — see below). In `sharedTimerMessages`/`sharedTimerClip`, which never reach `AlarmController`, `VibrationPlayer` is the **only** mechanism and runs unconditionally off `vibrationEnabled` — grep every `AlarmPlayer` start/stop site together with its `VibrationPlayer` counterpart before changing the finish-handling flow.

`TimerStore.acknowledgeFinish(id:)` / `.isFinishAcknowledged(id:)` (App-Group-backed, alongside `save`/`loadAll`) record "Stop" was tapped for a specific finish — cleared automatically on the next `TimerStore.save` for that id (repeat, extend, etc.), since a new mutation means a future finish should be free to alert again. Written by the vibration-only notification's "Stop" action (see below) and the in-app Stop button; read by `shouldVibrateInApp`.

`TimerAlarmMetadata.swift` (the `AlarmMetadata` payload on an AlarmKit alarm) is a verbatim pair — `sharedTimer` (schedules the alarm) + `sharedTimerWidget` (renders its Live Activity):

```
diff sharedTimer/TimerAlarmMetadata.swift sharedTimerWidget/TimerAlarmMetadata.swift
```

### Core model (`TimerModel.swift`)

- `TimerPayload` — the one data type for both timer and countdown modes (`TimerKind`). Holds `endDate`, `duration`, optional `pausedRemaining` (non-nil = paused). `remaining`, `isExpired`, `progress(at:)`, `paused()`, `resumed()`, `extended(by:)` are all pure, date-parameterized functions — no wall-clock reads except through the `at:`/default-`Date()` args, which keeps them usable inside `TimelineView`.
- `TimerPayload.url()` / `.from(url:)` encode/decode a payload into query params on `https://lokii49.github.io/sharedTimer/t.html` — this is the link shared in Messages and opened by the App Clip. Wire params: `id`, `label`, `end`, `dur`, `kind`, `paused` (only if paused), `alarm` (only `alarm=0`, i.e. only when the alarm toggle is off — absent means on, safe because "alarm on" never changed meaning). `vib` is **not** the same convention — it's always emitted explicitly (`vib=1`/`vib=0`), and absent means *off*: since vibration-on now also triggers a full-screen AlarmKit takeover (not just a foreground buzz), a link from before the toggle existed can't be allowed to default to it the way `alarm` does. Same asymmetry in `TimerModel.swift`'s JSON `Decodable` init (`alarmEnabled` back-compats to `true`, `vibrationEnabled` to `false`) and `CloudSyncController`'s record decode. Changing the payload's wire fields requires updating `docs/t.html`'s JS parsing (`qs(...)` calls) in lockstep.
- `TimeFormat` — day-aware duration formatting (`3d 04:12:09` / `4:12:09` / `12:09`) shared by every surface; also duplicated in `docs/t.html`'s `formatRemaining`/`formatTargetDate` JS.

### Persistence & cross-target sync

`TimerStore` reads/writes an array of `TimerPayload` as JSON in `UserDefaults(suiteName: "group.com.lokesh.sharedTimer")` — the App Group is what lets the main app, Messages extension, App Clip, and widget all see the same timers. Every target's entitlements file must list that same group ID. `TimerStore.persist` prunes payloads that are non-paused and expired more than 24h ago.

### Notifications, Alarms & Live Activities

Deployment target is **iOS 26.1** (all shipping targets — bumped from 17.0 for AlarmKit).

`TimerPayload.alarmEnabled` (the compose-sheet "Alarm when it ends" toggle, default true, in `TimerFieldsView`) gates the whole loud path: when **false**, a finished timer/countdown raises only a `.default`-sound notification — never AlarmKit, never the in-app `AlarmPlayer` loop. It's a payload field → carried in the share link (`alarm=0`, emitted only when off), CloudKit (`alarmEnabled` record field), and decoded back-compat as `true` everywhere. `docs/t.html` reads `alarm` into a body data-attribute only (no audio there). `StartTimerIntent` / `StartCountdownIntent` expose it as an `alarm` parameter.

`TimerPayload.vibrationEnabled` (the compose-sheet "Vibrate when it ends" toggle, default true, same `TimerFieldsView` section) has the same wire/CloudKit/back-compat/Intent treatment as `alarmEnabled` (`vib` param, `vibrationEnabled` CloudKit field, `vibrate` Intent parameter) but is its own toggle — on with the alarm off, or off with the alarm on, are both real combinations.

Finished-alert mechanism is chosen **by `AlarmController.ownsAlert(for:)`** (`payload.alarmEnabled || payload.vibrationEnabled`) — not by kind; both `.timer` and `.countdown` route the same way:

- **Either toggle on → AlarmKit** (`sharedTimer/AlarmController.swift`, **main app target only**). Full-screen through the silent switch and Focus, Stop / Repeat panel, survives a force-quit, even locked — the same experience regardless of *which* toggle triggered it. `alarmEnabled` picks the loud `alarm.caf`; vibration-only (alarm off) picks `vibration_silent.caf` (`sharedTimer/vibration_silent.caf`, a digitally-silent `.caf` — all-zero samples — matching `alarm.caf`'s format/duration; regenerate with `ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 3.03 -sample_fmt s16` piped through `afconvert -f caff -d LEI16@44100 -c 1` if it's ever lost). AlarmKit's `sound:` is **non-optional with no explicit "no sound" case** — checked against the real `AlarmKit`/`ActivityKit` `.swiftinterface` in the SDK, `AlertConfiguration.AlertSound` only has `.default`/`.named(_:)` — so silence is smuggled in as a named asset instead. This rests on an assumption **not yet confirmed on-device**: that AlarmKit's alert vibration isn't decoded from the sound file's waveform, same as a regular notification's haptic firing independent of which sound plays. If that assumption is wrong (AlarmKit substitutes a default sound for silence, or won't vibrate without real audio), this needs a different approach — verify on a physical device before treating "vibration-only, zero sound" as settled. AlarmKit also runs its **own** Live Activity (rendered by `sharedTimerWidget/TimerAlarmActivityWidget.swift` via `AlarmAttributes<TimerAlarmMetadata>`, carrying `kind` so the icon/tint match `.timer` vs `.countdown`), so the custom `TimerActivityAttributes` Live Activity is **not** started when AlarmKit owns the alert — starting both is the "too many Live Activities" bug. The "Repeat" button uses AlarmKit's built-in `.countdown` secondary-button behavior (no App Intent); `AlarmController.reconcileRepeat` folds a Repeat back into `TimerStore` on next foreground (not filtered by kind or which toggle triggered it — a repeated countdown restarts its original `duration` from now, same as a timer).
- **Both toggles off → `NotificationScheduler`** + custom `TimerActivityAttributes` Live Activity, for either kind. A quiet, standard-sound notification, no AlarmKit involvement.
- **AlarmKit denied/unavailable, either toggle on → `NotificationScheduler` fallback.** If `vibrationEnabled` (alarm off) is what wanted AlarmKit, this fallback notification also gets `NotificationScheduler.vibrationFinishCategoryID` — lock-screen "Repeat"/"Stop" `UNNotificationAction`s, registered + handled only in `AppDelegate` (`UNUserNotificationCenterDelegate`). "Stop" doesn't interrupt anything active (`VibrationPlayer`/`AlarmPlayer` are foreground-only, and no third-party app can vibrate in the background on iOS — confirmed platform limit, not a gap) — it calls `TimerStore.acknowledgeFinish` so the app doesn't auto-re-buzz on next open. "Repeat" runs the same repeat-mutation sequence as everywhere else. Setting the category identifier is harmless in the `sharedTimerMessages`/`sharedTimerClip` copies of `NotificationScheduler.swift` too (their notifications are the **primary**, not fallback, path there, since they never reach `AlarmController`) — an unregistered category just renders with no action buttons.

(Countdown-through-AlarmKit, and vibration-through-AlarmKit, are both deliberate product choices, not the platform default — a far-out date target ringing/buzzing full-screen when it finally arrives is the whole point of turning either toggle on. If a future change wants either case to stay gentle/backgrounded regardless of the toggle, that's a reversion of this decision, not a bug fix.)

`NSAlarmKitUsageDescription` lives **directly in `sharedTimer/Shortcuts.plist`** (the `INFOPLIST_FILE`), not as an `INFOPLIST_KEY_*` build setting — Xcode 26's `INFOPLIST_KEY_*` allowlist silently drops that key, so the setting compiled away and no permission prompt ever showed. Verify with `plutil -p <built>.app/Info.plist | grep Alarm` after touching it.

`AlarmController` is **main-app-only on purpose** (breaks the "duplicate into every target" rule): AlarmKit is unavailable in app extensions, so `sharedTimerClip` / `sharedTimerMessages` stay wholly on the `NotificationScheduler` path regardless of `alarmEnabled`/`vibrationEnabled` — a shared/opened timer never rings/buzzes through AlarmKit unless it's also open in the main app. If AlarmKit is denied / unavailable / at capacity, `AlarmController.reschedule` falls back to `NotificationScheduler` for that payload too. `AlarmController` must never be reachable from `TimerStore.swift` (same invariant as `CloudSyncController` / `WatchSyncController` — `TimerStore` compiles into the Widget); `AlarmController` reaching *into* `TimerStore` (for `isFinishAcknowledged`) is fine, only the reverse direction is forbidden.

The main app's mutation sites funnel through `ContentView.armAlerts(for:)` (`onAppear`, `apply`, `pullCloudChanges`) or inline the same sequence — `AlarmController.reschedule`, then the custom Live Activity only `if !AlarmController.ownsAlert(for: payload)` — in `AppDelegate` push handler, `WatchSyncController` watch-relay, and both `TimerIntents` (`StartTimerIntent`, `StartCountdownIntent`). `sharedTimerMessages/MessagesViewController.swift` and `sharedTimerClip/ContentView.swift` still reimplement the older "cancel notification → reschedule → start/update/end Live Activity" sequence directly (these two never reach `AlarmController` at all — no AlarmKit in extensions) — grep all of these before changing the mutation flow. `LiveActivityController.swift` / `TimerActivityAttributes.swift` are still verbatim-identical across their copies and untouched by any of this. `NotificationScheduler.swift` gained the `vibrationFinishCategoryID` category-tagging (still verbatim across its 3 copies, just no longer pristine from the pre-AlarmKit version) — its actual scheduling/sound logic is otherwise unchanged.

**Extend-awareness notification** (`AppDelegate.notifyIfExtended`, main app only): the silent `CKDatabaseSubscription` that drives all CloudKit sync (`shouldSendContentAvailable = true`, no alert) has zero visible signal on its own — a participant who isn't looking at the app has no way to know someone else just extended a shared timer. The push handler snapshots `TimerStore.loadAll()` *before* applying the batch's saves, then diffs each incoming payload against its prior local copy: a pure extend (`endDate` moved forward ≥5s, `duration`/pause state unchanged, `existing.remaining > 0` so a same-shaped repeat from a finished timer doesn't also match) fires a local notification via `CloudSyncController.fetchAttribution` for the "who". This deliberately needs no new CloudKit field and no attribution plumbing through `pullChanges` — the delta comparison doubles as self-echo suppression for free, because `ContentView.apply` always calls `TimerStore.save` *before* `CloudSyncController.pushUp`, so a change's own round-trip back through the subscription always diffs to zero against what's already stored locally. Scoped to extend only (not pause/resume/delete) — those are much more frequent and would make this noisy. `AppDelegate` also gained `userNotificationCenter(_:willPresent:)` (previously absent, so ANY foregrounded notification showed nothing) — gated by category so only this new notification gets a foreground banner; finish/vibration-fallback notifications keep their existing silent-in-foreground behavior, since the in-app UI already covers that case for them.

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
