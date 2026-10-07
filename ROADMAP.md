# Timer Roadmap

Status as of 2026-10-07 (1.0.3 merged to main via #5; 1.0.4 complete on branch `1.0.4`, not yet merged). Goal: beat the real App Store competitors (ShareTimer, ShareMyTimer,
Synced Timer Plus, TimeTo) by closing the live-sync gap and leaning into the one thing none of
them have — a real native iMessage extension — instead of routing sharing through a plain link
or QR code.

## Status at a glance (2026-10-07)

**Release:** 1.0.4 (build 7) is feature-complete on branch `1.0.4`. Version is bumped, App Store release notes are written, CI is green, and all 51 tests pass on the simulator and on an iPhone 14 Pro (iOS 26.7).

**Working-tree follow-up (2026-10-07):** the first Phase 7 Siri expansion is implemented locally on `1.0.4`: Pause, Resume, Extend, and Time Remaining. All of it ships in 1.0.4 (decided 2026-10-07); not yet committed. Spotlight indexing of individual timers is also implemented, with live update/delete reconciliation and direct detail-screen routing. Lock Screen circular/rectangular widgets with native remaining-time rings and a configurable Watch complication / Smart Stack widget are also implemented. Shared sequences now preserve full phase/loop state through URLs and CloudKit, with phase-aware Messages/App Clip/web recipients. Yearly countdowns, Calendar import, and web `.ics` export are also implemented locally. All 51 unit tests, 12 shared-sequence tests, 16 annual/Calendar tests, 6 Spotlight tests, 8 widget tests, and 25 AlarmKit integration tests pass on the network-connected iPhone 14 Pro, plus five UI tests for timer links, sequence import, annual controls, the creation form, and Calendar access. Nineteen web timing/export tests also pass. Spoken Siri invocation, a visual Spotlight result tap, and two-account propagation still need manual verification.

**Remaining release steps:**
1. Merge `1.0.4` → `main` (PR).
2. Archive and upload (fastlane / App Store Connect).
3. Submit.

### Fixed in 1.0.4

| Area | What | Verified |
|---|---|---|
| CloudKit | Sync could die permanently on an expired change token. The token is now reset and refetched. The db token is saved only after the zone fetch succeeds. | Build + tests; two-account device check pending |
| Sequences | A Stop mid-sequence no longer stalls the rest. Every phase is pre-armed (window of 8) with its own alarm id. | Device tests + manual |
| Sequences | "Next" on the card no longer leaves the skipped phase's alarm running (second Lock Screen card). | Device test + manual |
| Messages / Clip | No second alert or Live Activity when opening a bubble for a timer the main app alarms via AlarmKit. | Manual |
| CloudKit | A shared timer deleted by a participant no longer comes back. | Unit test; two-account device check pending |
| Live Activity | No more 0:00 card left on the Lock Screen after a quiet timer finishes. | Build + tests |
| Live Activity | The paused card shows the correct time after extending while paused. | Device test |
| Widgets | The list widget refreshes for the earliest timer, not the first row. An unconfigured Single Timer keeps a paused or finished timer (it used to go blank). | Manual |
| Links | A newer re-shared link updates a timer the recipient already has (`upd` stamp). | Unit tests; two-device check pending |
| Robustness | Per-timer alarm work runs in call order. TimerStore writes take a cross-process file lock. | Reasoning; #7 isn't unit-testable |
| Formatting | Correct year on non-Gregorian calendars. Unused overflow-prone `bigDigits` removed. | Unit test |
| Misc | Siri-started timers reach the watch and the open app. Deleting a ringing timer stops the in-app alarm. | Build + tests |

### Implemented in 1.0.4

| Feature | Verified |
|---|---|
| Pause/Resume + Stop (Next/Cancel for sequences) on the Lock Screen card and Dynamic Island. Pause keeps the card visible with Resume. | Manual |
| Home-screen widget buttons: Single Timer gets Pause/Resume, Stop/Next/Cancel, and Repeat when finished; All Timers gets Pause/Resume per row, with a shimmer while updating. | Manual |
| Recent timers: one-tap chips in New Timer, 2 dynamic Quick Actions, seeded once from existing timers. | Manual |
| Control Center / Action button control "Start <recent timer>", which runs without opening the app and confirms with a banner. | Manual |
| Engineering: shared `Shared/` folder replaces copy-pasted files; `TimerArming` funnel; `ContentView` split; GitHub Actions CI; on-device AlarmKit integration tests. | CI + device |

### Still pending

**Needs a manual check (can't be automated here):**
- Two iCloud accounts:
  - Live sharing and accepting a share inside Messages.
  - The extend notification.
  - The participant-delete fix.
  - CloudKit token-reset recovery.
- Two devices: a re-shared plain link updating the recipient (`upd`).
- Siri / Shortcuts by voice (Phase 3).
- Watch app pairing and sync (Phase 3).
- StandBy rendering of the widgets (Phase 4).
- Several long sequences at once reaching AlarmKit's alarm cap (`maximumLimitReached`).
- Pending→running `.fixed` timing of a "Start later" sequence (Phase 5).
- "Sam paused…" text staged in the Messages input field (Phase 2).

**Known limitations (platform, by design):**
- An extend/pause made *inside Messages* can't move the main app's AlarmKit alarm until the app next opens. No AlarmKit in extensions.
- The pre-armed sequence window only refills when the app runs. A sequence left untouched for more than 8 phases runs out of pre-armed alarms.
- Sequence phases not covered by AlarmKit (including both toggles off) use an eight-phase notification window. Either window still needs the app to run to refill it.
- Pause/Resume from a widget updates after a short delay. iOS redraws a widget only after the intent completes; the optimistic-toggle approach doesn't pause (see CLAUDE.md).

**Remaining feature backlog** (Phase 7, by value for effort):
1. Sound picker.
2. Localization + accessibility pass.
3. `t.html` polish.

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

## Phase 3 — Reach (implemented locally, paired-Watch verification pending)

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
- **Apple Watch app — implemented, with a local complication follow-up.** User created the
  `sharedTimerWatch Watch App` target via Xcode's "Watch App for Existing iOS App" wizard;
  App Group entitlement + `CODE_SIGN_ENTITLEMENTS` wiring connects the Watch app to its WidgetKit extension on the Watch itself; it is not used for phone sync (see below). **Corrects the
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
- **Complication / Smart Stack — implemented locally (2026-10-07).** See Phase 7 for the new embedded WidgetKit target, Watch-local snapshot cache, and verification status.

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
  picked time (`TimerPayload.scheduledStartDate`, sequence-only, now included in shared sequence links/CloudKit). The
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

## 1.0.4 — Hardening (complete on branch `1.0.4`; see "Status at a glance")

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

### Bugs / gaps found in the 2026-10-07 audit (all fixed in 1.0.4)

Ordered by severity. Each needs a device, a second account, or a product decision, so none
were changed blind.

| # | Sev | Where | Gap | Repro / fix direction |
|---|-----|-------|-----|------------------------|
| 1 | ~~High~~ | `AlarmController.performSequenceReschedule` | ~~Sequence stalls after primary **Stop** mid-sequence~~ — **fixed in Phase 6, verified on device.** Each phase occurrence now has its own pre-armed AlarmKit alarm (window of 8). | See Phase 6 device checks (a), (c), (d). |
| 2 | ~~High~~ | `TimerStore.isAlarmKitArmed`, Messages/Clip open paths, `TimerArming.arm` | ~~Double alerts + duplicate Live Activities when a timer is in both the main app and Messages~~ — **fixed in Phase 6, verified on device.** Mutations made *inside* Messages still arm their own notification (platform limit: no AlarmKit in extensions). | See Phase 6 device check (b). |
| 3 | ~~Med~~ | `CloudLinkStore.markLeft`, `CloudSyncController.pullChanges` | ~~A timer a participant deleted comes back~~ — **fixed (1.0.4):** a participant delete writes a left-share tombstone; `pullChanges` drops records for those ids; re-opening the share link clears it. | Device check (needs 2 iCloud accounts): participant deletes, owner extends, timer stays gone; re-open link, it comes back. |
| 4 | ~~Med~~ | `LiveActivityController`, `TimerLiveActivityWidget` | ~~Custom Live Activity stuck at 0:00 after finish~~ — **fixed (1.0.4):** `staleDate = endDate`; the card renders "Finished" without buttons once stale/past; the app ends finished activities (5-min linger) at the zero crossing and on every launch/foreground. | Device check: both toggles off, 1-min timer, lock: card shows Finished, disappears after ~5 min once the app has run. |
| 5 | ~~Med~~ | `TimerPayload.updatedAt`/`shouldAdopt`, link `upd` | ~~Re-shared link for a known timer ignored~~ — **fixed (1.0.4):** links carry the last-change stamp; a strictly newer snapshot updates a plain-link (non-CloudKit) copy in the app, Messages and the Clip. | Device check: share a plain link, extend on the sender, re-send, open on the recipient. |
| 6 | ~~Low~~ | `AlarmController.enqueue` | ~~Per-id ordering not guaranteed~~ — **fixed (1.0.4):** the per-id chain is built synchronously under a lock at call time. | — |
| 7 | ~~Low~~ | `TimerStore.withWriteLock` | ~~Cross-process read-modify-write not atomic~~ — **fixed (1.0.4):** all writes take an exclusive `flock` on a lock file in the App Group container. Not unit-testable (single-process stress test couldn't reproduce the race). | — |
| 8 | ~~Low~~ | `TimeFormat.bigDigits` | ~~Breaks 8-char contract at 100–167h~~ — **removed (1.0.4):** unused. | — |
| 9 | ~~Low~~ | `TimeFormat.targetDate` | ~~Wrong year on non-Gregorian calendars~~ — **fixed (1.0.4):** Gregorian + POSIX, cached. | — |
| 10 | ~~Low~~ | `TimerIntents.swift` | ~~Intents skip the watch and the foreground UI~~ — **fixed (1.0.4):** both start intents push to the watch and post `.externalTimerStoreChange` from the main actor; the dialog shows the real length ("30s", "1h 30m"). | — |
| 11 | ~~Low~~ | `ContentView.stopInAppAlertIfRinging` | ~~Deleting a ringing timer leaves the in-app alarm going~~ — **fixed (1.0.4).** | — |
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

## Phase 7 — Features (good to have; first four done in 1.0.4)

Ranked by value vs. effort. Most of these build on intents and infrastructure that already
exist.

- **Live Activity buttons: done (1.0.4).** Pause/Resume + ✕, with Next/Cancel on sequence phases, on both Live Activities; pause keeps the AlarmKit alarm alive in its paused state. **Confirmed on device (iPhone 14 Pro, 2026-10-07):** Lock Screen ⏭ on a sequence advances to the next phase with a single card (after fixing a skipped-phase alarm that lingered as a second card), ⏸/▶ work. Remaining manual checks (Dynamic Island, ✕ on a plain timer) also reported working.
- **Home-screen widget buttons: done (1.0.4).** Single Timer: Pause/Resume + Stop/Next/Cancel, Repeat when finished; All Timers: Pause/Resume per row. **Confirmed on device (2026-10-07):** Pause/Resume from the widgets (plain `Button(intent:)` + shimmer — an optimistic `Toggle`/`SetValueIntent` attempt never paused and was reverted); an unconfigured widget keeps the paused timer. Also confirmed on device: ✕ → Repeat on the widget, Recent chips (after a one-time seed from existing timers), dynamic Quick Actions, and the Control Center control starting a timer without opening the app (with a "started" banner as confirmation).
- **Control Center control and Action button: done (1.0.4)** — `StartRecentTimerControl` starts the most recent timer without opening the app.
- **Quick-start recents: done (1.0.4)** — Recent chips in the New Timer sheet + 2 dynamic Quick Actions.
- **More Siri / App Intents: implemented locally (2026-10-07), shipping in 1.0.4.**
  - `PauseTimerIntent`, `ResumeTimerIntent`, `ExtendTimerIntent`, and `GetTimerRemainingIntent` in the main app. Each has an App Shortcut, spoken feedback, and an editable parameter summary. Extend asks how many minutes to add; Time Remaining returns seconds for chaining in Shortcuts (the current phase for sequences; a scheduled sequence's value includes the wait until its first phase ends).
  - `TimerChoice` moved from the widget into `Shared/`, compiled by the app and widget only. Its `EntityStringQuery` supports name search, preserves duplicate names for disambiguation, derives current sequence phases, and resolves finished timers by ID so existing widget selections remain valid.
  - Actions reload by ID, catch up stale sequences, preserve pauses during Extend, keep Pause/Resume idempotent, and reject missing/finished/scheduled selections and invalid durations. Time Remaining reports scheduled, paused, running, or finished state without mutating timers.
  - Mutations await AlarmKit scheduling and a best-effort CloudKit fetch/save (including conflict retry), push WatchConnectivity state, reload widgets through `TimerStore.save`, and notify the foreground UI on the main actor. App Shortcut parameter values refresh when the app's timer choices change and after Siri mutations.
  - **Verified:** 51 unit tests + 13 real AlarmKit integration tests pass on the network-connected iPhone 14 Pro, 2026-10-07. The two new device tests call the intent `perform()` methods and check real alarm Pause/Extend/Resume, returned seconds, stale entity names, idempotence, sequence catch-up, and future phase schedules. The app, widget, Messages, Clip, and Watch compile as part of the device test build. Metadata extraction contains all four new intents, `TimerChoice`, and six App Shortcuts. Simulator unit tests also pass (device AlarmKit tests skipped).
  - **Manual checks remaining:** voice invocation and timer-name disambiguation in Siri; Minutes prompting; two-account CloudKit propagation and paired-Watch delivery. Example phrases: "Pause Pasta in Timer - iMessage Extension", "Resume Pasta in Timer - iMessage Extension", "Extend Pasta in Timer - iMessage Extension", "How long is left on Pasta in Timer - iMessage Extension".
  - **Spotlight indexing: implemented locally (2026-10-07).** Main-app-only `TimerSpotlightIndex` indexes timer/countdown/current-phase names and paused/scheduled/finished state. Running results use end times rather than stale ticking text; paused timers stay indexed, and finished timers expire after 24 hours. Sequence metadata includes phase-name keywords and expiration after the final phase.
  - Store writes enqueue coalesced indexing through a process-local `TimerStore.didPersist` hook; the shared targets have no indexer dependency. App launch/foreground reconciles extension changes and stale/deleted results, index delegate callbacks rebuild the index, and background intent paths await indexing. Foreground scheduled starts and finishes refresh metadata.
  - Search results carry stable timer IDs and open the current detail screen through both cold and warm scene/user-activity handling. A deleted result shows "Timer unavailable"; it never recreates a timer from an old snapshot.
  - **Verified:** device build passes; all 51 unit + 6 Spotlight + 13 AlarmKit tests pass on the iPhone 14 Pro. The Spotlight integration test queries the real index after insert, pause, delete, and a simulated process restart using an isolated test domain/source. All 57 unit/Spotlight tests also pass on the simulator. A visual search-result tap remains a manual check.
- **Watch complication / Smart Stack widget: implemented locally (2026-10-07), shipping in 1.0.4.**
  - New `sharedTimerWatchWidget` WidgetKit extension embedded in the Watch app, supporting circular, rectangular (including Smart Stack), and inline accessories. Optional timer selection plus recommendations; unconfigured widgets choose the earliest running timer, then a paused timer. Configured deleted timers stay empty.
  - `WatchShared/` contains the existing deliberately separate Watch model, snapshot/cache helpers, and accessory view. `WatchTimerCache` persists the latest WatchConnectivity snapshot in a Watch-local App Group; it never reads the phone's `TimerStore`. App relaunch, connectivity activation, incoming snapshots, optimistic controls, and failed-control rollback keep the cache/widget updated. A SwiftUI WatchConnectivity background task drains pending delivery and persists before suspension.
  - Running time/rings use native date-driven views, completion has a precomputed Done entry, and paused time/rings stay frozen. Long durations use coarse labels with periodic refresh. Content is privacy-sensitive and has accessibility descriptions.
  - Registered ID-only `sharedtimer-watch://timer/<id>` links open the matching current Watch detail screen; a deleted timer shows "Timer unavailable".
  - **Verified:** nine Watch simulator tests cover selection, completion, pause, missing/deleted IDs, cache replace/clear/corruption, received snapshot persistence/relaunch/deletion, link validation, and twelve rendered static layout attachments. Signed iPhone build includes the Watch extension; all 65 unit/Spotlight/widget tests, 13 AlarmKit tests, and the timer-link UI test pass on the iPhone 14 Pro. A separate Watch CI job runs the new shared `sharedTimerWatch` scheme.
  - **Manual check remaining:** no physical Watch is available through Xcode. Pairing/delivery on hardware and actual watch-face/Smart Stack live rendering, configuration, tint/privacy, and refresh after phone/Watch mutations remain unverified. Static ImageRenderer attachments verify layout, not the native WidgetKit host.
- **Lock Screen accessory widgets: implemented locally (2026-10-07), shipping in 1.0.4.**
  - New configurable "Lock Screen Timer" widget (`.accessoryCircular` and `.accessoryRectangular`), using the existing `SelectTimerIntent`/`TimerChoice` picker. Monochrome layouts respect system tint, mark timer content privacy-sensitive, and include VoiceOver state/end-time descriptions.
  - Running timers use native date-driven circular `ProgressView` and `Text(timerInterval:)`; paused rings/time are frozen. Scheduled sequences show their start time with an empty ring; finished/cancelled timers show Done; long countdowns use coarse labels appropriate to their refresh cadence.
  - Pure `TimerWidgetSnapshot` selection and timelines preserve configured finished/focused paused timers, catch up stale sequences, precompute scheduled starts/phase changes/final finish (bounded to eight future entries), and refresh at calendar/day formatting thresholds. Widgets only read the store.
  - ID-only `sharedtimer://timer/<id>` links open the current timer detail screen. The scheme is registered in the main app's generated Info.plist through `Shortcuts.plist`; deleted IDs show an unavailable screen rather than importing a widget snapshot.
  - **Verified on iPhone 14 Pro:** 8 widget tests cover selection, ring state, URLs, coarse refresh, scheduled/sequence timeline boundaries, and eight rendered layout attachments (paused/scheduled/finished/empty in both sizes). Visual QA caught and fixed rectangular gauge overlap. A real UI test adds a quiet temporary timer, opens it through the widget URL, deletes it, and verifies the old URL cannot recreate it; it cleans up the timer. Existing unit, Spotlight, and AlarmKit checks remain green.
  - **Manual check remaining:** add both widget sizes to the actual Lock Screen and confirm live ring/countdown rendering, tint/privacy behavior, chosen-timer configuration, and refresh after pause/extend/finish. ImageRenderer attachments verify static layout; they are not a substitute for the real WidgetKit host.
- **Shared sequences: implemented locally (2026-10-07), shipping in 1.0.4.**
  - Versioned `seq` JSON preserves definitions, per-phase toggles, loop/current position, pause, completion, and `start` for scheduled sequences. Legacy scalar URL fields still let older clients show a phase snapshot. New decoders validate bounded input and catch up late opens across phases/loops without rewriting mutation timestamps.
  - CloudKit `sequenceData`, `scheduledStartDate`, and `updatedAt` preserve the same state. Main-app row/detail sharing prepares a `ckshare` link with a four-second full-sequence snapshot fallback; existing shares are reused. Explicit Next/Cancel actions await CloudKit push; cancellation stamps a finished, silent snapshot. Natural phase advancement is local derivation, never a CloudKit user-mutation push. Authoritative share acceptance does not echo back to the server.
  - Messages and App Clip recipients show phase/loop and pending state and follow boundaries; Messages refreshes authoritative accepted/reopened cloud shares. The web fallback follows the current phase from the link snapshot, including scheduled, paused, and completed sequences.
  - Notifications pre-arm eight phases in recipients/fallbacks, excluding AlarmKit-covered occurrences in the main app to prevent duplicate alerts. Mixed sequences retain the app's complete alert window when opened in extensions. Remote deletion clears derived phase alarms even when an extension has already removed the stored payload.
  - **Verified on iPhone 14 Pro:** 77 unit/Spotlight/widget/sequence tests, 18 AlarmKit tests, and two UI tests pass. New device cases test received-link/record phase alarms, pause/resume, actual mixed notification/AlarmKit coverage, and deletion after the payload is gone. The recipient UI test imports a scheduled sequence, starts it, pauses/extends/resumes, and deletes it. All 77 non-AlarmKit tests also pass on the simulator. Eight web timing tests and four 390×844 headless browser layouts are checked; web tests run in CI.
  - **Production CloudKit schema deployed (2026-10-07):** `Timer.sequenceData` (Bytes), `scheduledStartDate` (Date/Time), `updatedAt` (Date/Time). Two-account sharing/propagation and Messages/App Clip device presentation remain manual checks. Older apps still treat sequences as single-phase snapshots; App Clip/web/Watch do not become CloudKit peers. The existing eight-phase background arming limit remains.
- **Recurring countdowns + Calendar import: implemented locally (2026-10-07), shipping in 1.0.4.**
  - New Countdown offers **Repeat yearly** and **Import from Calendar**. The sheet uses the selected Timer/Countdown type directly, fixing an existing first-open state issue.
  - A Gregorian month/day/time/time-zone anchor preserves anniversaries across missed years, pauses and one-occurrence extensions. February 29 uses February 28 in non-leap years; missing spring times use the first valid time, and repeated autumn times use the first occurrence. Next Year explicitly skips an occurrence; Stop disables the annual series. Clock rollover preserves the shared mutation stamp.
  - The current occurrence and the following year are independently pre-armed through AlarmKit fixed-date alarms (no year-long countdown/Live Activity). Quiet/failed occurrences receive notifications, excluding dates AlarmKit covered. Opening/foregrounding/finishing refills the two-occurrence window. Pause cancels both; resume restores them. Two slots per Gregorian year prevent collisions when Extend crosses New Year's Eve. Remote deletion works after the stored payload is gone.
  - `AnnualRecurrence` is stored in JSON, versioned `annual` links and CloudKit `Timer.recurrenceData` (Bytes). Main app, Messages, App Clip, widgets and web derive the next occurrence; older clients and Watch remain single-occurrence snapshots. Calendar identifiers, attendees and notes never enter the timer's shared payload.
  - Calendar access is requested only after tapping Import. Full-access EventKit reads the next year's events, with search and denial/restricted/error/retry handling. Import copies the title/start/time zone, all-day events use local midnight, and simple unbounded annual rules/birthdays preselect yearly repetition. Relative rules (e.g. fourth Thursday) and other repeat frequencies remain one-off imports.
  - Web countdowns offer **Add to Calendar**, exporting a UTF-8 `.ics` with escaped/folded text. Annual events include RRULE, a self-contained time zone and explicit daylight-saving exceptions. Export snapshots 30 years of current time-zone rules; calendar rules may need refreshing if governments change them. Paused countdowns do not export stale target dates.
  - **Verification:** 93 unit/sequence/Spotlight/widget/annual tests on device and simulator, 25 AlarmKit device tests, five device UI tests, and 19 web timing/export tests. An independent iCalendar parser expands ten years of leap-day/spring-gap/autumn-repeat exports. Device screenshots and a 390×844 web capture are reviewed.
  - **Production CloudKit schema deployed (2026-10-07):** `Timer.recurrenceData` (Bytes). Two-account delivery still to verify. The annual alert window needs Timer to run at least once each year to keep refilling; this is stated in the creation form. Calendar imports are copied snapshots, not subscriptions to later event edits.
- **Edit a running timer: implemented locally (2026-10-07), shipping in 1.0.4.**
  - Pencil on the detail screen and "Edit…" in the row context menu open `EditTimerSheet`. Timers: label + Alarm/Vibrate toggles (time stays on +1:00/Extend). Countdowns: also the target date (disabled while paused); a finished countdown moved forward runs again and its in-app alert stops. Yearly countdowns re-anchor in their own time zone. Sequences are not editable (product decision).
  - Same id, CloudLink and share links; no new wire/CloudKit field (`updatedAt` stamp lets a re-shared link carry the edit). Attribution reads "<name> edited". A countdown keeps its original start so the ring and the recipient's extend banner stay correct.
  - Fixes a latent staleness: paused AlarmKit alarms and annual fixed alarms were kept whenever their time matched, so a new title or tone would never reach them. AlarmController now records a per-alarm title/tone signature and re-creates on mismatch — also covers edits arriving via CloudKit.
  - **Verified (simulator, 2026-10-07):** app/Messages/Clip build; 127 unit tests incl. 9 new `EditTimerTests` (one pre-existing widget PNG-render test flaked once on a zlib write error and passed on rerun); new UI test `testEditRenamesCountdownInPlace` passes. **Verified on iPhone 14 Pro (2026-10-07):** 102 non-AlarmKit tests, all 27 AlarmKit device tests (incl. the two new ones: paused-timer and annual edits re-create the alarm with the new title/tone signature), and the edit UI test pass.
  - **Manual checks remaining:** rename a paused AlarmKit timer and confirm the Lock Screen card's title; turn Alarm off on a running timer and confirm a silent full-screen buzz; two-account propagation of an edit.
- **"What's New" after an update: implemented locally (2026-10-07), shipping in 1.0.4.** "Sunrise Walk", picked from three mockups (https://claude.ai/artifact/R6Kz41fCP8D6dx56qMWd5t): six paged screens with animated illustrations, the sky draining from night to sunrise across the tour, Skip anytime. Shown once to people updating (not fresh installs); deep links take priority; Reduce Motion shows still frames. **Verified (simulator):** 6 gate unit tests, the paging UI test, and screenshots reviewed. **Manual:** look at it on a real update from 1.0.3 (TestFlight), with Reduce Motion on, and on a small phone. Not yet reachable again after dismissal (no settings screen to host it).
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
