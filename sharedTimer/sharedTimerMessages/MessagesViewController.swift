//
//  MessagesViewController.swift
//  sharedTimerMessages
//

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<AnyView>?

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
        } else {
            presentComposeView()
        }
    }

    private func presentComposeView() {
        let root = AnyView(TimerComposeView { [weak self] payload, mode in
            self?.send(payload: payload, mode: mode)
        })
        presentRoot(root)
    }

    private func presentRunningView(payload: TimerPayload) {
        let root = AnyView(TimerRunningView(
            payload: payload,
            onNewTimer: { [weak self] in
                self?.presentComposeView()
            },
            onUpdate: { [weak self] updated in
                self?.persist(updated)
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

    private func persist(_ payload: TimerPayload) {
        TimerStore.save(payload)
        NotificationScheduler.cancel(id: payload.id)
        if payload.isPaused {
            LiveActivityController.update(for: payload)
        } else {
            NotificationScheduler.scheduleAlert(for: payload)
            LiveActivityController.start(for: payload)
        }
        CloudSyncController.pushUp(payload)
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

        CloudSyncController.createShare(for: payload) { [weak self] shareURL in
            DispatchQueue.main.async {
                self?.deliver(payload: payload, mode: mode, shareURL: shareURL, conversation: conversation)
            }
        }
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
