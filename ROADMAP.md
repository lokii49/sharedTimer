# Timer Roadmap

Status as of 2026-10-07 (1.0.3 merged to main via #5; 1.0.4 in progress). Goal: beat the real App Store competitors (ShareTimer, ShareMyTimer,
Synced Timer Plus, TimeTo) by closing the live-sync gap and leaning into the one thing none of
them have — a real native iMessage extension — instead of routing sharing through a plain link
or QR code.

## Phase 1 — CloudKit live sync (shipped)

Pause/resume/extend/delete now propagate between devices via CloudKit `CKShare`
(`public­Permission = .readWrite`, no sign-up beyond the iCloud login already on the device).

**Built:**
- `CloudSyncController.swift` + `CloudLink.swift` (main app + Messages extension) — zone
  creation, share/accept, push-up with conflict retry, delete asymmetry (owner delete removes
  for everyone; participant delete is local-only), database-subscription-based pull-down
- `AppDelegate.swift` (main app) — receives silent push, applies changes through the existing
  `TimerStore`/`NotificationScheduler`/`LiveActivityController` call sequence
- `MessagesViewController.send()` — creates the share (4s self-timeout), appends `ckshare` to
  the link on success; **falls back to today's plain link on any failure** — no regression
- App Clip and `docs/t.html` untouched — still snapshot-only, by design (v1 scope boundary)

**Known gap, not yet closed:** a recipient who only ever interacts *inside* the Messages
extension (never opens the main app) doesn't get live sync — accepting a share only happens via
the main app's `onOpenURL`. Natural first item for Phase 2.

## Phase 2 — Group-thread timers + in-thread status (implemented, device-verification pending)

The thing that actually turns the iMessage extension into a real differentiator instead of just
a delivery mechanism for a link. Shipped in the descoped form the CloudKit/Messages APIs
actually allow — see the per-item notes below for what changed from the original wording.

**Built:**
- **Messages-extension live accept** — closes the Phase 1 gap: `MessagesViewController.
  presentView(for:)` now calls the already-present-but-unused `CloudSyncController.acceptShare`
  when a `ckshare` param is on the incoming message URL, guarded by `CloudLinkStore` so it only
  runs once. A recipient who only ever opens the extension (never the main app) now gets a real
  `CloudLink` and stops silently no-op'ing on `pushUp`/`pushDelete`.
- **Group participants** — no compose-flow change needed: `share.publicPermission = .readWrite`
  (Phase 1) already lets anyone with the link join, group thread or 1:1. Added the "who's
  watching" surface instead: `CloudSyncController.fetchParticipantCount` reads
  `record.share.participants.count` on demand, shown as "N watching" in `TimerDetailView`
  (main app) and `TimerRunningView` (Messages).
- **Attribution, descoped to a self-declared name** — a `CKShare` accepted via a public
  `.readWrite` link never returns participant `nameComponents` (Apple withholds identity for
  anonymous link-based accepts), so there's no ambient name to attribute to. `DisplayNameStore`
  (new, duplicated into `sharedTimer`/`sharedTimerMessages`) holds a one-time, skippable,
  self-declared name; `CloudSyncController.applyFields`/`pushUp`/`createShare` write it plus a
  short action verb onto the CKRecord (`lastActorName`/`lastAction`, not `TimerPayload` — no
  wire-format change), read back via `lastActor(from:)`/`fetchAttribution`.
- **In-thread attribution, descoped to a staged draft** — an extension can only fill the
  conversation's input field (`insertText`), never post on its own, and has no conversation
  context for a *remote* party's action. So this is local-only: pausing/extending inside
  `TimerRunningView` stages "Sam paused Pasta — 5:22 left" into the input field; the person
  still taps send.
- **Shared finish moment, descoped to a same-device haptic** — both sides already schedule
  their local notification off the same synced `endDate` (Phase 1), so the pings already land
  together; no new cross-device machinery was needed. Added a `UINotificationFeedbackGenerator`
  success haptic the first time `payload.isExpired` flips true while `TimerDetailView` or
  `TimerRunningView` is on screen.

**Builds clean** (`sharedTimer` and `sharedTimerMessages` schemes, iOS 26.5 simulator), and the
two duplicated `CloudSyncController.swift`/`DisplayNameStore.swift` copies stay in sync. **Not
yet verified on device** — this needs two iCloud accounts and a simulator/device, neither
available in the environment that wrote this:
- Two-account share acceptance from inside the Messages extension (item 1)
- `insertText` staging actually landing in the conversation input, including in a group thread
- The finish haptic firing on the wall-clock tick (fixed once already — the first cut attached
  `.onChange` outside `TimelineView`'s content closure, which never re-evaluates on the clock)

## Phase 3 — Reach (implemented, device-verification pending; complication deferred)

- **Siri / App Intents / Shortcuts — implemented.** `sharedTimer/TimerIntents.swift` (new,
  main app target only). `StartTimerIntent`/`StartCountdownIntent` reuse the same creation
  sequence every other surface uses — `TimerPayload.compose` → `TimerStore.save` →
  `NotificationScheduler.scheduleAlert` → `LiveActivityController.start` — donated via a
  static-phrase `AppShortcutsProvider` ("Start a timer in \(.applicationName)" / "Start a
  countdown in \(.applicationName)" — resolves to whatever CFBundleDisplayName the main app
  target has, currently "Timer - iMessage Extension"; label/minutes/date aren't
  spoken-phrase-fillable per the App Intents framework,
  so Siri prompts for them after the phrase matches, or they come from the Shortcuts editor).
  Deliberately doesn't share the created timer — no background-intent API can address a
  specific iMessage contact and insert text the way `MessagesViewController` does; that stays
  a one-tap follow-up via the existing `ShareTimerSheet`. Confirmed via
  `ExtractAppIntentsMetadata`: both intents show up in the built `Metadata.appintents` with
  their parameters. **Not yet verified**: actually invoking via Siri or the Shortcuts app
  (needs a simulator/device with Siri enabled — not available in the environment that wrote
  this), and whether the donated phrases sound natural spoken aloud.
- **Apple Watch app — implemented, without the complication.** User created the
  `sharedTimerWatch Watch App` target via Xcode's "Watch App for Existing iOS App" wizard;
  App Group entitlement + `CODE_SIGN_ENTITLEMENTS` wiring added (needed for a future watch
  complication extension, which shares data with this app on-device the way `TimerStore`
  does across the other targets — not used for phone sync, see below). **Corrects the
  roadmap's original approach**: "reads the same App Group `TimerStore`" doesn't work — App
  Groups don't sync between an iPhone and its paired Watch, verified against Apple's own
  guidance rather than assumed (different physical devices, separate container
  filesystems). CloudKit-only was rejected too: most timers are never shared, so most never
  reach CloudKit at all, and a CloudKit-only watch app would show nothing for someone who's
  never shared a timer. Built on `WatchConnectivity` instead — `sharedTimer/
  WatchSyncController.swift` (phone) pushes the full local `TimerStore` snapshot via
  `updateApplicationContext` at every mutation point (`ContentView.apply`/`delete`/
  `pullCloudChanges`, `AppDelegate`'s push handler); `sharedTimerWatch Watch App/
  WatchSyncController.swift` (watch) mirrors it into a `@Published` array with an
  optimistic-update-then-rollback-on-failure `send(id:op:)` for Pause/Resume/+1:00, relayed
  back to the phone as a message and applied there through the same `TimerStore`/
  `NotificationScheduler`/`LiveActivityController`/`CloudSyncController.pushUp` sequence
  every other surface uses (see CLAUDE.md's "Watch app" section). Native watchOS list UI —
  no Sky gradient system on this pass, a reasonable future polish item. Both `sharedTimer`
  and `sharedTimerWatch Watch App` schemes build clean (watchOS Simulator platform had to
  be downloaded first — wasn't installed at all before this). **Not yet verified**: actual
  WCSession pairing/message delivery on a live simulator pair or device, which isn't
  something to script in this environment.
- **Complication — deferred, not started.** Needs a separate WidgetKit extension target
  embedded in the watch app — the same "new target, needs Xcode's GUI wizard" situation the
  watch app itself was just in. Same next step as before: scaffold the target via Xcode's
  File > New > Target, then ask for the code plan.

## Phase 4 — StandBy mode (implemented, device-verification pending)

Turned out not to need "a new WidgetKit family/layout" as originally guessed here — verified
against Apple's actual mechanism instead (sources in the implementation): StandBy auto-promotes
existing `.systemSmall`/`.systemMedium` widgets, which `SharedTimerCountdownWidget` already
declared. The real gap was that the system strips whatever `.containerBackground(for: .widget)`
supplies in StandBy and substitutes plain black — `BigCountdownWidgetView`'s entire Horizon sky
identity rode on that call, so it would've rendered as bare text on black there.

**Built:** `sharedTimerWidget/SharedTimerWidget.swift` — `BigCountdownWidgetView` and
`TimerListWidgetView` both now read `@Environment(\.showsWidgetContainerBackground)` and
`@Environment(\.widgetRenderingMode)` and redraw their sky as an ordinary `ZStack`-sibling
content layer (not via `containerBackground`) when the system has stripped it and rendering is
`.fullColor` — skipped in `.vibrant` (StandBy Night Mode), where the system's own
desaturate-by-luminance pass would fight a colorful layer underneath. `TimerLiveActivityWidget`
needed no changes — Live Activities already appear in StandBy automatically.

**Not yet verified**: actual StandBy rendering. `simctl` has no StandBy verb; enabling it needs
the Simulator app's Features menu plus on-device interaction to add the widget, not something
scripted in the environment that wrote this. Builds clean (`sharedTimerWidget` and umbrella
`sharedTimer` schemes) — that's what's confirmed. **Specific risk to check first on device**:
the StandBy sky layer is a `ZStack` sibling of the widget's own content, which sits inside
WidgetKit's automatic content margins — unlike `.containerBackground`, which renders full-bleed
outside them. The sky may show up inset with a black frame around it in StandBy rather than
edge-to-edge like it is on the Home Screen. If so, the fix is `.contentMarginsDisabled()` on
`SharedTimerCountdownWidget`'s `WidgetConfiguration` plus manually re-adding padding to
`content(for:)` — but that flag also changes Home Screen rendering, so don't apply it without
checking both.

## Phase 5 — Sequence timers (shipped 1.0.2; scheduled-start shipped 1.0.3, device-verification pending)

Not part of the original competitor-gap analysis above — a separate differentiator added on
its own track once the core sync/reach/StandBy phases were in.

**Built (1.0.2):**
- `SequencePhase`/`SequenceInfo` on `TimerPayload` — ordered phases (label/kind/duration/own
  alarm+vibrate toggles), looped `loopCount` times. Free-form builder in `NewSequenceSheet`
  (add/delete/reorder/edit any phase); Pomodoro and Intermittent Fasting are just seeded
  starting points, not fixed modes, alongside a blank Custom template.
- `SavedSequenceStore` — save a built sequence as a blueprint, re-select from "Start from".
  Main-app-only, kept out of the share/sync path (never round-tripped through `url()`,
  CloudKit, `docs/t.html`, or the watch app).
- Background-safe advance: `advancedSequence(at:)` re-derives whichever phase should be
  current from elapsed time (no running state machine — iOS has no background execution to
  drive one). AlarmKit per-phase alert gets a dynamic secondary button — "Next"
  (`AdvanceSequenceIntent`) on every phase but the last, "Cancel" (`EndSequenceIntent`) on the
  final one — after confirming on device that AlarmKit's `stopIntent` and its built-in
  `.countdown` secondary-button behavior can't do either job.

**Built (1.0.3, merged to main 2026-10-07):**
- "Start later" — `NewSequenceSheet` can schedule a sequence's phase 0 to begin at a future
  picked time (`TimerPayload.scheduledStartDate`, sequence-only, never shared/synced). The
  finish alert is still armed at creation, not deferred, since nothing can run in the
  background to arm it later.
- Redesigned "Scheduled" state — `SkyCard` shows the start time itself (not a ticking
  countdown to it) and reads "starts …"; Pause/Extend hidden while pending (don't mean
  anything yet); Delete doubles as Cancel; "Start Now" reuses `repeated()` to jump straight to
  running.
- Fixed a Siri-intent reschedule teardown risk and added the first `TimerModel` unit tests
  (c5c5708).
- Fixed row tap targets only responding to the label text, not the rest of the row
  (53d211d).

**Not yet verified**: on-device re-confirmation of the pending→running AlarmKit `.fixed`
schedule transition timing after these changes (previously spot-checked once — create a
pending sequence 2 minutes out with a 1-minute phase 0, confirm nothing shows for 2 minutes
and the alarm rings at +3, not +4); that a pending sequence never leaks into the watch app via
`WatchSyncController`'s flattened phase-0 view (guard is code-reviewed, not device-tested).

## 1.0.4 — Hardening (in progress, branch `1.0.4`)

From a full code audit on 2026-10-07. Build + the 26 `sharedTimerTests` (Swift Testing) pass;
nothing below has been verified on a device yet.

**Fixed (a1e6653):**
- **CloudKit sync could die permanently.** `pullChanges(scope:)`/`fetchZoneChanges` didn't
  handle `CKError.changeTokenExpired`. The stale token stayed saved, so every later pull failed
  the same way and live sync stopped silently. Now the token is cleared and the fetch reruns
  once from nil, at both the database and zone level, in both `CloudSyncController` copies.
- **The database change token was saved too early** (`changeTokenUpdatedBlock` and the
  success path), before the zone fetch finished. A failed zone fetch was never retried. The
  token is now only saved once every changed zone has been fetched.
  `zoneNotFound`/`userDeletedZone` don't hold the token back.
- **Timer-list widget refresh** was keyed to `payloads.first`. A paused payload's stale
  `endDate` can sort first, which gave a 15-min fallback that missed a running timer's
  expiry. It now uses the earliest refresh any listed timer needs.
- **Comments that no longer matched the code:**
  - `vibrationEnabled`'s doc said "defaults true" (it decodes as false).
  - `AlarmController.reschedule` claimed overtaken calls are "dropped".
  - `handleIncoming`'s doc was attached to `openQuickAction` and claimed known timers update.

**To verify on device:** with two iCloud accounts, force a token reset by deleting the
`dbChangeToken.*` / `zoneChangeToken.*` App Group keys. Then confirm the next pull still
delivers changes and doesn't duplicate or resurrect anything (see the zombie gap below).

### Bugs / gaps found, not yet fixed

Ordered by severity. Each needs a device, a second account, or a product decision, so none
were changed blind.

| # | Sev | Where | Gap | Repro / fix direction |
|---|-----|-------|-----|------------------------|
| 1 | ~~High~~ | `AlarmController.performSequenceReschedule` | ~~Sequence stalls after primary **Stop** mid-sequence~~ — **fixed in Phase 6, verified on device.** Each phase occurrence now has its own pre-armed AlarmKit alarm (window of 8). | See Phase 6 device checks (a), (c), (d). |
| 2 | ~~High~~ | `TimerStore.isAlarmKitArmed`, Messages/Clip open paths, `TimerArming.arm` | ~~Double alerts + duplicate Live Activities when a timer is in both the main app and Messages~~ — **fixed in Phase 6, verified on device.** Mutations made *inside* Messages still arm their own notification (platform limit: no AlarmKit in extensions). | See Phase 6 device check (b). |
| 3 | ~~Med~~ | `CloudLinkStore.markLeft`, `CloudSyncController.pullChanges` | ~~A timer a participant deleted comes back~~ — **fixed (1.0.4):** a participant delete writes a left-share tombstone; `pullChanges` drops records for those ids; re-opening the share link clears it. | Device check (needs 2 iCloud accounts): participant deletes, owner extends, timer stays gone; re-open link, it comes back. |
| 4 | ~~Med~~ | `LiveActivityController`, `TimerLiveActivityWidget` | ~~Custom Live Activity stuck at 0:00 after finish~~ — **fixed (1.0.4):** `staleDate = endDate`; the card renders "Finished" without buttons once stale/past; the app ends finished activities (5-min linger) at the zero crossing and on every launch/foreground. | Device check: both toggles off, 1-min timer, lock: card shows Finished, disappears after ~5 min once the app has run. |
| 5 | Med | `ContentView.handleIncoming` (`:611`), `MessagesViewController.swift:41` | **A re-shared link for a timer that's already known is ignored.** A sender who extends a timer and sends a fresh *plain* (non-CloudKit) link can't update the recipient's copy. | Needs a recency field on the wire (e.g. `rev` = last-modified epoch). Prefer the link only when it's newer. Update `docs/t.html` in lockstep. |
| 6 | Low | `AlarmController.enqueue` (`:364`) | **Per-id ordering isn't guaranteed.** Each call hops through its own unstructured `Task` before reaching the `Serializer` actor, and arrival order isn't specified. A `reschedule` followed by a `clear` (fast delete) could run in reverse and leave an alarm armed for a deleted timer. | Hard to repro. Fix: make the call sites `async`, or put a monotonically increasing generation per id and skip stale work inside `run`. |
| 7 | Low | `TimerStore.save`/`persist` (`:21`, `:82`) | **Read-modify-write across processes isn't atomic.** The app, Messages extension, intents, and AlarmKit intents can each `loadAll` → mutate → write, so a concurrent write from another process can be lost. | Rare. Fix: `NSFileCoordinator`, or store one key per timer id instead of a single array. |
| 8 | Low | `TimeFormat.bigDigits` (`TimerModel.swift:467`) | **Breaks its own "always 8 characters" contract** for 100–167h: it prints `120:00:00` under the 7-day calendar threshold. | Big countdown widget with a 5-day countdown. Fix: switch to `DD:HH:MM` above 99h (needs a design call). Apply to all 4 copies. |
| 9 | Low | `TimeFormat.targetDate` (`TimerModel.swift:477`) | **Wrong year on a non-Gregorian calendar.** It uses a `DateFormatter` with a fixed `yyyy-MM-dd` and no calendar/locale (a Buddhist calendar shows 2569), and builds a new formatter per call. | Set Gregorian + `en_US_POSIX`, or switch to `Date.ISO8601FormatStyle().year().month().day()`. Apply to all copies. |
| 10 | ~~Low~~ | `TimerIntents.swift` | ~~Intents skip the watch and the foreground UI~~ — **fixed (1.0.4):** both start intents push to the watch and post `.externalTimerStoreChange` from the main actor; the dialog shows the real length ("30s", "1h 30m"). | — |
| 11 | Low | `ContentView.delete` (`:505`), pull-delete path | **Deleting a ringing timer leaves the in-app `AlarmPlayer`/`VibrationPlayer` loop going**, along with the "Time's up" banner, until the user taps Stop. | Fix: stop the players when the deleted id is among those currently alerting. |
| 12 | — | Docs | ~~CLAUDE.md said `sharedTimerTests` was empty~~ — fixed alongside this roadmap. | — |

## Phase 6 — Reliability & engineering (implemented on `1.0.4`, verified on device)

**Done.** Build and the 32 `sharedTimerTests` pass; CI runs them on every push and PR.
1. **`ContentView.swift` split** into `NewTimerSheet`, `NewSequenceSheet`, `TimerDetailView`, and `ShareSheets`.
   - New `TimerArming.arm`/`armAwaiting` is the single "reschedule, then custom Live Activity unless AlarmKit owns the alert" funnel.
   - It replaces 5 hand-inlined copies (ContentView, AppDelegate ×2, WatchSyncController, both start intents).
2. **Copy-paste removed.** The 12 files that were copy-pasted across targets now live once in `sharedTimer/Shared/`.
   - It's a synchronized folder (chosen over a Swift package, so no `public` churn), with per-target membership exception sets reproducing the old footprint exactly. Verified via each target's `SwiftFileList`.
   - The watch keeps its own `TimerModel.swift`.
3. **Gap #2 (Messages/Clip double-arming).**
   - New App Group registry `TimerStore.setAlarmKitArmed`/`isAlarmKitArmed`, written by `AlarmController`.
   - The Messages bubble-open path and the Clip skip their own notification and custom Live Activity for AlarmKit-armed ids.
   - `TimerArming.arm` ends stray custom Live Activities for AlarmKit-owned ids.
4. **Gap #1 (sequence stalls after Stop).**
   - Every sequence phase occurrence gets its own AlarmKit alarm, pre-armed up to 8 ahead. Future phases use `.fixed(end)` plus `preAlert: duration`, the combination confirmed on device for pending sequences.
   - Only occurrences ≥ current are ever cancelled; matching ones are kept.
   - `AdvanceSequenceIntent` carries the tapped phase index.
   - The foreground tick advances without re-arming while AlarmKit's alert is up, so the UI no longer sticks on "Finished".
   - `rescheduleAwaiting` now goes through the per-id serializer (narrows gap #6).
5. **CI.** `.github/workflows/tests.yml`: GitHub-hosted `macos-26`, ad-hoc-signed simulator build (no certificates needed), runs the unit tests plus Clip/Messages builds.

**Verified on a physical device (iPhone 14 Pro, iOS 26.7, 2026-10-07):** all 32 unit tests, plus 9 new `AlarmKitDeviceTests` against the real `AlarmManager`. They confirm:
- The 8-occurrence window is armed, and nothing beyond it.
- The current phase has no schedule; future phases are `.fixed(end_k)` with `preAlert = duration` and state `.scheduled`.
- Re-arming an unchanged sequence keeps the same alarm set.
- Advancing or extending leaves earlier occurrences untouched and re-arms later ones at the new dates.
- Pausing disarms.
- A pending sequence pins phase 0 to `.fixed(start + d0)`.
- `clear(_:)` and `cancelSequenceAlarms` remove every phase alarm.
- The legacy 1.0.3 single-id alarm is cancelled on the first reschedule.
- A plain timer keeps its single id, and the registry (`isAlarmKitArmed`) tracks it.

**Manual device checks — reported working by the user on the iPhone 14 Pro, 2026-10-07** (visual/interactive; not automatable here):
- **(a)** Pomodoro with 1-min phases. Tap **Stop** (not Next) on phase 1 and lock the phone.
  - Phase 2 rings on time, and so do the phases after it.
  - No Live Activity or Dynamic Island appears for a future phase before its own countdown window, even with several `.fixed` alarms pending at once.
- **(b)** Create a timer with Alarm on in the main app, share it, then open its bubble in Messages on the same device. There's no extra notification and no second Live Activity.
- **(c)** With the app foregrounded while a phase alert rings, the alert stays up and the list advances to the next phase.
  - Also open the app *by tapping* a ringing phase alert: it must stay up.
- **(d)** Stop on phase k, then tap **Next** on phase k+1's alert. Phase k+2 starts from the tap, not phase k+1 again.
- **(e)** ~~Legacy 1.0.3 alarm migration~~: covered by `legacySingleIDAlarmIsCancelledOnFirstSequenceReschedule` on device.
- **(f)** Several long sequences at once (e.g. 3× Intermittent Fasting = up to 24 pre-armed alarms). Watch for `maximumLimitReached` in the console. Once the cap is hit, a plain timer silently falls back to a notification.

## Phase 7 — Features (good to have)

Ranked by value vs. effort. Most of these build on intents and infrastructure that already
exist.

- **Live Activity buttons: done (1.0.4).** Pause/Resume + ✕, with Next/Cancel on sequence phases, on both Live Activities; pause keeps the AlarmKit alarm alive in its paused state. **Confirmed on device (iPhone 14 Pro, 2026-10-07):** Lock Screen ⏭ on a sequence advances to the next phase with a single card (after fixing a skipped-phase alarm that lingered as a second card), ⏸/▶ work. Remaining manual checks (Dynamic Island, ✕ on a plain timer) also reported working. **Still open:** buttons on the home-screen widget —
  *(original item:)* Pause / +1 min / Repeat via
  `Button(intent:)` on the home-screen widget and the custom Live Activity. Reuses
  `TimerStore` plus a `LiveActivityIntent` (same pattern as `AdvanceSequenceIntent`).
- **Home-screen widget buttons: done (1.0.4).** Single Timer: Pause/Resume + Stop/Next/Cancel, Repeat when finished; All Timers: Pause/Resume per row. **Confirmed on device (2026-10-07):** Pause/Resume from the widgets (plain `Button(intent:)` + shimmer — an optimistic `Toggle`/`SetValueIntent` attempt never paused and was reverted); an unconfigured widget keeps the paused timer. Also confirmed on device: ✕ → Repeat on the widget, Recent chips (after a one-time seed from existing timers), dynamic Quick Actions, and the Control Center control starting a timer without opening the app (with a "started" banner as confirmation).
- **Control Center control and Action button: done (1.0.4)** — `StartRecentTimerControl` starts the most recent timer without opening the app.
- **Quick-start recents: done (1.0.4)** — Recent chips in the New Timer sheet + 2 dynamic Quick Actions.
- *(original item:)* **Control Center control and Action button** (`ControlWidget`, iOS 18+): "Start 5-min
  timer" or a last-used preset. Small, high-visibility work.
- **Quick-start presets / recents:** one-tap chips for recently used durations and labels
  in the "+" sheet and the Quick Actions, with dynamic `UIApplicationShortcutItems`.
- **More Siri / App Intents:** Pause/Resume/Extend/"How long is left on X?" intents over
  the existing `TimerChoice` `AppEntity`, plus Spotlight indexing of timers.
- **Watch complication / Smart Stack widget:** deferred since Phase 3. Needs the Xcode
  target wizard first.
- **Lock Screen accessory widgets** (`.accessoryCircular`/`.accessoryRectangular`) with a
  progress ring.
- **Shared sequences:** adds the sequence to the URL/CloudKit wire format (and a `t.html`
  fallback that shows the current phase). This is the biggest product differentiator left,
  but it needs gap #1's per-phase alarm design first.
- **Recurring countdowns:** yearly birthdays and anniversaries, re-armed on finish. Import
  the target from Calendar (EventKit) and export an `.ics` from `t.html`.
- **Edit a running timer:** rename it or change its target date, instead of
  delete-and-recreate.
- **Sound picker:** a few bundled `.caf` tones beyond `alarm.caf`, kept as a local
  preference (not on the wire).
- **Localization and accessibility pass:** all strings are hard-coded English (including
  the `LocalizedStringResource(stringLiteral:)` alarm titles). Add VoiceOver labels and
  values for the SkyCard digits and progress, and Dynamic Type checks on the detail screen.
- **`t.html` polish:** an "Open in Timer" / App Store smart banner, and live updates via a
  public CloudKit JS read for shared timers. That's a large job, so only take it on if web
  recipients turn out to matter.

## Process for each remaining phase

Same approach as Phase 1: explore the relevant code, design the concrete technical plan via
`EnterPlanMode`, get it approved, then implement — not guessed/started blind.
