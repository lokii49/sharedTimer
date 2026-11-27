//
//  MessagesViewController.swift
//  sharedTimerMessages
//

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<AnyView>?
    /// Reset each time presentRunningView shows a timer — see stageAttributionText.
    private var hasStagedAttribution = false

    private var revertObserver: NSObjectProtocol?
    /// The bubble the person left (Delete, Remove, or New Timer from its view). Messages
    /// keeps `selectedMessage` set, so every reactivation (switching apps and back)
    /// rebuilt the running view from that bubble — saving and re-arming a timer just
    /// deleted here, re-joining a share just left, or wiping a half-filled form.
    private var leftMessageURL: URL?
    /// Timers deleted or removed from here this session: a bubble of one, or an accept
    /// that was still in flight, must not bring it back.
    private var deletedHere: Set<String> = []
    /// A Delete / Remove from My Timers that can still be undone (owner's pick 4A, 5 s,
    /// like the app). The timer is already gone from this phone; for a share, the
    /// participant `pushDelete` waits until the window ends (`finishPendingRemoval`).
    private var pendingRemoval: RemovalSnapshot?
    private var removalWork: DispatchWorkItem?

    deinit {
        if let revertObserver { NotificationCenter.default.removeObserver(revertObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // CloudKit refused a change made here (the share became view only) and put the
        // server's copy back in the store: move this extension's alert and Live
        // Activity to it too, as `persist` would.
        revertObserver = NotificationCenter.default.addObserver(forName: CloudSyncController.revertedToServer, object: nil, queue: .main) { note in
            guard let payload = note.object as? TimerPayload else { return }
            // Reminders were re-planned for the refused change.
            TimerReminders.sync(payload)
            NotificationScheduler.cancel(id: payload.id)
            guard !TimerStore.isAlarmKitArmed(id: payload.id) else { return }
            if payload.isPaused || payload.isExpired {
                LiveActivityController.update(for: payload)
            } else {
                NotificationScheduler.scheduleAlert(for: payload)
                LiveActivityController.start(for: payload)
            }
        }
        // Horizon is dark-first; Messages.app owns this extension's trait environment,
        // so the dark trait has to be forced on the controller itself for UIKit-hosted
        // SwiftUI colors to resolve against the dark room.
        overrideUserInterfaceStyle = .dark
        // Fire-and-forget, opportunistic: ensures share-time later is a single round
        // trip (record+share save) instead of two (zone create, then record+share save).
        CloudSyncController.ensureZoneExists { _ in }
        presentComposeView()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        #if DEBUG
        Self.debugLog("willBecomeActive selected=\(conversation.selectedMessage.flatMap { TimerPayload.from(url: $0.url)?.id.prefix(8) } ?? "nil") session=\(conversation.selectedMessage?.session.map { "\($0.hash)|\($0)" } ?? "nil")")
        #endif
        presentView(for: conversation)
        if presentationStyle == .compact {
            requestPresentationStyle(.expanded)
        }
    }

    /// Messages backgrounded or switched away: the foreground loops can't keep running,
    /// so stop them rather than leave `isPlaying` and the Stop button stale.
    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        // The extension may not live to the end of the Undo window.
        finishPendingRemoval()
        AlarmPlayer.shared.stop()
        VibrationPlayer.shared.stop()
    }

    /// An incoming message doesn't change what the person is looking at — it used to
    /// rebuild the view from the selected bubble (losing a half-filled form). Just let an
    /// open timer view pick up any stored change.
    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        NotificationCenter.default.post(name: TimerRunningView.storeChange, object: nil)
    }

    /// The person tapped another bubble while the extension is open (expanded or
    /// compact): show that one — an explicit choice, so even one left earlier.
    #if DEBUG
    /// M11: whether a re-share continued the bubble's MSSession. Read from the App Group
    /// (`debugMessagesLog`) with `devicectl … copy from --domain-type appGroupDataContainer`.
    static func debugLog(_ line: String) {
        let defaults = UserDefaults(suiteName: "group.com.lokesh.sharedTimer")
        var log = defaults?.stringArray(forKey: "debugMessagesLog") ?? []
        log.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
        defaults?.set(Array(log.suffix(40)), forKey: "debugMessagesLog")
    }

    override func didStartSending(_ message: MSMessage, conversation: MSConversation) {
        Self.debugLog("didStartSending session=\(message.session.map { "\($0.hash)|\($0)" } ?? "nil") timer=\(TimerPayload.from(url: message.url)?.id.prefix(8) ?? "nil")")
    }
    #endif

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        #if DEBUG
        Self.debugLog("didSelect message=\(TimerPayload.from(url: message.url)?.id.prefix(8) ?? "nil") conversationSelected=\(conversation.selectedMessage.flatMap { TimerPayload.from(url: $0.url)?.id.prefix(8) } ?? "nil")")
        #endif
        finishPendingRemoval()
        leftMessageURL = nil
        if let id = TimerPayload.from(url: message.url)?.id { deletedHere.remove(id) }
        presentView(for: conversation)
    }

    private func presentView(for conversation: MSConversation) {
        if let url = conversation.selectedMessage?.url, url == leftMessageURL {
            return presentComposeView()
        }
        if let payload = TimerPayload.from(url: conversation.selectedMessage?.url) {
            // Deleted or removed here earlier this session: don't save it back.
            if deletedHere.contains(payload.id) && !TimerStore.loadAll().contains(where: { $0.id == payload.id }) {
                return presentComposeView()
            }
            let existing = TimerStore.loadAll().first { $0.id == payload.id }
            // A newer re-shared plain link updates the copy we have (CloudKit-linked
            // timers stay with sync) — same rule as the main app's handleIncoming.
            let adoptLink = existing.map { CloudLinkStore.get(timerID: payload.id) == nil && $0.shouldAdopt(payload) } ?? false
            let stored = (adoptLink ? payload : (existing ?? payload)).advancedSequence()
            TimerStore.save(stored)
            // Opening the bubble only (re-)arms when the main app isn't already
            // handling this id through AlarmKit — otherwise this would stack a
            // notification + custom Live Activity on top of AlarmKit's own alert and
            // Live Activity (see TimerStore.isAlarmKitArmed). Mutations made here
            // (`persist`) still arm unconditionally: the extension can't reach AlarmKit
            // to move that alarm, so its own notification is the only alert guaranteed
            // to match the new state until the main app next reconciles.
            // An adopted newer link changes the timing, which the main app's AlarmKit
            // alarm doesn't know yet — arm our own alert like any Messages mutation.
            if adoptLink || !TimerStore.isAlarmKitArmed(id: stored.id) {
                NotificationScheduler.cancel(id: stored.id)
                NotificationScheduler.scheduleAlert(for: stored)
                // Paused: update an existing card, never request one (a paused card has
                // no stale date and would stay forever) — as every other path here does.
                if stored.isPaused { LiveActivityController.update(for: stored) }
                else { LiveActivityController.start(for: stored) }
            }
            presentRunningView(payload: stored)
            acceptShareIfNeeded(from: conversation.selectedMessage?.url, localPayloadID: stored.id)
            if CloudLinkStore.get(timerID: stored.id) != nil {
                // Peek: Messages can't move AlarmKit, so it must not consume these changes
                // (tokens, link drops) — the main app's own pull has to see them too, or a
                // deletion/pause here left its alarm ringing (or paused on the Lock Screen)
                // forever.
                CloudSyncController.pullChanges(peek: true) { updated, deletedIDs in
                    for payload in updated {
                        TimerStore.save(payload)
                        if !TimerStore.isAlarmKitArmed(id: payload.id) {
                            NotificationScheduler.scheduleAlert(for: payload)
                            if payload.isPaused { LiveActivityController.update(for: payload) }
                            else { LiveActivityController.start(for: payload) }
                        }
                    }
                    for id in deletedIDs {
                        TimerStore.delete(id: id)
                        NotificationScheduler.cancel(id: id)
                        NotificationScheduler.cancelReminders(id: id)
                        LiveActivityController.end(id: id)
                    }
                    NotificationCenter.default.post(name: TimerRunningView.storeChange, object: nil)
                }
            }
        } else {
            presentComposeView()
        }
    }

    /// Closes the Phase-1 gap: a recipient who only ever opens this extension (never the
    /// main app's onOpenURL) previously never got a CloudLink, so pushUp/pushDelete
    /// silently no-op'd for them forever — see CloudSyncController.acceptShare, already
    /// present in this target but never called until now. Mirrors
    /// ContentView.handleIncoming. Guarded on CloudLinkStore so it only runs once —
    /// presentView fires on every willBecomeActive/didReceive. This is a receive-path
    /// write, so it goes through TimerStore/NotificationScheduler/LiveActivityController
    /// directly rather than persist(_:action:) — never pushUp here, which would echo the
    /// remote state straight back to the server (see CloudSyncController's own invariant).
    private func acceptShareIfNeeded(from url: URL?, localPayloadID: String) {
        guard CloudLinkStore.get(timerID: localPayloadID) == nil,
              let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shareString = components.queryItems?.first(where: { $0.name == "ckshare" })?.value,
              let shareURL = URL(string: shareString) else { return }

        CloudSyncController.acceptShare(from: shareURL) { [weak self] authoritative in
            guard let authoritative else { return }
            DispatchQueue.main.async {
                // Removed here while the accept was in flight (there was no link yet, so
                // the removal couldn't leave the share): leave it now instead of
                // bringing the timer back.
                if self?.deletedHere.contains(authoritative.id) == true {
                    CloudSyncController.pushDelete(id: authoritative.id)
                    return
                }
                // A pause/extend made while the accept was in flight couldn't push (no
                // CloudLink yet) and is newer than the record — keep it and push it now.
                if let local = TimerStore.loadAll().first(where: { $0.id == authoritative.id }),
                   local.hasChange(newerThan: authoritative) {
                    CloudSyncController.pushUp(local, action: "updated")
                    return
                }
                TimerStore.save(authoritative)
                NotificationCenter.default.post(name: TimerRunningView.storeChange, object: nil)
                guard !TimerStore.isAlarmKitArmed(id: authoritative.id) else { return }
                NotificationScheduler.cancel(id: authoritative.id)
                if authoritative.isPaused {
                    LiveActivityController.update(for: authoritative)
                } else {
                    NotificationScheduler.scheduleAlert(for: authoritative)
                    LiveActivityController.start(for: authoritative)
                }
            }
        }
    }

    private func presentComposeView() {
        let root = AnyView(TimerComposeView(removed: pendingRemoval?.payload, onUndo: { [weak self] in
            self?.undoRemoval()
        }) { [weak self] payload, mode, isExisting in
            self?.send(payload: payload, mode: mode, isExisting: isExisting)
        })
        presentRoot(root)
    }

    /// Delete / Remove from My Timers: everything on this phone goes now; Delete for
    /// Everyone (already confirmed) also reaches everyone now and has no Undo.
    private func remove(_ deleted: TimerPayload) {
        finishPendingRemoval()
        let link = CloudLinkStore.get(timerID: deleted.id)
        let snapshot = RemovalSnapshot(payload: TimerStore.loadAll().first { $0.id == deleted.id } ?? deleted,
                                       readOnly: TimerStore.isReadOnly(id: deleted.id),
                                       alarmKitArmed: TimerStore.isAlarmKitArmed(id: deleted.id),
                                       reminders: TimerReminders.get(deleted.id))
        deletedHere.insert(deleted.id)
        leftMessageURL = activeConversation?.selectedMessage?.url
        TimerStore.delete(id: deleted.id)
        NotificationScheduler.cancel(id: deleted.id)
        NotificationScheduler.cancelReminders(id: deleted.id)
        LiveActivityController.end(id: deleted.id)
        if let link, link.isOwner, link.isShared {
            CloudSyncController.pushDelete(id: deleted.id)
        } else {
            // A share stays joined while Undo is offered, marked left so a pull in the
            // meantime doesn't bring it back (as in the app).
            if link != nil { CloudLinkStore.markLeft(timerID: deleted.id) }
            pendingRemoval = snapshot
            let work = DispatchWorkItem { [weak self] in self?.finishPendingRemoval() }
            removalWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
        presentComposeView()
    }

    /// The Undo window ended (or something else needs a settled state): a participant
    /// leaves the share for good (`pushDelete` drops the link, never the record); a
    /// local timer has nothing left to do.
    private func finishPendingRemoval() {
        removalWork?.cancel()
        removalWork = nil
        guard let removed = pendingRemoval else { return }
        pendingRemoval = nil
        CloudSyncController.pushDelete(id: removed.payload.id)
    }

    private func undoRemoval() {
        removalWork?.cancel()
        removalWork = nil
        guard let removed = pendingRemoval else { return }
        pendingRemoval = nil
        let restored = removed.payload.advancedSequence()
        CloudLinkStore.clearLeft(timerID: restored.id)
        TimerStore.save(restored)
        // `TimerStore.delete` cleared both flags: a view-only share must stay view only,
        // and a timer the app arms through AlarmKit (an alarm Messages never cancelled)
        // must not get a second alert from here.
        if removed.readOnly { TimerStore.setReadOnly(id: restored.id, true) }
        if removed.alarmKitArmed {
            TimerStore.setAlarmKitArmed(id: restored.id, true)
        } else if restored.isPaused || restored.isExpired {
            LiveActivityController.update(for: restored)
        } else {
            NotificationScheduler.scheduleAlert(for: restored)
            LiveActivityController.start(for: restored)
        }
        TimerReminders.set(removed.reminders, for: restored.id)
        TimerReminders.sync(restored)
        deletedHere.remove(restored.id)
        leftMessageURL = nil
        if CloudLinkStore.get(timerID: restored.id) != nil {
            CloudSyncController.refreshPermissions(for: [restored.id]) {
                // On main: the open view's observer writes SwiftUI state.
                DispatchQueue.main.async { NotificationCenter.default.post(name: TimerRunningView.storeChange, object: nil) }
            }
        }
        presentRunningView(payload: restored)
    }

    private func presentRunningView(payload: TimerPayload) {
        hasStagedAttribution = false
        let root = AnyView(TimerRunningView(
            payload: payload,
            onNewTimer: { [weak self] in
                #if DEBUG
                Self.debugLog("newTimer selected=\(self?.activeConversation?.selectedMessage.flatMap { TimerPayload.from(url: $0.url)?.id.prefix(8) } ?? "nil")")
                #endif
                self?.leftMessageURL = self?.activeConversation?.selectedMessage?.url
                self?.presentComposeView()
            },
            onUpdate: { [weak self] updated, action in
                self?.persist(updated, action: action)
            },
            onDelete: { [weak self] deleted in
                self?.remove(deleted)
            },
            onSendUpdate: { [weak self] current in
                self?.send(payload: current, mode: .appCard, isExisting: true)
            }
        ).id(payload.url().absoluteString))
        presentRoot(root)
    }

    private func persist(_ payload: TimerPayload, action: String) {
        // View-only share: only the clock-driven phase advance may be stored.
        guard action == "sequenceAdvanced" || !TimerStore.isReadOnly(id: payload.id) else { return }
        // An edit that leaves the finish where it was (a rename, a toggle) on a timer the
        // app arms through AlarmKit: that alarm still rings at the right time, so a
        // notification and card from here would only double it until the app re-arms.
        let prior = TimerStore.loadAll().first { $0.id == payload.id }
        let appAlarmStillRight = action == "edited" && TimerStore.isAlarmKitArmed(id: payload.id)
            && !TimerStore.finishMoved(from: prior, to: payload)
        TimerStore.save(payload)
        // Reminders were planned for the old finish: re-plan them for the new one (none
        // while paused). The app re-plans them too when it next arms this timer.
        if action != "sequenceAdvanced" { TimerReminders.sync(payload) }
        if !appAlarmStillRight && (action != "sequenceAdvanced" || !TimerStore.isAlarmKitArmed(id: payload.id)) {
            NotificationScheduler.cancel(id: payload.id)
            if payload.isPaused {
                LiveActivityController.update(for: payload)
            } else {
                NotificationScheduler.scheduleAlert(for: payload)
                LiveActivityController.start(for: payload)
            }
        }
        if action != "sequenceAdvanced" {
            CloudSyncController.pushUp(payload, action: action)
            stageAttributionText(for: payload, action: action)
        }
    }

    /// Stages — never sends — a one-line "Sam paused Pasta — 5:22 left" into the
    /// conversation's input field for a local pause/resume/extend on a shared timer. An
    /// extension can only fill the input, never post on its own; the person still has to
    /// tap send. Only the first mutation per presentation stages anything — insertText
    /// replaces the field's content each call, so repeated taps would otherwise stomp on
    /// whatever the person already typed in response. No-ops when there's no active
    /// conversation (e.g. torn down mid-flight) or the timer isn't cloud-linked, matching
    /// every other CloudKit-absence no-op here.
    private func stageAttributionText(for payload: TimerPayload, action: String) {
        guard !hasStagedAttribution,
              let conversation = activeConversation,
              CloudLinkStore.get(timerID: payload.id)?.isShared == true else { return }
        hasStagedAttribution = true
        let name = DisplayNameStore.name ?? String(localized: "Someone")
        // The wire verb is English ("paused"); translate the whole phrase per verb, as
        // the detail screen does — never interpolate the verb itself.
        let phrase = CloudSyncController.attributionPhrase(name: name, action: action)
        let remaining = TimeFormat.display(payload.remaining)
        conversation.insertText(String(localized: "\(phrase) \(payload.label) — \(remaining) left")) { error in
            if let error {
                print("SharedTimer insertText (attribution) error: \(error)")
            }
        }
    }

    private func presentRoot(_ root: AnyView) {
        if let hosting = hostingController {
            hosting.rootView = root
        } else {
            let hosting = UIHostingController(rootView: root)
            addChild(hosting)
            hosting.view.backgroundColor = UIColor(Sky.room)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            hosting.didMove(toParent: self)
            hostingController = hosting
        }
    }

    /// The local timer starts unconditionally first — sharing always works locally even
    /// if the cloud call fails or times out. `CloudSyncController.createShare` has its
    /// own internal ~4s timeout and always calls back with either a share URL or nil;
    /// nil means "send exactly today's plain link," which is what makes the added
    /// network dependency safe rather than a regression.
    private func send(payload picked: TimerPayload, mode: TimerShareMode, isExisting: Bool) {
        // A second tap while the share is being prepared (up to ~4s) created a second
        // timer, share and bubble.
        guard let conversation = activeConversation, !isSending else { return }
        finishPendingRemoval()
        isSending = true

        let payload: TimerPayload
        if let stored = TimerStore.loadAll().first(where: { $0.id == picked.id }) {
            // Re-sharing an existing timer: send its newest state, and leave its alerts
            // alone — re-saving the copy the picker loaded overwrote changes made since,
            // and a notification here doubled up on an AlarmKit alarm the app owns.
            payload = stored.advancedSequence()
        } else if isExisting {
            // Deleted (here or on another device) after the picker loaded it — saving the
            // picker's copy would bring it back.
            isSending = false
            return
        } else {
            payload = picked
            TimerStore.save(payload)
            NotificationScheduler.scheduleAlert(for: payload)
            TimerReminders.sync(payload)
            // The card used to appear only after reopening its bubble.
            LiveActivityController.start(for: payload)
        }

        promptForDisplayNameIfNeeded {
            CloudSyncController.createShare(for: payload) { [weak self] shareURL in
                DispatchQueue.main.async {
                    self?.isSending = false
                    self?.deliver(payload: payload, mode: mode, shareURL: shareURL, conversation: conversation)
                }
            }
        }
    }

    private var isSending = false

    /// One-time prompt for DisplayNameStore.name — see DisplayNameStore.swift. Skipping
    /// (Skip, or dismissing) just falls back to "Someone" in attribution; nothing here
    /// blocks on it, including this call site itself, which proceeds either way.
    private func promptForDisplayNameIfNeeded(then completion: @escaping () -> Void) {
        guard DisplayNameStore.shouldPrompt else {
            completion()
            return
        }
        let alert = UIAlertController(
            title: String(localized: "What should we call you?"),
            message: String(localized: "Shown to people you share timers with, like \"Sam paused Pasta.\" You can change it any time in Timer's Settings."),
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = String(localized: "Your name") }
        alert.addAction(UIAlertAction(title: String(localized: "Skip"), style: .cancel) { _ in
            DisplayNameStore.declined = true
            completion()
        })
        alert.addAction(UIAlertAction(title: String(localized: "Continue"), style: .default) { [weak alert] _ in
            let trimmed = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { DisplayNameStore.name = trimmed }
            completion()
        })
        present(alert, animated: true)
    }

    private func deliver(payload: TimerPayload, mode: TimerShareMode, shareURL: URL?, conversation: MSConversation) {
        let link = payload.url(liveShare: shareURL)
        // A share sent: the person is done with the compose form, so a later tap on the
        // bubble they left shows its timer again.
        leftMessageURL = nil

        switch mode {
        case .link:
            let text = "\(payload.shareMessage)\n\(link.absoluteString)"
            conversation.insertText(text) { [weak self] error in
                if let error {
                    print("SharedTimer insertText error: \(error)")
                }
                self?.dismiss()
            }

        case .appCard:
            // Re-sharing while this timer's own card is the selected message continues its
            // session, and Messages collapses the older card to its summary (seen in the
            // simulator, iOS 27.2, 2026-11-27). Only then: reusing the same session (even
            // the same session id, archived) without the card selected leaves both cards
            // full — checked both ways (M11). A new card starts its own session.
            let selected = conversation.selectedMessage
            let selectedSession = selected.flatMap { TimerPayload.from(url: $0.url)?.id } == payload.id ? selected?.session : nil
            let session = selectedSession ?? MSSession()
            let message = MSMessage(session: session)
            #if DEBUG
            Self.debugLog("deliver selected=\(selected != nil) selectedSession=\(selectedSession.map { "\($0)" } ?? "nil") using=\(session) payload=\(payload.id.prefix(8))")
            #endif
            let layout = MSMessageTemplateLayout()
            layout.caption = payload.label
            layout.subcaption = payload.isExpired ? "Timer done" : subcaption(for: payload)
            message.layout = layout
            message.url = link
            message.summaryText = "Shared \(payload.kind == .countdown ? "countdown" : "timer"): \(payload.label)"

            conversation.insert(message) { [weak self] error in
                if let error {
                    print("SharedTimer insert error: \(error)")
                }
                self?.dismiss()
            }
        }
    }

    /// The card's second line (English, like the rest of the card — see CLAUDE.md). A
    /// clock time was formatted in the sender's zone and stale for a paused timer; the
    /// timer's own length reads right anywhere.
    private func subcaption(for payload: TimerPayload) -> String {
        if payload.isPending(), let start = payload.scheduledStartDate { return "Starts \(TimeFormat.targetDate(start))" }
        if payload.isPaused { return "Paused · \(TimeFormat.display(payload.remaining)) left" }
        if payload.sequence != nil || payload.kind == .timer { return payload.shareSummary }
        return "→ \(TimeFormat.targetDate(payload.endDate))"
    }
}

/// What a removal took away, for Undo.
private struct RemovalSnapshot {
    let payload: TimerPayload
    let readOnly: Bool
    let alarmKitArmed: Bool
    let reminders: Set<TimerReminder>
}
