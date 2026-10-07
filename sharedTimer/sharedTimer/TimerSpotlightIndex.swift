import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Stable metadata: no ticking "N seconds left" text that would become stale in search.
struct TimerSpotlightEntry: Equatable {
    let timerID: String
    let title: String
    let description: String
    let keywords: [String]
    let expirationDate: Date
    let modifiedAt: Date?

    func searchableItem(domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = description
        attributes.keywords = keywords
        attributes.contentModificationDate = modifiedAt
        let item = CSSearchableItem(uniqueIdentifier: TimerSpotlightIndex.identifier(for: timerID, domain: domain), domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = expirationDate
        return item
    }
}

/// App-only indexing. A write observer has no work in the widget/Messages/Clip;
/// their changes are reconciled from the shared store when the app next runs.
@MainActor
final class TimerSpotlightIndex: NSObject, CSSearchableIndexDelegate {
    nonisolated static let domain = "com.lokesh.sharedTimer.timers"
    static let shared = TimerSpotlightIndex()

    private let index: CSSearchableIndex
    private let itemDomain: String
    private let loadPayloads: @MainActor () -> [TimerPayload]
    private var indexed: [String: TimerSpotlightEntry]?
    private var pending = false
    private var rebuild = false
    private var work: Task<Void, Never>?
    private var started = false
    private(set) var lastError: Error?

    init(domain: String = TimerSpotlightIndex.domain, loadPayloads: @escaping @MainActor () -> [TimerPayload] = TimerStore.loadAll) {
        itemDomain = domain
        index = CSSearchableIndex(name: domain)
        self.loadPayloads = loadPayloads
        super.init()
        index.indexDelegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        // The callback runs under TimerStore's write lock: only enqueue a task here.
        // Read the newest snapshot later, after the lock is released.
        TimerStore.didPersist = {
            Task { @MainActor in TimerSpotlightIndex.shared.requestRefresh() }
        }
        requestRefresh()
    }

    func requestRefresh() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        pending = true
        guard work == nil else { return }
        work = Task { await drain() }
    }

    /// Background intents await indexing before returning and losing their process.
    @discardableResult
    func refreshAwaiting() async -> Bool {
        requestRefresh()
        await work?.value
        return CSSearchableIndex.isIndexingAvailable() && lastError == nil
    }

    private func drain() async {
        while pending {
            pending = false
            let entries = Self.entries(from: loadPayloads())
            let current = Dictionary(entries.map { ($0.timerID, $0) }, uniquingKeysWith: { _, latest in latest })
            let previous = indexed ?? [:]
            let reset = rebuild || indexed == nil
            rebuild = false
            do {
                // Reconcile persisted old results once on launch/reindex, including
                // deletes made in an extension while this process was absent.
                if reset {
                    try await index.deleteSearchableItems(withDomainIdentifiers: [itemDomain])
                } else {
                    let removed = previous.keys.filter { current[$0] == nil }
                    if !removed.isEmpty {
                        try await index.deleteSearchableItems(withIdentifiers: removed.map { Self.identifier(for: $0, domain: itemDomain) })
                    }
                }
                let changed = entries.filter { reset || previous[$0.timerID] != $0 }
                if !changed.isEmpty {
                    try await index.indexSearchableItems(changed.map { $0.searchableItem(domain: itemDomain) })
                }
                indexed = current
                lastError = nil
            } catch {
                // Keep local timer operations successful; retry a full reconciliation
                // on the next store change or foreground, rather than looping offline.
                indexed = nil
                lastError = error
                print("[TimerSpotlightIndex] \(error)")
            }
        }
        work = nil
    }

    nonisolated static func identifier(for timerID: String, domain: String = domain) -> String {
        "\(domain):\(timerID)"
    }

    nonisolated static func timerID(from identifier: String, domain: String = domain) -> String? {
        let prefix = domain + ":"
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func entries(from payloads: [TimerPayload], at date: Date = Date()) -> [TimerSpotlightEntry] {
        payloads.compactMap { stored in
            let payload = stored.advancedSequence(at: date)
            let exhausted = payload.sequence.map { $0.loopIndex >= $0.loopCount } ?? false
            let remaining = payload.pausedRemaining ?? payload.endDate.timeIntervalSince(date)
            let finished = exhausted || remaining <= 0
            let type = payload.sequence != nil ? "Sequence" : payload.kind == .countdown ? "Countdown" : "Timer"
            let description: String
            if finished {
                description = "\(type) · Finished"
            } else if payload.isPending(at: date), let start = payload.scheduledStartDate {
                description = "\(type) · Starts \(start.formatted(date: .abbreviated, time: .shortened))"
            } else if payload.isPaused {
                description = "\(type) · Paused"
            } else {
                description = "\(type) · Ends \(payload.endDate.formatted(date: .abbreviated, time: .shortened))"
            }
            let expiry: Date
            if payload.isPaused && !finished {
                expiry = .distantFuture
            } else {
                let phases = payload.sequence.map { $0.phases.count * $0.loopCount } ?? 1
                let finalEnd = !finished ? payload.upcomingSequencePhases(limit: phases).last?.endDate ?? payload.endDate : payload.endDate
                expiry = finalEnd.addingTimeInterval(86400)
            }
            guard expiry > date else { return nil }
            let keywords = ["timer", type.lowercased()] + (payload.sequence?.phases.map(\.label) ?? [])
            return TimerSpotlightEntry(timerID: payload.id, title: payload.label, description: description, keywords: keywords, expirationDate: expiry, modifiedAt: payload.updatedAt)
        }
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        Task { @MainActor in
            rebuild = true
            await refreshAwaiting()
            acknowledgementHandler()
        }
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        // A full current snapshot also removes stale requested IDs.
        Task { @MainActor in
            rebuild = true
            await refreshAwaiting()
            acknowledgementHandler()
        }
    }
}
