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

    override func viewDidLoad() {
        super.viewDidLoad()
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
        presentView(for: conversation)
        if presentationStyle == .compact {
            requestPresentationStyle(.expanded)
        }
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        presentView(for: conversation)
    }

    private func presentView(for conversation: MSConversation) {
        if let payload = TimerPayload.from(url: conversation.selectedMessage?.url) {
            let stored = TimerStore.loadAll().first { $0.id == payload.id } ?? payload
            TimerStore.save(stored)
            NotificationScheduler.scheduleAlert(for: stored)
            LiveActivityController.start(for: stored)
            presentRunningView(payload: stored)
            acceptShareIfNeeded(from: conversation.selectedMessage?.url, localPayloadID: stored.id)
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

        CloudSyncController.acceptShare(from: shareURL) { authoritative in
            guard let authoritative else { return }
            DispatchQueue.main.async {
                TimerStore.save(authoritative)
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
        let root = AnyView(TimerComposeView { [weak self] payload, mode in
            self?.send(payload: payload, mode: mode)
        })
        presentRoot(root)
    }

    private func presentRunningView(payload: TimerPayload) {
        hasStagedAttribution = false
        let root = AnyView(TimerRunningView(
            payload: payload,
            onNewTimer: { [weak self] in
                self?.presentComposeView()
            },
            onUpdate: { [weak self] updated, action in
                self?.persist(updated, action: action)
            },
            onDelete: { [weak self] deleted in
                TimerStore.delete(id: deleted.id)
                NotificationScheduler.cancel(id: deleted.id)
                LiveActivityController.end(id: deleted.id)
                CloudSyncController.pushDelete(id: deleted.id)
                self?.presentComposeView()
            }
        ))
        presentRoot(root)
    }

    private func persist(_ payload: TimerPayload, action: String) {
        TimerStore.save(payload)
        NotificationScheduler.cancel(id: payload.id)
        if payload.isPaused {
            LiveActivityController.update(for: payload)
        } else {
            NotificationScheduler.scheduleAlert(for: payload)
            LiveActivityController.start(for: payload)
        }
        CloudSyncController.pushUp(payload, action: action)
        stageAttributionText(for: payload, action: action)
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
              CloudLinkStore.get(timerID: payload.id) != nil else { return }
        hasStagedAttribution = true
        let name = DisplayNameStore.name ?? "Someone"
        let remaining = TimeFormat.display(payload.remaining)
        conversation.insertText("\(name) \(action) \(payload.label) — \(remaining) left") { error in
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
    private func send(payload: TimerPayload, mode: TimerShareMode) {
        guard let conversation = activeConversation else { return }

        TimerStore.save(payload)
        NotificationScheduler.scheduleAlert(for: payload)
        LiveActivityController.start(for: payload)

        promptForDisplayNameIfNeeded {
            CloudSyncController.createShare(for: payload) { [weak self] shareURL in
                DispatchQueue.main.async {
                    self?.deliver(payload: payload, mode: mode, shareURL: shareURL, conversation: conversation)
                }
            }
        }
    }

    /// One-time prompt for DisplayNameStore.name — see DisplayNameStore.swift. Skipping
    /// (Skip, or dismissing) just falls back to "Someone" in attribution; nothing here
    /// blocks on it, including this call site itself, which proceeds either way.
    private func promptForDisplayNameIfNeeded(then completion: @escaping () -> Void) {
        guard DisplayNameStore.name == nil else {
            completion()
            return
        }
        let alert = UIAlertController(
            title: "What should we call you?",
            message: "Shown to people you share timers with, like \"Sam paused Pasta.\"",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "Your name" }
        alert.addAction(UIAlertAction(title: "Skip", style: .cancel) { _ in completion() })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak alert] _ in
            let trimmed = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { DisplayNameStore.name = trimmed }
            completion()
        })
        present(alert, animated: true)
    }

    private func deliver(payload: TimerPayload, mode: TimerShareMode, shareURL: URL?, conversation: MSConversation) {
        let link = outgoingURL(for: payload, shareURL: shareURL)

        switch mode {
        case .link:
            let text = "\(shareEmoji(for: payload)) \(payload.label) — \(shareSummary(for: payload))\n\(link.absoluteString)"
            conversation.insertText(text) { [weak self] error in
                if let error {
                    print("SharedTimer insertText error: \(error)")
                }
                self?.dismiss()
            }

        case .appCard:
            let message = MSMessage()
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

    /// `payload.url()`'s wire format is untouched — the CloudKit share URL rides along
    /// as an extra query param that App Clip / docs/t.html already ignore silently.
    private func outgoingURL(for payload: TimerPayload, shareURL: URL?) -> URL {
        guard let shareURL,
              var components = URLComponents(url: payload.url(), resolvingAgainstBaseURL: false) else {
            return payload.url()
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "ckshare", value: shareURL.absoluteString))
        components.queryItems = items
        return components.url ?? payload.url()
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func shareEmoji(for payload: TimerPayload) -> String {
        payload.kind == .countdown ? "📅" : "⏱️"
    }

    private func shareSummary(for payload: TimerPayload) -> String {
        switch payload.kind {
        case .timer:
            let minutes = Int((payload.duration / 60).rounded())
            return "\(minutes) min timer"
        case .countdown:
            return "counting down to \(TimeFormat.targetDate(payload.endDate))"
        }
    }

    private func subcaption(for payload: TimerPayload) -> String {
        switch payload.kind {
        case .timer:
            return "Ends at \(formattedTime(payload.endDate))"
        case .countdown:
            return "→ \(TimeFormat.targetDate(payload.endDate))"
        }
    }
}
