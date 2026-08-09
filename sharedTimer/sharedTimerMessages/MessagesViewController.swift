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
            presentRunningView(payload: payload)
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
        let root = AnyView(TimerRunningView(payload: payload) { [weak self] in
            self?.presentComposeView()
        })
        presentRoot(root)
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

        switch mode {
        case .link:
            let minutes = Int((payload.duration / 60).rounded())
            let text = "⏱️ \(payload.label) — \(minutes) min timer\n\(payload.url().absoluteString)"
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
            layout.subcaption = payload.isExpired ? "Timer done" : "Ends at \(formattedTime(payload.endDate))"
            message.layout = layout
            message.url = payload.url()
            message.summaryText = "Shared timer: \(payload.label)"

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
}
