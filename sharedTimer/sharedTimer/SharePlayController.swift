//
//  SharePlayController.swift
//  sharedTimer
//
//  SharePlay (1.0.7, D11): run a timer together in a FaceTime call. The activity
//  carries the timer's share link — the same snapshot format Messages and QR codes
//  use — so everyone in the call gets the timer, and every Pause/Extend/Repeat made
//  by anyone is sent to the others as a fresh link. A received link is applied only
//  when its `upd` stamp is newer (`TimerPayload.shouldAdopt`), as for re-opened
//  links, so messages crossing in flight can't roll a timer back. Apple's servers
//  carry it — no server of ours, nothing collected.
//
//  Main app only. Needs the Group Activities capability on the App ID and the
//  com.apple.developer.group-session entitlement. Only testable with two devices in a
//  FaceTime call.
//

import Combine
import Foundation
import GroupActivities

struct TimerGroupActivity: GroupActivity {
    static let activityIdentifier = "com.lokesh.sharedTimer.timer"

    /// `TimerPayload.url()` of the timer when the activity started.
    let link: String
    let label: String

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = label
        metadata.subtitle = String(localized: "Timer")
        metadata.type = .generic
        metadata.fallbackURL = URL(string: link)
        return metadata
    }
}

/// One timer update sent to the others in the call.
private struct TimerUpdateMessage: Codable {
    let link: String
}

@MainActor
final class SharePlayController: ObservableObject {
    static let shared = SharePlayController()

    /// The timer being shared with the call, nil when none.
    @Published private(set) var sharedTimerID: String?
    @Published private(set) var participantCount = 0
    /// True while a FaceTime call can take a SharePlay activity.
    @Published private(set) var isEligible = false

    /// Applies a timer received from the call (wired by ContentView).
    var onReceive: ((TimerPayload) -> Void)?

    private var session: GroupSession<TimerGroupActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: Set<Task<Void, Never>> = []
    private var subscriptions: Set<AnyCancellable> = []
    private let observer = GroupStateObserver()

    private init() {
        isEligible = observer.isEligibleForGroupSession
        observer.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isEligible = $0 }
            .store(in: &subscriptions)
        tasks.insert(Task { [weak self] in
            for await session in TimerGroupActivity.sessions() {
                self?.join(session)
            }
        })
    }

    /// Offers this timer to the current FaceTime call.
    func start(_ payload: TimerPayload) async {
        let activity = TimerGroupActivity(link: payload.url().absoluteString, label: payload.label)
        if case .activationPreferred = await activity.prepareForActivation() {
            _ = try? await activity.activate()
        }
    }

    func leave() {
        session?.leave()
        reset()
    }

    /// Sends a local change of the shared timer to the others in the call.
    func send(_ payload: TimerPayload) {
        guard payload.id == sharedTimerID, let messenger else { return }
        let message = TimerUpdateMessage(link: payload.url().absoluteString)
        Task { try? await messenger.send(message) }
    }

    private func join(_ session: GroupSession<TimerGroupActivity>) {
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger
        if let payload = TimerPayload.from(url: URL(string: session.activity.link)) {
            sharedTimerID = payload.id
            onReceive?(payload)
        }
        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                let joined = participants.count > self.participantCount
                self.participantCount = participants.count
                // A late joiner only has the activity's start link; send the current
                // state (receivers keep the newest by its `upd` stamp).
                if joined, let id = self.sharedTimerID,
                   let current = TimerStore.loadAll().first(where: { $0.id == id }) {
                    self.send(current)
                }
            }
            .store(in: &subscriptions)
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .invalidated = state { self?.reset() }
            }
            .store(in: &subscriptions)
        tasks.insert(Task { [weak self] in
            for await (message, _) in messenger.messages(of: TimerUpdateMessage.self) {
                guard let payload = TimerPayload.from(url: URL(string: message.link)) else { continue }
                await MainActor.run { self?.onReceive?(payload) }
            }
        })
        session.join()
    }

    private func reset() {
        session = nil
        messenger = nil
        sharedTimerID = nil
        participantCount = 0
    }
}
