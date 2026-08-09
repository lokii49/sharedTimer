//
//  MessagesViewController.swift
//  sharedTimerMessages
//

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<TimerComposeView>?

    override func willBecomeActive(with conversation: MSConversation) {
        presentComposeView()
        if presentationStyle == .compact {
            requestPresentationStyle(.expanded)
        }
    }

    private func presentComposeView() {
        let root = TimerComposeView { [weak self] payload in
            self?.send(payload: payload)
        }

        if let hosting = hostingController {
            hosting.rootView = root
        } else {
            let hosting = UIHostingController(rootView: root)
            addChild(hosting)
            hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
            hostingController = hosting
        }
    }

    private func send(payload: TimerPayload) {
        guard let conversation = activeConversation else { return }
        let minutes = Int(payload.remaining / 60)
        let text = "⏱️ \(payload.label) — \(minutes) min timer\n\(payload.url().absoluteString)"

        conversation.insertText(text) { error in
            if let error {
                print("SharedTimer insertText error: \(error)")
            }
        }
    }
}
