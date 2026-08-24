# Timer Roadmap

Status as of 2026-08-21. Goal: beat the real App Store competitors (ShareTimer, ShareMyTimer,
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

## Process for each remaining phase

Same approach as Phase 1: explore the relevant code, design the concrete technical plan via
`EnterPlanMode`, get it approved, then implement — not guessed/started blind.
