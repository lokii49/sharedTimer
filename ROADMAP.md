# Timer Roadmap

Status as of 2026-11-27 (1.0.8 live; 1.0.9 audit fixes on branch `1.0.9`, see below). Goal: beat the real App Store competitors (ShareTimer, ShareMyTimer,
Synced Timer Plus, TimeTo) by closing the live-sync gap and leaning into the one thing none of
them have — a real native iMessage extension — instead of routing sharing through a plain link
or QR code.

## 1.0.9 (audit 2026-11-27, branch `1.0.9`)

1.0.8 (build 12) is live (READY_FOR_SALE, checked via App Store Connect 2026-11-27). Four parallel read-only audit passes (model/wire/web, alert delivery, CloudKit/sharing/extensions, app UI/l10n/a11y) plus a `git diff 1.0.7 1.0.8` regression review, a full localization scan and competitor/API research. Every finding below was re-read in the code before fixing; tests were added first where the code allows it. Details of each fix live in CLAUDE.md "1.0.9 fixes".

**Status:** Fixes F1–F26 (F7 and F17 withdrawn, F21 reverted, see below) and widget fixes W1–W15 done on branch `1.0.9`; version 1.0.9 (13). Verified 2026-11-27 after the last change (✕ skips a repeating countdown, What's New page 4): simulator 209 unit (162 run, 47 device-only skipped), 19 UI (18 + the iPad-only test, which passes on an iPad Air simulator), Watch 12, web 33 + Worker/status 23; iPhone 14 Pro (iOS 27.2, US/Pacific) 161 unit + 47 AlarmKit/Live Activity + the History UI test; standalone Clip and Messages builds and a Release build pass; real-iCloud clash test on the iPhone 13 (below). Fail-before confirmed by temporarily restoring the old logic: F3, F4 (real AlarmKit device test), F8, the web/Worker tests for F19/F20, F24 (History row), F25 (alert buttons). Not automatable here (CloudKit two-device, UI presentation, widget rendering): F1, F2, F6, F11, F12, W3–W5, W7–W15; F9/F10 device behaviour beyond the existing suites unverified. Owner device check of the tour/notes claims: Messages card collapse not observed (2026-11-27, removed from tour + 11 notes). Owner chose to submit without the other checks, so "an open timer follows every change" (Messages) and the widget claims (finish on time, tap opens, inline Lock Screen, tinted look) ship device-unverified — check them on the release build. App Store Connect rejects ✕ in What's New (first release run failed on it; notes reworded).

### Fixed

| # | Sev | Where | Defect → fix | Test |
|---|---|---|---|---|
| F1 | Med | `CloudSyncController` pull | A share accepted on another device of the same iCloud account arrived in this device's shared database with no CloudLink and was stored unlinked: Delete didn't mark it left (the owner's next change brought it back), changes never reached the share, a view-only share was editable. → link it as a participant (not in a peek; not if left) and read its permission. | Pure link helper; real two-device behaviour unverified |
| F2 | Med | `ContentView` Add sheet | Add pushed the snapshot captured at accept time, rolling back a change the owner made while the sheet was up and telling everyone "updated". Not Now was ignored once a pull had stored the timer, and a second link replacing the sheet left the first share joined. → Add saves the newest stored copy without pushing; Not Now removes a pulled copy and leaves; a replaced offer is declined. | UI path, no automated test (CloudKit) |
| F3 | Med | `CloudSyncController.merged` | Conflict merge copied timing keys one by one, and the order of racing saves decided the outcome: a Resume racing this device's own Pause could land as "paused" for everyone; their end + our paused remainder made states nobody created. → timing keys (`endDate`, `pausedRemaining`, `duration`, `scheduledStartDate`, `sequenceData`, `recurrenceData`, `repeatRuleData`) merge as one group, and the server's group (and stamp) stays when its `updatedAt` is newer. | Unit (both orders); real iCloud on the iPhone 13: a forced conflict in both save orders keeps the extend whole, and CloudKit's `ancestorRecord` is the fetched copy (the merge's assumption) |
| F4 | Med | `AlarmController` annual slots | Extending a daily/weekly/monthly occurrence (or a yearly one past New Year) gave the moved date the slot still holding the next occurrence; the next occurrence lost its alarm and its notification. → two-pass planning (kept slots first, then free ones). | Unit (`planAnnualSlots`) + AlarmKit device test |
| F5 | Med | `BackgroundRefresh.schedule` | Tested the raw stored copy, which reads finished once its phase/occurrence ended → the next request was cancelled after the first run past a boundary. → projected through `advancedSequence` (`wantsRuns`). | Unit |
| F6 | Med | `EditTimerSheet` | Opened from the detail screen, `original` was replaced on every re-render while the fields kept their first values → untouched fields compared as changed and Save wrote stale values over a rename/extend that landed meanwhile. → `original` frozen in `@State`. | Not automatable without UI harness |
| F8 | Low/Med | `TimerModel.edited` | A time-only edit of a clamped repeating countdown (Feb 29 shown as Feb 28, a monthly 31st shown as the 30th) baked the clamp into the rule. → `AnnualRecurrence.reanchored(from:to:)` keeps the rule's day when the date didn't change and its time when the time didn't. | Unit |
| F9 | Low | `AlarmController.matchesPrearmed` | A pre-armed phase alarm paused in place and resumed within 1 s was kept paused — the phase never rang. → never keep a `.paused` alarm for a running sequence. | Device behaviour unverified (pausing a pre-armed `.fixed` alarm) |
| F10 | Low | `NotificationScheduler` | `*Awaiting` arming paths returned before the notification was added (cancel sync, add async); the NSE could deliver (and be ended) first. → `scheduleAlertAwaiting`; AlarmController's async paths and the NSE wait for the add — except while notification permission is undecided, where waiting would hang on the prompt. | Existing notification device tests |
| F11 | Low | Siri start intents, Control Center `startRecent` | Never uploaded with "Sync with iCloud" on. → awaited `pushUpAwaiting` (no-op when sync is off). | — |
| F12 | Low | `ShareTimerSheet` | Start SharePlay offered for an iCloud-shared timer, whose owner ignores changes from the call (1.0.8 rule) — a member's Pause only paused their own copy. → hidden for `isShared`. | — |
| F13 | Low | Watch `WatchSyncController` | Two quick failed taps rolled back to the first tap's state (Pause+Resume → "paused" while the phone ran). → per-timer fallback advanced by phone acks. | Watch unit |
| F14 | Low | `TimerDetailView` Keep Screen On | Never switched off when a sequence finished, and its button disappeared. → finished = exhausted for sequences. | — |
| F15 | Low | `ContentView` overlay | The alarm banner replaced the Undo toast; Undo ran out unseen. → both shown. | — |
| F16 | Low | iPad list | Selected row not exposed to VoiceOver. → `.isSelected` trait. | — |
| F18 | Low | Messages share list | Row digits frozen at open; a scheduled sequence said "Ends" with phase 0's end. → rows tick, follow phases, show the start time (no countdown to it). | — |
| F19 | Low | `docs/t.html` | Yearly ICS for an occurrence moved into the next year excluded the next real anniversary; old (1.0.4–1.0.6) links with a literal `+` in `seq`/`annual`/`repeat`/`label` were invalid or mangled; hand-made recurrence envelopes judged unlike the app (missing hour/minute/second, non-integer weekday). | 3 web tests (failed before) |
| F20 | Low | link-preview Worker | Same `+` handling; rewrote/counted sequence links the app rejects for a bad `start`. | 2 worker tests (failed before) |
| F21 | Test | `testCalendarImportLoadsEventsWithFullAccess` | Tried resetting Calendar access at teardown so the device is left as found — **reverted**: every run then hits the first-grant system prompt, which this test can't answer on iOS 27 (it looks for "Allow Full Access" in SpringBoard; a screen recording showed the prompt up and unanswered, the import correctly waiting on "Loading events…" — also the likely cause of 1.0.7's "stuck on Loading events" note, not an app bug). The test still leaves access granted (open, low). | 18/18 UI after revert |
| F22 | Low | `CalendarCountdownChoice` | All-day day taken with local `startOfDay` only → a UTC-midnight day became the previous day west of UTC. → day read from the matching midnight (local or UTC), then local midnight. | Unit (both representations) |
| F23 | Low (owner report) | Keep Screen On (app + Clip) | The sun icon read as a dark/light switch that did nothing; outline→filled was the only feedback. → owner's pick: `lock.slash` icon, filled warm when on, 1.5 s "Screen stays on" / "Screen can sleep" capsule for the person's own taps only (not the automatic off at finish/background/leaving), both strings ×9 languages; What's New illustration updated. | Installed on both phones; manual look |
| F24 | **High** (owner report) | History screen | Opening History crashed (main-thread stack overflow) whenever a sequence or repeating-countdown run was on screen. The row's small tag helper was named `tag(_:)`, which resolved to SwiftUI's `View.tag(_:)`, so the row nested itself without end. Found by bisecting the row on the iPhone 14 Pro (Debug and Release both crashed; the simulator's 8 MB stack hid it almost always). → helper renamed `pill(_:)`. **Likely in the live 1.0.7/1.0.8 too** (same code; unconfirmed which SDK built the App Store binary) — for anyone with a sequence/yearly run in History. | Device UI test (crashed before, passes after); unit test renders a sequence row (test host crashed with the old name) |
| F25 | **High** (owner report) | Full-screen alert buttons | Next on a sequence phase alert advanced the timer but left the alert on screen. With the app in front its 1 s tick had already stored the next phase, so Next returned at the "already past" guard without touching AlarmKit; even on the tapped phase, the reschedule keeps an earlier ringing occurrence, and AlarmKit doesn't dismiss after a `.custom` button. Same for Next Year/Week/… (the rollover keeps a ringing slot), Cancel when the timer was gone, and view-only Open (which carried no timer id). → `AlarmController.dismissRinging`: every alert-button action ends the tapped occurrence's ringing alarm first, before any guard; Open now carries the timer id. **Owner's call:** a person's change to the timer (in-app Pause/+1:00/Resume/Start Now/Edit/Repeat, card/widget buttons, Siri, Watch) also ends an earlier occurrence still ringing (`endRingingForChange`). Clock-driven and remote paths still never touch a ringing alarm. | 5 AlarmKit device tests with a real ringing alert (failed before: the alert kept ringing); owner tapped Next on device and the DEBUG marker logged `next … ringing=1 stillRinging=0` |
| F26 | Med (owner call) | ✕ on a repeating countdown (widget, Lock Screen card) | Ended the whole daily/weekly/monthly/yearly series for everyone, with no undo, from one tap. → skips to the next occurrence (`skippingOccurrence`), series kept. | AlarmKit device test updated |

Web test harnesses now encode links the way the app does (`%20`, `%2B`) instead of `URLSearchParams.toString()` (`+` for spaces, which the app never sends).

**Real-iCloud clash test (iPhone 13, development environment, 2026-11-27)** — `TwoDeviceClashTests` (skipped unless `TEST_RUNNER_CLASH_ROLE` is set; roles `setup`/`join`/`race`/`cleanup` for two phones on different accounts — **written but never run successfully**, `solo`, `forced`, `purge`). The two-phone run wasn't possible: the iPhone 14 Pro has no iCloud account (CloudKit `noAccount`), owner chose the one-phone runs.
- `forced`: two copies of one fetched record saved one after the other, both orders → the second save is refused as `serverRecordChanged` with the fetched copy as ancestor; after `merged`, the newer +5 min wins whole with its attribution. ✔
- `solo`: Pause and +5 min pushed at the same instant from the same fresh read, 6 rounds → **0 true conflicts**: the pushes ran one after the other and the last save won whole (5× the extend, 1× the older Pause overwrote the newer extend). So the merge path is rare in practice and the everyday behaviour is "last save wins", exactly as in 1.0.8 — `pushUp` fetches then writes every field of the local copy. **Not fixed here (N15 below):** a push made from a stale copy (offline, or slow) can overwrite a newer change. A plain `updatedAt` guard in `pushUp` would misfire on a phone whose clock is off; it needs a per-timer sync base (the record change tag / fields this device last saw).
- Cleanup verified: no test record, link, queued delete or stored timer left on the iPhone 13 (`purge`). The iPhone 13 now runs a development build — reinstall Timer from the App Store; until then don't open it with Sync with iCloud on (it would upload timers to the development environment).

**Investigated, no bug (no change):** the claim that the Add-shared-timer sheet, Quick Action sheet and notifications alert never appear over a pushed detail screen (by analogy with 4033887) — a new UI test, `testIncomingLinkOffersTheTimerWhileADetailScreenIsOpen`, passes with the sheet where it always was, so the move was reverted and the test kept as a guard. The What's New "Every day…" line was already localized (a catalog sync marked its keys stale only after the change, meaning the compiler extracted them before) — reverted.

**Device-only failure, investigated (→ F22):** `allDayImportUsesLocalMidnightAndWeeklyEventStaysOneOff` failed on the iPhone 14 Pro, which is now on iOS 27.2 in **US/Pacific** (a one-off diagnostic test printed the zone): EventKit returned the test's GMT-built all-day day as UTC midnight with no time zone, and local `startOfDay` made it Jan 4. The import now takes the day from whichever midnight EventKit used (local for store events, UTC for GMT-built ones) — see F22. Whether real store all-day events ever arrive as UTC midnight is unverified; the owner check is "import an all-day event on the Pacific-time phone".

**Checked and clean (no change):** localization — 9 catalogs, 0 missing translations in the 10 languages, 0 format-specifier mismatches, 0 stale keys, AppShortcuts placeholders byte-identical (script, not estimate); `stopIntent` nil; every intent uses `*Awaiting`; serializer coverage; stray sweep and `reconcileRepeat` (1.0.8); NSE single delivery; peek never moves tokens/links; `CKShare.url` from `perRecordSaveBlock`; token ordering; widget/stub signature parity; read-only enforcement on every mutation path; TimerModel pure math, sequence chaining, back-compat decoders, TimerStore prune/lock; the 1.0.7→1.0.8 diff (one regression found: F12).

**Owner checks still open (carried + new):**
- Two devices on one Apple ID: F1 (a share accepted on one appears linked on the other), iCloud share / re-share / Stop Sharing mirroring.
- Two people: F2 (Add after the owner paused keeps the pause; Not Now after a pull removes it). Two phones on different accounts changing one shared timer at the same moment (`TwoDeviceClashTests` roles `setup`/`join`/`race`; needs the 14 Pro signed into iCloud) — expect the last save to win, and in a true conflict the newest change to win whole (a Pause racing a +5 min loses to the +5 min).
- SharePlay in a FaceTime call (F12 hides it for iCloud-shared timers).
- Apple Calendar import of an exported daily/weekly ICS; all-day Calendar import on the Pacific-time phone (F22).
- The Pomodoro card's cause (1.0.8).
- **Messages / App Clip (build-verified only, no automated tests):** delete or "Remove" a timer from its bubble, switch apps and come back (stays gone); leave a bubble via New Timer, half-fill the form, switch apps (form kept); tap the bubble you left (shows its timer?); a friend's pause arriving while the bubble is open (view follows, no ring at the old end); ~~re-share from a bubble (old card collapses)~~ — checked 2026-11-27 on the iPhone 13 (iMessage and RCS): not observed, both cards stay; cause unconfirmed (session reuse on that path unverified); claim removed from the tour and notes; "Next Week" on a weekly countdown in Messages, then open the app (AlarmKit moves); tap a Clip "time's up" notification after the Clip was closed (opens that timer); the Clip's "Get Timer" banner (appears; hidden while ringing).
- **iPhone 13:** runs a development build since the clash test — reinstall Timer from the App Store; until then don't open it with Sync with iCloud on.

**App Store Connect (2026-11-27):** Timer is sold in China mainland (since 2026-09-02), so the **AIGC and Security Assessment declarations** must be answered in App Store Connect by **Jan 31, 2027** (owner answers; every China app must, even with "No" — [Apple](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information/)). The new **age-rating questions** (dating & relationships, shared location) are booleans editable only on a version being prepared; `fastlane release`/`resubmit` now answer them No when unanswered (`ensure_age_rating_answers`).

**Release gates for 1.0.9 (2026-11-27, owner chose to ship the full 1.0.9 now):** no new CloudKit fields. ~~Bump to 1.0.9 / build 13~~ done. ~~Deploy the link-preview Worker~~ done (version 94db1442; live check: `C++` kept, bad `start` not rewritten). Website: [mirrornotes-website#3](https://github.com/lokii49/mirrornotes-website/pull/3) copies `docs/t.html` — **owner merges** (merging deploys the page). ~~Release notes ×11~~ written (machine translations, not native-reviewed). What's New 1.0.9 shows to updaters from this version. China AIGC/Security declarations: owner, by Jan 31, 2027.

**What's New 1.0.9:** four pages (owner's pick): Widgets that keep up · More in Messages · Keep the screen on · Alarms that listen (replaced "Steadier sharing": it promised newest-change-wins, which the real-iCloud test disproved for everyday saves — N15; the release-notes line was dropped too) — new scenes, 8 strings × 9 languages; replaces the 1.0.7 tour. Shows to people updating once the version is bumped to 1.0.9 (release gate). Verified: unit gate tests (4 pages, 1.0.7/1.0.8 → 1.0.9) and the UI tour test with a screenshot of each page.

### App Clip, iMessage and Watch pass (2026-11-27, owner request)

Two read-only audits (Messages; Clip + Watch app) plus a ripple check of every 1.0.9 change against these targets and a parity grep. Platform facts checked against Apple's pages, not memory: App Clip size limit 15 MB for physical invocations, 100 MB for digital-only on iOS 17+ ([App Store Connect](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/)) — the Clip is 3.9 MB (Release build, before thinning); ephemeral Clip notifications last 8 h per WWDC20, 24 h per WWDC21 (conflicting; the Clip doesn't use them — it asks normally); there is no API to edit a sent bubble, and a new message in the same `MSSession` was said to collapse the older one ([forum](https://developer.apple.com/forums/thread/51570)) — not what iOS 27 did on device (2026-11-27).

| # | Sev | Target | Defect → fix | Verified |
|---|---|---|---|---|
| M1 | Med | Messages | Every reactivation / incoming message rebuilt the view from the still-selected bubble: a timer deleted or a share left here came back (saved, re-armed, re-joined), a half-filled New Timer form was wiped. → `leftMessageURL` (cleared when a share is sent or another bubble is tapped) + `deletedHere` (cleared by an explicit tap on that bubble); `didReceive` only refreshes; new `didSelect` override. Unverified: whether re-tapping the bubble you left arrives as `didSelect` or only `willBecomeActive` (then it shows compose). | Build; device check |
| M2 | Med | Messages | An open running view never saw changes made by other processes (Live Activity/Siri pause, Watch, the notification service saving a friend's pause): rang at the old end, and a tap pushed the stale copy over the change. → re-reads the store every 2 s, comparing both copies projected to the same moment (`TimerPayload.hasOutsideChange` — projecting only the stored side swallowed a phase alert in the second before the view's tick); every tap mutates the newest stored copy and re-checks view-only first. | Unit (boundary ≠ outside change); device check |
| M3 | Low/Med | Messages | Remove while the share accept was in flight brought the timer back and re-joined. → the accept callback leaves instead. | Build |
| M4 | Low | Messages | Tapping another bubble while open kept the old timer. → `didSelect(_:conversation:)`. | Build |
| M5 | Low | Messages | App-card subcaption: a stale end for paused timers, phase 0's end for scheduled sequences, a clock time in the sender's zone. → start / "Paused · 3:00 left" / the length summary. | Build |
| M6 | Low | Messages | Opening a paused timer's bubble requested a Live Activity (no stale date — stays forever); a timer composed here got none. → update when paused; start on compose. | Build |
| M7 | Low | Messages, Clip | Stop didn't acknowledge the finish and overtime ignored it (both ways vs the app). → `acknowledgeFinish` + acknowledged overtime. | Build |
| M8 | Low | Messages | Compose footnote promised a full-screen ring; from Messages only a notification is scheduled until the app opens. → honest footnote (`notificationOnlyHere`, ×9 languages). | Build |
| M9 | Low | Messages | "This matches what your friend sees" shown for unshared timers. → only for live shares. | Build |
| M10 | Parity | Messages | No way to skip a repeating countdown's occurrence. → "Next Year/Week/…" button, via the new pure `TimerPayload.skippingOccurrence` (also used by the app now). | Unit |
| M11 | Low | Messages, app share sheet | Re-sharing a timer from its own bubble stacked a second card. → same `MSSession` (new cards get their own) — **M11 findings (2026-11-27, branch `m11-session`):** DEBUG logging showed the owner's two device re-shares had **no selected card** at send time, so each got a fresh session. A simulator XCUITest probe (driving Messages + the extension) then showed: re-share while the card is selected (tap card → New Timer → Share) → the older card **collapses** to its summary; re-share without the card selected, even reusing the same session id (archived per timer), → **no collapse** (matches the device). The archive-and-reuse attempt was removed; behaviour is 1.0.9's. Still open: one device re-share with the card selected (debug build on the iPhone 13 logs each step), then decide whether a Share button on the card's own view is worth a mockup. Nothing promises a collapse. The live link (`TimerPayload.url(liveShare:)`, now shared by Messages and the app's share sheet) appends `ckshare` without re-encoding the query — both builders turned a label's `%2B` back into `+`. | Unit (link) ; device: no collapse — **open** |
| C1 | Med | Clip | Launched without a link (tapped "time's up" notification, App Library): empty state although the timer was stored. → notification delegate (opens that timer) + fallback to the most relevant stored timer. | Build; device check |
| C2 | Low/Med | Clip | "Get the full app" overlay could never appear (cold launch: no active scene yet, no retry) and covered Stop. → `.appStoreOverlay`, held back while ringing. | Build; device check |
| C3 | Low | Clip, app detail | Keep Screen On's `finished` was evaluated outside the 1 s tick (Clip: stayed on after a quiet finish, button gone). → evaluated inside it. | Build |
| C4 | Low | App (+ Clip/Messages data) | A fresh install after using the Clip or Messages showed the What's New tour (their App Group data looked like an update). → `TimerStore.wasCreatedOutsideApp`. | Build |
| Wa1 | Low | Watch | Paused timers showed only "Paused", so +1:00 while paused did nothing visible. → frozen time + "Paused". | Watch build |
| Wa2 | Low | Watch | A timer finishing with the list open sat at 00:00 until the next phone update; paused ones sorted by a stale end. → the list redraws at each running timer's end (explicit `TimelineView` schedule, not every second) and sorts by time left. | Watch build |
| Wa3 | Low | Watch | Residual rollback race after F13 (a context carrying tap A's result, then tap B fails → rolled back to before A). → contexts reset the fallback; `applyOptimistic` extracted so tests drive real taps. | Watch unit (2 tests) |

**Not done / left open:** Watch complication VoiceOver reads the time from when the timeline was built (A7 — how VoiceOver reads live timer text needs a device check before changing it); the Watch complication keeps `.privacySensitive()` on everything (owner call, see W5). Parity gaps that are product scope, not bugs, and need mockups first: Messages has no Edit, reminders, repeating countdowns or sequences in compose, no Undo for Remove; **mockups 2026-11-27: https://claude.ai/artifact/EbYvmY3ZyMzJVhavwSTbPY (recommended 1A Repeat menu, 2A saved sequences only, 3A Edit sheet, 4A 5 s Undo, 5A reminder chips) — owner picked 1A 2A 3A 4A 5A, **all built on `1.0.10`** (CLAUDE.md "Messages parity");** the Clip is a viewer by design; the Watch flattens sequences and repeats (no phase caption, no Next) by design. Messages/Clip have no automated tests — everything above in them is build-verified only; the device checklist covers them.

### Next release — making Timer more powerful (plan only; mockups before any UI work)

Ranked by value ÷ effort, from competitor listings/reviews and Apple docs (research 2026-11-27; Timer+ reviews read directly, other apps from listings/snippets). Flags: **W** = wire change (`TimerModel` url/decoder + `docs/t.html` + Worker + website copy in lockstep), **CK** = new CloudKit field (deploy to production first), **S/** = new `Shared/` file (check every target's exception list incl. the notification service), **L10n** = new strings ×10 languages, **P** = privacy-label impact.

| # | Feature | Effort | Flags | Notes |
|---|---|---|---|---|
| N1 | **Spoken cues for sequences** — **built on `1.0.10` (picks A / Lean / Dip); not yet listened to on a device** — phase name, "next: Rest", 3-2-1 beeps, optional ducking | M | L10n, S/? | The most-requested interval-app feature (Timer+, Seconds). Foreground / Keep Screen On only — AlarmKit alerts can't speak. AVSpeechSynthesizer + `.duckOthers`. Local preference, no wire. |
| N2 | **"Test my alarm"** in Settings → Alerts — **built (pick B), branch `1.0.10`** | S | L10n | Fires a real 5 s AlarmKit alarm; positions Timer as the reliable one (Clock-app timer complaints on iOS 26; an AlarmKit 26.2 regression was reported, FB21273655). |
| N3 | **Remove time** (−1:00 / −5) beside Extend — **built (pick A): detail screen, Messages, Watch ("−" beside +1:00) and Siri/Shortcuts (Remove Time); not on repeating countdowns** | S | — | Timer+ has it. `extended(by:)` with a negative interval clamped at "now"; no wire change (endDate only). Watch + Siri intent parity. |
| N4 | **History stats + CSV export** — **built (pick B, Stats page)** | S–M | L10n | Totals per label/sequence, fasting streaks; export via ShareLink. On device only. |
| N5 | **Folders/tags + a note per timer** — **owner picked 1A / 2A / this phone only, plus Recents carry tags and notes; built on `1.0.10`** (CLAUDE.md "Tags and notes") | M | L10n (local) / W+CK if shared | Start local-only; sharing the note later needs W+CK. |
| N6 | **"Days since" count-up** from a past date | M | W, CK | Needs a new kind or flag. Older apps reject an unknown `kind` (whole timer dropped) — ship as a new optional param/field with a countdown-compatible fallback, like `repeat`/`repeatRuleData`. |
| N7 | **Stopwatch with laps** | M–L | W, CK, L10n | Same compat issue as N6; probably local-only first. |
| N8 | **Scheduled Live Activity start** (`Activity.request(…, start:)`, iOS 26) for quiet scheduled sequences | S–M | — | Replaces the foreground-only `pendingIDs` tick. A forum report says it can create a second activity — device-test reuse first. |
| N9 | **Built on `1.0.10`** (Find via EnumerableEntityQuery + IndexedEntity properties, Spotlight association, undo for Pause/Resume/Add/Remove Time; see CLAUDE.md) — **App Intents upgrades**: `IndexedEntity` for TimerChoice (Spotlight filtering + generated "Find timers"), `UndoableIntent` for Siri pause/extend/delete | S–M | L10n | WWDC25-275. |
| N10 | **Focus filter** (`SetFocusFilterIntent`): mute heads-up reminders / pick timers per Focus — **owner picked A + suggestion yes (https://claude.ai/artifact/8xDPZqVcd77PMzccAiEXS8); built on `1.0.10`** (CLAUDE.md "Focus filter"). Mechanism (SDK): `appContext.notificationFilterPredicate` matched against each notification's `filterCriteria` (iOS 16), applied by iOS without the app running; AlarmKit alarms and finish notifications never filtered | S–M | L10n | Local preference. |
| N11 | **Widget accented/clear rendering** (`widgetAccentedRenderingMode`) so the skies don't wash out when tinted | S | — | Needs a mockup of the tinted look. |
| N12 | **More tones** (+4, IMA4 ≈ 75 KB × 4 targets) | S | L10n | Imported sounds unverified with AlarmKit `.named` (Library/Sounds). |
| N13 | **Photo background per countdown** | M | P? (local only = none) | Keep on device; CKAsset only if shared. |
| N15 | **Stale pushes can't overwrite newer changes** | M | — (no new field; the base lives on device) | **Built on branch `n15-sync-base` (2026-11-27).** `CloudSyncController.SyncBase` keeps per timer the server record this device last synced (pulled, pushed, created, accepted, adopted; App Group files). The base is read when `pushUp` is called (or this process's own later save, `pushBase`), not after the fetch — a pull in between would hide the other phone's change. `plannedPush` compares decoded copies projected to the same moment (1 s tolerance) and writes only what this device changed since its base; timing is one group, and a field both sides changed goes to the newer `updatedAt` (every field, not just timing). A push that changes nothing sends nothing; afterwards `settlement` takes the server copy (store + base + `revertedToServer` re-arm) only if the stored copy still equals the pushed snapshot — a later tap already stored is never undone. Pushes of one timer run in call order (`PushQueue`). Timers linked before this have no base until their next pull or push (then the old behaviour applies once). Verified: 12 unit tests (`SyncBaseTests`; the core, settle-guard and rename tie-break tests each fail under the old logic), sim 221. Real iCloud (iPhone 13, 2026-11-27, `TEST_RUNNER_CLASH_ROLE=stale`; the other phone's change written straight to the server): passes all three rounds — a stale pause keeps the newer +5 min and the phone takes it; a newer pause wins; the other phone's vibration switch and this phone's pause both survive. With the old logic forced back the same run fails rounds 1 and 3 (pause overwrote the extend; switch lost). Two-phone run still blocked (14 Pro has no iCloud). The tour makes no claim. |
| N14 | **iOS 27 checks**: landscape Dynamic Island (`isDynamicIslandLimitedInWidth`) — **done on branch `di-narrow` (ring when limited, simulator-verified)**. Survey 2026-11-27 (see CLAUDE.md "iOS 27 survey"): no code change needed; StandBy/tinted Home Screen, Mac menu bar and Watch Control Center are **owner looks on hardware** (checklist there). Candidates, not adopted: AlarmKit `appEntityIdentifier` (iOS 27, effect undocumented), `systemExtraLargePortrait` for All Timers on iPad (needs a mockup) | S | — | Build is on the iOS 27.2 SDK; verify WWDC26 APIs before adopting. |

**Do not pursue (privacy label "Data Not Collected"):** widget/Live Activity push updates (needs our server + push tokens), anything server-synced. HealthKit workouts (L) stay on device and likely keep the label, but confirm Apple's definition first.

**Suggested 1.0.9 scope beyond the fixes (owner pick):** N2 + N3 (small, no wire change), then mockups for N1 and N4. N6/N7 need a compat design first.

### Next

- [ ] **Widgets: improvements, all bugs and gaps fixed (no assumptions), must-have widget features implemented** (owner, 2026-11-27). Audit of home, Lock Screen, both Live Activities, controls and the Watch complication against the iOS 27.2 SDK interfaces. Mockups https://claude.ai/artifact/MYUg4ZE8bZ6mj1Z9kVA1sj — **owner's picks (2026-11-27): A outline rows for tinted/clear Home Screen and StandBy night, A grid of sky cards for iPad extra large, CarPlay opt out** — all built (W13–W15).

| # | Sev | Where | Defect → fix | Verified |
|---|---|---|---|---|
| W1 | Med | Home widgets (Single Timer, All Timers) | One entry per timeline and views reading the wall clock: a finish waited for a reload ("0:00" with Pause/✕, no "Time's up"/Repeat), a sequence showed the old phase at 0:00, the sky never drained, a Pomodoro asked ~288 reloads a day. → `TimerWidgetSnapshot.homeTimeline`: entries at start/phase/finish, sky-drain steps, hour rollovers of "3d 4h"; views render from `entry.date`; All Timers gets every listed timer's boundaries (`listDates`). Single Timer now uses the Lock Screen widget's `resolve`. | Unit (4 new) |
| W2 | Med-Low | Reload policy (iOS + Watch) | Empty, paused and finished widgets reloaded every 15 min (96/day, over budget), so reloads that mattered were throttled. → a 6 h safety net for paused/empty/long-finished (every store save reloads; reloads triggered from Messages/the notification service are unverified on device), an auto-selected finished timer at end + 1 h; otherwise only coarse text no entry covers. All Timers judges each row on the entry dates it really keeps (`listReloadDate`). Watch: 6 h unless running; hour-aligned for coarse text. | Unit |
| W3 | Med | Single Timer, All Timers rows, both Live Activities | No tap target: tapping opened the app wherever it was. → `widgetURL` / per-row `Link` to `sharedtimer://timer/<id>` (ID only). | Manual |
| W4 | Med (suspected) | AlarmKit Live Activity | White glyphs on white 18 % circles over the system (light in Light Mode) background. → `liveControlInk` = `Color.primary` on that card; unchanged on skies and in the Dynamic Island. | Manual (Light Mode Lock Screen) |
| W5 | Low | Lock Screen widget | `.privacySensitive()` hid the whole widget (time and ring) when redacted. → the label only. | Manual |
| W6 | Low | Coarse "3d 4h" | Refreshed on a fixed hour from load, up to ~58 min stale. → aligned to the hour rollover (as entries, see W1). | Unit |
| W7 | Low | Custom Live Activity compact slot | Fixed 44 pt truncated "1:23:45". → scales, max 70 pt like the AlarmKit card. | Manual |
| W8 | Low | All Timers | Two rows + "N more…" overflowed a medium widget, five a large one on smaller phones. → `ViewThatFits` picks the most rows that fit. | Manual (SE) |
| W9 | Low | Widget gallery | Showed "No Timers" to people without timers. → `context.isPreview` sample ("Coffee break", 9 translations). | Manual |
| W10 | Low | Shortcuts app | Seven button-only Live Activity intents listed with a raw "Timer ID" field. → `isDiscoverable = false` (Start Recent stays, the control uses it). | Manual: Shortcuts list, and that AlarmKit's Next/Cancel/Open buttons still run |
| W11 | Low | All Timers rows | No C6 corner scrim under the small end text. → added. | Manual |
| W13 | Visual | All Timers in `.accented`/`.vibrant` | Opaque sky fills under white text became one slab of tint. → hairline-outlined rows, labels at 75 %/60 %, digits `.widgetAccentable()` (Single Timer's digits too); full colour unchanged. | Manual (tinted Home Screen, StandBy night) |
| W14 | Feature | All Timers `.systemExtraLarge` (iPad) | Grid of up to six sky cards (name, end, big time, Pause; card opens the timer; "N more…"). | Manual (iPad) |
| W15 | Decision | Single Timer | `.disfavoredLocations([.carPlay], for: [.systemSmall])` — not offered in CarPlay; the Live Activity small tile still is. | Manual (CarPlay) |
| W12 | Gap | Lock Screen | `.accessoryInline` (label + time above the clock, time alone when tight); `TimelineEntryRelevance` on both home widgets for Smart Stack / Smart Rotate. | Unit build; manual look |

**1.0.10 (branch `1.0.10`, 2026-11-27):** N15 sync base; M11 Send update; N2 Test my alarm; N3 Remove time (detail + Messages; not on repeating countdowns — they'd ring twice); N4 Stats + History redesign (grouped rows, Undo, day bars, "set for"); Live Activity relevance; narrow-island ring; Watch complication a11y + name-only redaction. Verified: sim 249 unit, UI incl. `testHistoryAndStatsScreens` (en / ar / AX XXXL), iPhone 14 Pro 193 unit + 49 AlarmKit/Live Activity, real-iCloud `stale` run (iPhone 13); screens looked at: History, group, Stats ×3, detail with − (17e default + AX), Settings refused state, Export sheet, Messages card with Send update. **Island "Time's up" (2026-11-27): not our code — stale state on that phone.** The iPhone 14 Pro's compact island showed "Time's up" for a counting-down alarm timer (1.0.9 and 1.0.10 builds alike) while the Lock Screen card was right, and the widget logged no render. After a phone restart a diagnostic build that writes the mode + alarm-id prefix into the island showed `C09B8` (countdown, this alarm) — the widget draws the right state. AlarmKit's own activity reported `.countdown` throughout (probe read `Activity<AlarmAttributes>.activities`). No code change. What triggered it is unknown: a recheck after the AlarmKit device suite (whose alert-button tests stop ringing alarms like 1.0.9's Next/Open) showed digits. If it recurs, a restart clears it — and note what ran before. **Relevance fix from the same recheck:** quiet cards outranked AlarmKit cards in the island; all custom scores now sit below zero (`belowAlarmKit`). Also fixed: Xcode's "AVAudioSession Hang Risk" — AlarmPlayer and the Settings tone preview now (de)activate the session on a background queue (the async API is iOS 27-only). Still unchecked: AlarmKit-card ring on screen, two-phone N15, card collapse on a real phone. The extension catalogs' sync audit couldn't match their string data (main app catalog clean).

**Not done (plan):** ~~Live Activity `relevanceScore`~~, ~~narrow Dynamic Island~~ (both built in 1.0.10); ~~Single Timer ✕ on a repeating countdown~~ (1.0.9: ✕ skips to the next occurrence). **Watch Smart Stack relevance built in 1.0.10**: `WatchTimerSnapshot.relevance` mirrors the phone widgets' entry rule (last hour 100, running 50 for its remaining time, paused 10, done/empty 0) with an extra entry at the last-hour mark; entry relevance only — the provider's `relevance()` (RelevanceKit contexts, may suggest the widget uninvited and double the Live Activity's small tile) stays a candidate, semantics undocumented. Unit test `smartStackRelevanceRanksTheLastHourFirst`; unseen in a real Smart Stack. **Watch `.accessoryCorner`**: mockups https://claude.ai/artifact/KNVYgLpZerGaRPBHKMpCeM (A icon + arc / B time + arc / C time + name; plus renaming "Shared Timer" → "Timer") — **owner picked B (time + draining arc), built 1.0.10**; renamed "Shared Timer" → "Timer" (owner, 2026-11-27; gallery name and the no-timer text, using the existing translated "Timer" key). `ImageRenderer` doesn't draw the curved label, so the arc is unchecked: owner look on a face with corners (Wayfinder/Infograph) — running arc drains on its own, paused arc frozen and grey, done/empty arc empty. If the live arc doesn't move there, fall back to a stepped `Gauge` driven by timeline entries. Widget push stays out (needs a server; privacy label).

## 1.0.8 (audit 2026-11-13, branch `1.0.8`, build 12)

Trigger: a paused AlarmKit "Pomodoro · Phase 1 of 2 · Loop 1 of 4 · 05:46" card stayed on the owner's Lock Screen for days with no timer in the app (likely an alarm orphaned by a Messages delete / a remote delete a Messages pull consumed; cause unconfirmed — owner to check whether a paused Pomodoro is in that phone's list and whether ▶ on the card did anything). Five read-only audit passes; details of every fix in CLAUDE.md "1.0.8 fixes".

**Status: 1.0.8 (build 12) live (READY_FOR_SALE, confirmed 2026-11-27).** Submitted 2026-11-13. All High (4), Medium (13) and Low findings fixed, apart from three Low items left open on purpose. Verified: sim 189 unit + 18 UI (incl. the iPad split-view test, confirmed to fail without its fix), Watch 10, web/link-preview/status 51, iPhone 14 Pro 40 AlarmKit + 1 Live Activity + 66 unit (none skipped); CI green; the live app on device cancelled an orphaned paused alarm at launch and kept a stored paused timer's alarm.
- **No automated test:** real CloudKit pulls (Messages `peek` incl. the expired-token refetch, `dropShareIfGone`), the notification service and its reminder cancel, the Edit-sheet delete guard, the detail `hasBuzzedFinish` reset. The pull/link decisions, SharePlay acceptance and warm-foreground sequence re-arm are unit-tested as pure functions (`Audit108Tests`).
- **Unconfirmed (manual / two devices):** the `.stale` premise of the Live Activity reuse fix (a foreground app's card still read `.active` 15 s past `staleDate`; reuse itself is device-tested); iCloud share / re-share / Stop Sharing mirroring between two devices on one Apple ID; SharePlay in a FaceTime call; Apple Calendar import of an exported daily/weekly ICS (only ical.js was checked); the Pomodoro card's actual cause.
- **Released pieces:** PRs lokii49/sharedTimer#14 and lokii49/mirrornotes-website#2 merged (the web page is live); link-preview Worker deployed (version 9a532dc0); release notes in all 11 languages uploaded and verified on App Store Connect (machine translations, not native-reviewed). Still unconfirmed: `Timer.repeatRuleData` production deploy (from 1.0.7). Release gotchas: `fastlane release` again stopped on altool's false CDUploaderStateInfoResumeFilePath error after a successful upload, and `update_metadata` on the precheck/IAP error after uploading; `fastlane resubmit` finished the submission.

**Low items:** all fixed on `1.0.8` except the three left open on purpose (see CLAUDE.md "1.0.8 fixes": a finished plain timer's re-arm silences its ringing alarm, the custom card's overtime freezes at +1:00:00, the compact slot ≥ 100 h stays coarse). The previously unreviewed areas (tests, extension catalogs, CI, fastlane, KeepAwake, TimerComposeView) were audited too; fixed: test-host History/iCloud writes, the UI tests' tone/History leftovers, scheme parallelism, compact "Nd" localization, Messages' share list projection, fastlane App Clip en-GB subtitle.

**Still open (low):** ~~Messages' share-list row digits don't tick and a pending sequence row says "Ends" with phase 0's end~~ (fixed in 1.0.9, F18); `testCalendarImportLoadsEventsWithFullAccess` leaves Calendar full access granted on the device (resetting it was tried and reverted in 1.0.9, F21); a few tests can't fail (`example()` stubs, the render-for-visual-review tests only check PNG encoding).

**No automated test (manual or two-device only):** real CloudKit pulls incl. the expired-token peek refetch and `dropShareIfGone`; the notification service; two-account / two-device sharing; SharePlay in a FaceTime call; the `.stale` premise of the Live Activity reuse fix; Apple Calendar import of the exported ICS (only ical.js was checked); the link-preview Worker in the real Workers runtime (not deployed).

## 1.0.7 plan (audit 2026-11-08, branch `1.0.7`, build 10)

Full audit by four parallel read-only passes (correctness vs. CLAUDE.md invariants, performance, UI/accessibility, competitor research). Bucket A ships regardless; B is evidence-based perf; C needs mockups before code (owner rule); D is the feature menu. **No new CloudKit fields are proposed for 1.0.7** — anything that would need one is flagged.

**Status (2026-11-08): 1.0.7 (build 11) submitted for App Review; branch `1.0.7` / PR #13 not yet merged.**
- **Done + verified:** A1–A14; B1 (device test), B3–B7 (B7 minus the calendar query, see below); C1–C5; D1–D3, D5, D6 (all D directions picked from https://claude.ai/artifact/9nyb9PteYPHexn8MC7agEf: A/A/A/A/A/B). 157 unit + 15 UI tests pass on the simulator (the calendar UI test is flaky at its system-alert step, passes on rerun); 121 unit + 33 AlarmKit tests pass on the iPhone 14 Pro. 31 new strings localized.
- **Done, needs a manual check on device:** A3 (Watch relay awaits), A6 (vibrate-only notification buzzes with no tone), B2 (sky sway look, still in Low Power Mode), C1 (fresh-install AlarmKit prompt on first ringing timer), D1 (a heads-up notification arriving), D2 (overtime on Lock Screen card), D4 (no Watch/CarPlay available).
- **Known limit:** overtime keeps counting for up to 1 h after the AlarmKit full-screen Stop — that system button has no hook, so only the in-app Stop / banner / ✕ acknowledge the finish.
- **B8 done:** tones are IMA4 (4.6 MB → 1.3 MB); AlarmKit device test + owner listening check passed.
- **Owner decisions (2026-11-08):** overtime stays 1 h; build D7, D8, D9, D10 next; C6–C9 mockups in progress.
- **All of C6–C9 and D7–D13 built in 1.0.7** (owner: nothing moves to a later release). Picks: C https://claude.ai/artifact/PYNWKUeoSA8sezNDGfossk (A/A/A/A), D9/D10 https://claude.ai/artifact/EviEMXCXiV8xENfdAN3sAr (A/A), D8/D11/D12/D13 https://claude.ai/artifact/6dcmEyGetDD8tSdJnxphTd (A/B/A/B).
- **Release gates (owner):** (1) deploy `Timer.repeatRuleData` (Bytes) to the production CloudKit schema; (2) ~~Group Activities capability + entitlement~~ done 2026-11-08; (3) iPad screenshots made 2026-11-08 (`fastlane/screenshots/en-GB/7–11_iPad_*.png`, 2064×2752, source `fastlane/screenshot_source/ipad.html`); upload with `fastlane update_screenshots` after `release` creates 1.0.7 in App Store Connect (release skips screenshots), then check for duplicate uploads.
- **Unverifiable here:** D7 (Siri voice), D11 (two devices on FaceTime), D12 (two devices on one iCloud account), D13 (Apple Intelligence device), D4 (Watch/CarPlay).

Invariant checklist result: PASS on TimerStore isolation, `stopIntent` nil, no `CKContainer.default()`, intents use `*Awaiting`, `Shared/` target membership, AlarmPlayer/VibrationPlayer pairing, main-actor posts. iPad: every shipping target is `TARGETED_DEVICE_FAMILY = 1` (only test bundles are `1,2`) — iPad is a feature (D), not a fix.

### A. Bugs (fix in 1.0.7)

| # | Sev | Where | Defect → fix |
|---|---|---|---|
| A1 | Med | `Shared/LiveActivityController.swift:9` | `start`/`startAwaiting` guard only pending, not finished. A pulled/echoed Stop or Cancel (both toggles off) re-requests a "Finished" card. → guard "plain timer finished, or sequence exhausted (`loopIndex == loopCount`)" — **not** bare `isFinished`, which is also true for an un-advanced mid-sequence payload (`remaining <= 0`) and would drop a running quiet sequence's card. |
| A2 | Med | `ContentView.handleIncoming` ~:910, `ShareSheets.swift:265` | `acceptShare` runs before the person picks Add / Not Now, so a declined live share still joins the zone and shows up on the next pull (and in the NSE). → two options: (a) accept only on Add — sheet then shows the link snapshot until Add (loses today's authoritative preview); (b) keep early accept, and on Not Now leave the share (delete it from the shared DB) + `CloudLinkStore.remove`. (b) keeps current preview behaviour. Either way test re-tapping the link after a decline. |
| A3 | Med | `WatchSyncController.swift:163` | Watch relay uses fire-and-forget `arm`/`pushUp` then replies; app can be re-suspended before AlarmKit moves. → `armAwaiting`/`pushUpAwaiting` before reply (device check). |
| A4 | Low-Med | `AppDelegate.swift:70` | Remote delete ends the custom Live Activity fire-and-forget before `completionHandler`. → `endAwaiting`. |
| A5 | Low-Med | `CloudSyncController.pushDelete` :523 | CloudLink dropped before the network delete; offline "Delete for Everyone" is lost forever. → keep a pending-delete list, retry on foreground/pull. |
| A6 | Low-Med | `NotificationScheduler.swift:107` | Vibrate-only fallback sets `sound = nil`; iOS ties haptics to sound, so Messages/Clip (primary path) and AlarmKit-denied app finish with a silent banner. → silent named sound (`vibration_silent.caf`, add to Messages/Clip/NSE — +3 × 271 KB unless B8's IMA4 conversion lands in the same pass) — verify on device. |
| A7 | Low | `AppDelegate.swift:138` | Notification "Repeat" has no `isFinished` guard / sequence projection; a stale notification restarts a running timer. → same guard as `LiveActivityActions.repeatTimer`. |
| A8 | Low | `TimerModel.url()` ~:513 | `+` left unescaped in query; `t.html`'s `URLSearchParams` reads it as a space ("C++" → "C  "). → percent-encode `+`. |
| A9 | Low | `TimerModel.from(url:)` ~:585 | Plain `label` has no length cap (phase labels do: 512 B). → same cap. |
| A10 | Low | `ContentView` pull/push paths | Remote Repeat/Extend of a ringing timer leaves the in-app loop + banner running (AlarmKit-denied only). → stop when `TimerStore.finishMoved`. |
| A11 | Low | `SettingsView.swift:81` | Tone change re-arms every timer → revives swiped-away quiet Live Activities. → re-arm only `ownsAlert` timers. |
| A12 | Low | `ShareSheets.swift:233`, `TimerModel.composeAnnual` :734, `MessagesViewController.swift:214` | "1 phases · 1 loops"; English "Countdown" default + untrimmed label; staged Messages text interpolates the raw wire verb + "Someone". → catalog plurals / `String(localized:)` / `attributionPhrase`. |
| A13 | Low | `ContentView.handleIncoming` :932 | Saves the authoritative copy without posting `.externalTimerStoreChange` → open detail screen goes stale. |
| A14 | Doc | CLAUDE.md | Says `AdvanceSequenceIntent` uses `steppedToNextPhase`; production uses `materializingPhase` (former is test-only). |

### B. Performance (estimates from code reading; confirm with Instruments)

1. **High — cold launch cancels and re-creates every running plain timer's AlarmKit alarm** (`ContentView.swift:299` → `AlarmController.performReschedule` :168, no keep-path). Add the same keep-path sequences have (state `.countdown`, `alarmIntendedEnd` within 1s, signature match) inside `performReschedule`, still cancelling notifications + setting armed. Also removes the AlarmKit card flicker on every launch.
2. **High (battery) — detail/Clip sky sway animates continuously** (`TimerDetailView.swift:55`, `TimerClipView.swift:25`: a 1s linear animation restarted every tick on a full-screen gradient ≈ constant frames). Move to a render-server animation (`CAGradientLayer` + autoreversing `CABasicAnimation`, low frame-rate range); pause in Low Power Mode. Same look.
3. **Med-High — whole list rebuilt every second** (`ContentView.swift:49`). Per row per tick: 3 CloudLink JSON decodes (`removalTitle` ×2, `CloudLinkStore.get`), 2 `isReadOnly` reads, ~5 `UserDefaults(suiteName:)` allocations, gradient + 2–3 `formatted()` + shadow — swipe/context-menu closures are non-escaping, so they run every tick. Fix keeping the tick invariant: 1s driver only for `checkForNewlyExpired` (must still see zero-crossings with an empty list); compute registry lookups once per render; `static let` UserDefaults; per-card coarse TimelineView for the drain; frozen cards (paused/finished/pending) not redrawn. Using `Text(timerInterval:)` in rows is a product decision (format differs from `TimeFormat`). **Verify first** whether the root list `TimelineView` keeps ticking behind a pushed detail screen (open question in `TimerDetailView.swift:216`) — if so, both screens rebuild every second and this item's win doubles.
4. **Med — detail screen decodes CloudLinks every second** (`TimerDetailView.swift:184, 380`, plus `DisplayNameStore.name` in `statusLine`). Move to `@State` refreshed in `refreshSharingState`.
5. **Med — each save decodes the store 3–4×**; `undecodableEntries` re-decodes the whole array; pulls save per payload in a loop (N lock cycles, N widget reloads). → `loadAll` reports undecodable entries in one pass; `save(contentsOf:)` batch (still per-payload `keepingExtraTime`/`finishMoved`); coalesce widget reloads.
6. **Low-Med — AlarmController registry churn**: ~17 `AlarmManager.alarms` reads + 16 dictionary writes per 8-phase sequence reschedule. Read `alarms` once per reschedule, one merged registry write.
7. **Med/Low — main-thread blocking**: Calendar import's one-year EventKit query on main (`CalendarImportSheet.swift:46,82`) — **tried and reverted**: running `events(matching:)` in a detached task left the import stuck on "Loading events…" right after access was granted (UI test `testCalendarImportLoadsEventsWithFullAccess`, one A/B run each way on the simulator; that test's system-alert step is also flaky, so the evidence is thin); kept synchronous; QR generated in `body` with a new `CIContext` each evaluation (`ShareSheets.swift:74,170`); 3× `ImageRenderer` before `prepare()` delays the CloudKit share (:118).
8. **Low-Med — bundle**: 17 × 271 KB PCM `.caf` = 4.6 MB (4 copies of each tone). IMA4 ≈ 4× smaller — **device-test AlarmKit `.named` with IMA4 first.** Dark icon is byte-identical to light (634 KB).

### C. UI / UX / accessibility (mockups before code)

Low-risk, no visual redesign (can go straight in):
- **C1 Alert health** — AlarmKit permission is requested cold at launch (`AppDelegate.swift:29`) and nothing tells the person when it's denied, while the compose footnote still promises "rings full-screen". Ask at the first loud timer; Settings status row (alarms + notifications, link to Settings); inline compose warning.
- **C2 Dynamic Type** — `GlassPillButtonStyle` and the split pill use fixed `.system(size: 15)` (`Sky.swift:205`, `TimerFieldsView.swift:250`) → text styles. Preset rows → `ViewThatFits`. Phase wheels missing `.clipped()` (`NewSequenceSheet.swift:393`).
- **C3 VoiceOver** — unit-less timer wheels (`Picker("")`), recent chips read "8 meters", Messages/Clip digits unlabeled, home widget not grouped, SkyCard lacks `.isButton`.
- **C4 Safety + feedback** — Undo toast for Delete/Remove, `allowsFullSwipe: false`, detail Delete styled destructive (it looks like Pause today); `.sensoryFeedback` on pause/extend/start/delete.
- **C5 Messages parity** — same button order as the app; Repeat on finished; Start Now on scheduled.

Needs mockups:
- **C6 Contrast** — `endText` (85% white, 12pt) sits on the lightest corner of every sky: 1.3–2.1:1. Same on Live Activity digits and detail captions. Scrim or lightness cap; Increase Contrast support; Reduce Transparency for `.ultraThinMaterial`.
- **C7 Actionable empty state** — Timer / Countdown / Sequence tiles + recent chips instead of "Tap +".
- **C8 Liquid Glass** — pills/chips/banner are hand-drawn while system bars are real glass; adopt `.glassEffect` in a `GlassEffectContainer`.
- **C9 SkyCard at accessibility sizes** — fixed 104 pt height cuts labels; landscape rows stretch.

### D. Feature menu (ranked value ÷ effort; privacy-safe unless noted)

| # | Feature | Effort | Notes |
|---|---|---|---|
| D1 | **Halfway / "5 min left" reminders** | S–M | Timer+ headline feature. Quiet notifications in `NotificationScheduler` slots; local preference, no wire change. |
| D2 | **Overtime count-up** ("+2:13 over") after finish | S | Display only: detail, Live Activity (`Text(timerInterval:)` counts up), Messages/Clip, web. |
| D3 | **Keep screen awake** toggle on detail + Messages | S | `isIdleTimerDisabled`; kitchen/workout expectation. |
| D4 | **CarPlay + Watch Smart Stack Live Activity** | S–M | `.supplementalActivityFamilies([.small])` on both Live Activity widgets + a small layout. |
| D5 | **Saved sequences everywhere** — Recent chips, Quick Actions, Control Center | S–M | Templates are 3 taps deep today. |
| D6 | **`t.html` "Open in Timer" banner** | S | Finishes the last Phase 7 item (meta tag). |
| D7 | **Interactive Siri/Spotlight snippet** (ring + Pause/+1:00) | M | iOS 26 snippet intents on existing `GetTimerRemainingIntent`. |
| D8 | **Daily/weekly/monthly repeating countdowns** | M | Generalise `AnnualRecurrence`; `recurrenceData` is Bytes → envelope v2, **no schema deploy**; `t.html` in lockstep. **Compat cost:** decoders reject unsupported envelopes rather than flatten, so a 1.0.6 recipient of a weekly countdown link/record fails to decode the whole timer — needs a fallback scalar snapshot or a one-release lag. |
| D9 | **Timer history** (on device) | M | Sibling of `RecentTimersStore`; feeds fasting streaks. |
| D10 | **iPad** | M | `NavigationSplitView`, max card widths; currently iPhone-only. |
| D11 | **SharePlay timer** in FaceTime/Messages | M–L | Synchronized timer on Apple infra, no server. |
| D12 | **Sync your own timers across devices** | M–L | Private zone for unshared timers, reusing CloudSyncController; only matters once iPad/Mac exist. |
| D13 | **On-device natural-language sequence builder** (Foundation Models) | M | "25 on / 5 off ×4" → draft; Apple Intelligence devices only. |

Rejected for privacy (label stays "Data Not Collected"): group chat / "who has seen it", server-synced rooms.

Marketing levers from competitor reviews: free with no ads/subscription (Timer+ 46% negative recent reviews on paywalls), no server of ours to fail (ShareMyTimer "server error"), "Data Not Collected" vs. competitors collecting email/device ID/contacts.

### Code health (opportunistic)
`ContentView.swift` (979 lines) — extract the expiry tick and cloud merge first; sequence re-derive loop duplicated (:283, :345); `subtitle()` copied in 3 views; three identical App Group record-and-prune helpers in AlarmController; Messages hand-rolls the arming sequence.

## Status at a glance (2026-10-18)

**Release (historical, 2026-10-18):** 1.0.4 was live on the App Store (App Store ID 6804558361); 1.0.5 in progress. Current: 1.0.6 live, 1.0.7 planned (section above).

### 1.0.5 (submitted for review 2026-10-18, build 8)

Keep this release small.

**Link domain move (one release, owner's call 2026-10-18):**
- **1.0.5 — recognise and switch (done on the branch).** `https://mirrornotes.org/timer` is live (`mirrornotes-website` repo: `timer.html`, a copy of `docs/t.html`, plus `.well-known/apple-app-site-association`; Apple's CDN already serves it). The app claims `applinks:mirrornotes.org`, the Clip `appclips:mirrornotes.org`; the old domain stays in both. `url()` now emits `https://mirrornotes.org/timer?…`; old-host links still decode (unit test).
- **Accepted trade-off:** a recipient still on 1.0.4 or older gets the web countdown in Safari instead of the app, because their app doesn't claim mirrornotes.org. The old domain's page, AASA and entitlements stay forever for links already sent.
- **App Clip experience:** per Apple's "Supporting invocations from your website and the Messages app", Safari/Messages invocation needs the domain association plus the page's `apple-itunes-app` tag with the default experience; advanced experiences are only for showing a different card per domain/URL. So no App Store Connect change is expected — confirm on device.

**To do for 1.0.5:**
1. ~~Device check with a 1.0.5 build: a `mirrornotes.org/timer?…` link opens the app.~~ Done on the iPhone 14 Pro (2026-10-18): 52 unit tests and all 15 UI tests pass; the two share tests open `https://mirrornotes.org/timer?…` through `XCUIApplication.open`, which only reaches the app's Add sheet via the universal link. Still manual: on a device without the app, the App Clip card appears (use `applinks:mirrornotes.org?mode=developer` + Settings → Developer → Associated Domains Development if Apple's CDN cache lags; remove before release).
2. ~~`t.html`: `noindex`, and `app-id=6804558361` in the `apple-itunes-app` tag (Smart App Banner falls back to the full app where App Clips aren't allowed).~~ Done; re-copied to `mirrornotes-website`.
3. ~~Share counter.~~ Dropped (owner's call, 2026-10-18): any count sent from the app would change the App Store label from "Data Not Collected". The app-side code, the Cloudflare Worker and its D1 database were removed. For a rough signal, Cloudflare's dashboard for mirrornotes.org shows visits to `/timer` pages (website traffic, not app data collection).
4. Release notes.
5. Open: an `og:image` for link previews. The App Clip header shows a fixed "4:12:09", which would read as the real time left, so it needs a neutral image first.
6. ~~Privacy policy URL~~ moved to `https://mirrornotes.org/timer/privacy` (`privacy_url.txt`); the old URL stays up.

**Added to 1.0.5 (owner's call, 2026-10-18 — everything below moved in from 1.0.6):**
- Sharing: share-sheet preview + message; cached share URL with Live/Snapshot label; QR code (view-only snapshot link only); Manage Sharing (`UICloudSharingController`); Skip remembered for the name prompt; Save received sequence as template; link previews (neutral `og:image` + `link-preview` Worker for per-link title/description, no storage).
- Settings ("Sky Stack", picked from three mockups): display name, alarm tone (Classic/Glass/Ember/Dawn), What's New replay, About.
- Localization: top 10 languages (en, zh-Hans, hi, es, ar, fr, bn, pt-BR, ru, id) for app, Messages, Clip, Widget and permission prompts. Accessibility: one VoiceOver element per timer card, spoken digits, Dynamic Type sky labels.
- Best-effort `BGAppRefreshTask` refill of pre-armed sequence/yearly alert windows.
- **Verified on the iPhone 14 Pro (2026-10-18):** 109 unit tests, 27 AlarmKit device tests (incl. the tone-aware presentation signature) and 13 UI tests (Settings, What's New 1.0.5, Arabic RTL screenshots, share sheet from list and detail) pass; simulator: 136 unit + 13 UI.
- What's New 1.0.5 "Afternoon Walk" (picked from three mockups) covers the features above.
- **Manual checks:** Manage Sharing with a second iCloud account; RTL (Arabic) layout pass; tone choice on a real AlarmKit alert; Messages link preview on device; background refresh actually firing (Xcode's `_simulateLaunchForTaskWithIdentifier`). App Store metadata (description, screenshots) is still English-only.

### 1.0.4 (released)

1.0.4 ships everything below: the hardening fixes, Live Activity / widget controls, recents and the Control Center control, plus Edit, yearly countdowns with Calendar import, shared sequences, Lock Screen widgets, the Watch complication / Smart Stack, the extra Siri intents, Spotlight indexing and the "Sunrise Walk" What's New tour.

**Verified:** 135 unit tests on the simulator; 102 regular plus 27 AlarmKit device tests on the iPhone 14 Pro; UI tests for edit, What's New, links, sequences, annual flows and Calendar access; 19 web tests; the update path on an iPhone 13 upgraded from App Store 1.0.3.

**Remaining release steps:**
1. ~~Merge `1.0.4` → `main` (PR #6).~~ Done.
2. ~~Archive and upload build 7.~~ Done.
3. ~~Submit for review.~~ Done.
4. ~~After approval: release manually in App Store Connect.~~ Done, live.
5. Reinstall Timer from the App Store on the iPhone 13 (it runs a development build against the development CloudKit environment until then).

**Release tooling (2026-10-07):** `fastlane release` is now fully automated. It copies the previous version's App Clip Default Experience, waits for the build to finish processing and attaches it, then submits; `fastlane resubmit` resumes from any step. No manual App Store Connect visit per version.

**CI (2026-10-07):** the real-Spotlight-index test is skipped on GitHub-hosted runners (the system search daemon there can take minutes per query; it failed once at 668s while the same commit passed in a parallel run). It still runs locally and on device, and its polling is now time-budgeted (30s) instead of a fixed try count.

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

**Remaining feature backlog** (Phase 7): sound picker and localization shipped in 1.0.5; only `t.html` polish remains (now D6 in the 1.0.7 plan).

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

## 1.0.4 — Hardening (in 1.0.4, submitted for review; see "Status at a glance")

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
