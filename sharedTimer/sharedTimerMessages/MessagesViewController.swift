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
            if let existing = TimerStore.loadAll().first(where: { $0.id == payload.id }) {
                // Already ours — either we sent it, or we added it earlier. Keep it live.
                NotificationScheduler.scheduleAlert(for: existing)
                LiveActivityController.start(for: existing)
                presentRunningView(payload: existing, isAdded: true)
            } else {
                // Shared by someone else: preview only, until they explicitly add it.
                presentRunningView(payload: payload, isAdded: false)
            }
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

    private func presentRunningView(payload: TimerPayload, isAdded: Bool) {
        let root = AnyView(TimerRunningView(
            payload: payload,
            isAdded: isAdded,
            onNewTimer: { [weak self] in
                self?.presentComposeView()
            },
            onAdd: { [weak self] added in
                self?.persist(added)
            },
            onUpdate: { [weak self] updated in
                self?.persist(updated)
            },
            onDelete: { [weak self] deleted in
                TimerStore.delete(id: deleted.id)
                NotificationScheduler.cancel(id: deleted.id)
                LiveActivityController.end(id: deleted.id)
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
    }

    private func presentRoot(_ root: AnyView) {
        if let hosting = hostingController {
            hosting.rootView = root
        } else {
            let hosting = UIHostingController(rootView: root)
            addChild(hosting)
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

    private func send(payload: TimerPayload, mode: TimerShareMode) {
        guard let conversation = activeConversation else { return }

        TimerStore.save(payload)
        NotificationScheduler.scheduleAlert(for: payload)
        LiveActivityController.start(for: payload)

        switch mode {
        case .link:
            let text = "\(shareEmoji(for: payload)) \(payload.label) — \(shareSummary(for: payload))\n\(payload.url().absoluteString)"
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
            message.url = payload.url()
            message.summaryText = "Shared \(payload.kind == .countdown ? "countdown" : "timer"): \(payload.label)"

            conversation.insert(message) { [weak self] error in
                if let error {
                    print("SharedTimer insert error: \(error)")
                }
                self?.dismiss()
            }
        }
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
