//
//  MessagesViewController.swift
//  sharedTimerMessages
//

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {

    private var hostingController: UIHostingController<AnyView>?

    override func willBecomeActive(with conversation: MSConversation) {
        presentComposeView()
        if presentationStyle == .compact {
            requestPresentationStyle(.expanded)
        }
    }

    private func presentComposeView() {
        let root = AnyView(TimerComposeView { [weak self] payload in
            self?.send(payload: payload)
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

        presentRunningView(payload: payload)
    }
}
