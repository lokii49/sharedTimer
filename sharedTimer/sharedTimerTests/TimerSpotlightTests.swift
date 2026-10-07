import CoreSpotlight
import Foundation
import Testing
@testable import sharedTimer

@Suite(.serialized) @MainActor
struct TimerSpotlightTests {
    @Test func identifiersRouteOnlyThisAppsTimersAndKeepArbitraryStableIDs() {
        for id in ["uuid-like-id", "shared:timer/123", "Café"] {
            #expect(TimerSpotlightIndex.timerID(from: TimerSpotlightIndex.identifier(for: id)) == id)
        }
        #expect(TimerSpotlightIndex.timerID(from: "another.app:timer") == nil)
        #expect(TimerSpotlightIndex.timerID(from: TimerSpotlightIndex.domain + ":") == nil)
        #expect(TimerSpotlightIndex.timerID(from: TimerSpotlightIndex.domain + "extra:timer") == nil)
    }

    @Test func entriesExpireFinishedTimersButKeepLongPausedTimers() {
        let now = Date()
        let expired = TimerPayload(id: "old", label: "Old", endDate: now.addingTimeInterval(-86401), duration: 60)
        let finished = TimerPayload(id: "recent", label: "Recent", endDate: now.addingTimeInterval(-60), duration: 60)
        let paused = TimerPayload(id: "paused", label: "Paused", endDate: now.addingTimeInterval(-100000), duration: 60, pausedRemaining: 30)
        let pausedZero = TimerPayload(id: "zero", label: "Zero", endDate: now.addingTimeInterval(-60), duration: 60, pausedRemaining: 0)
        let entries = TimerSpotlightIndex.entries(from: [expired, finished, paused, pausedZero], at: now)
        #expect(entries.map(\.timerID) == ["recent", "paused", "zero"])
        #expect(entries[0].description.contains("Finished"))
        #expect(entries[0].expirationDate == finished.endDate.addingTimeInterval(86400))
        #expect(entries[1].description.contains("Paused"))
        #expect(entries[1].expirationDate == .distantFuture)
        #expect(entries[2].description.contains("Finished"))
    }

    @Test func sequenceMetadataCatchesUpAndExpiresAfterTheFinalPhase() throws {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let stale = TimerPayload(id: "sequence", label: "Work", endDate: now.addingTimeInterval(-10), duration: 60, sequence: SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0))
        let entry = try #require(TimerSpotlightIndex.entries(from: [stale], at: now).first)
        #expect(entry.title == "Rest")
        #expect(entry.description.contains("Sequence"))
        #expect(entry.keywords.contains("Work"))
        #expect(entry.keywords.contains("Rest"))
        #expect(entry.expirationDate == now.addingTimeInterval(110 + 86400))
        let stillKept = TimerSpotlightIndex.entries(from: [stale], at: now.addingTimeInterval(86509))
        let expired = TimerSpotlightIndex.entries(from: [stale], at: now.addingTimeInterval(86511))
        #expect(stillKept.count == 1)
        #expect(expired.isEmpty)
    }

    @Test func scheduledAndCancelledSequencesHaveDistinctSearchDescriptions() throws {
        let now = Date()
        let pending = TimerPayload.composeSequence(label: "Later", phases: [SequencePhase(label: "Work", duration: 60)], loopCount: 1, startDate: now.addingTimeInterval(120))
        let entry = try #require(TimerSpotlightIndex.entries(from: [pending], at: now).first)
        #expect(entry.description.contains("Starts"))
        var cancelled = pending
        cancelled.sequence?.loopIndex = 1
        let cancelledEntry = try #require(TimerSpotlightIndex.entries(from: [cancelled], at: now).first)
        #expect(cancelledEntry.description.contains("Finished"))
    }

    @Test func searchableItemsCarryStableIdentityAndCurrentMetadata() throws {
        let now = Date()
        let payload = TimerPayload(id: "same", label: "Pasta", endDate: now.addingTimeInterval(300), duration: 300, kind: .countdown, updatedAt: now)
        let entry = try #require(TimerSpotlightIndex.entries(from: [payload], at: now).first)
        let item = entry.searchableItem(domain: TimerSpotlightIndex.domain)
        #expect(item.uniqueIdentifier == TimerSpotlightIndex.identifier(for: payload.id))
        #expect(item.domainIdentifier == TimerSpotlightIndex.domain)
        #expect(item.attributeSet.title == "Pasta")
        #expect(item.attributeSet.contentDescription?.contains("Countdown") == true)
        #expect(item.attributeSet.contentModificationDate == now)
        #expect(item.expirationDate == payload.endDate.addingTimeInterval(86400))
    }

    // Real index journaling/querying. Dedicated domain and in-memory source mean the
    // test never edits someone's timers or their production search results.
    @Test(.enabled(if: CSSearchableIndex.isIndexingAvailable()))
    func actualIndexSupportsUpdateDeletionAndReconciliation() async throws {
        let token = UUID().uuidString
        let domain = "com.lokesh.sharedTimer.spotlight-tests." + token
        let title = "SpotlightTest" + token
        var payloads = [TimerPayload(id: token, label: title, duration: 300)]
        let index = TimerSpotlightIndex(domain: domain, loadPayloads: { payloads })
        do {
            #expect(await index.refreshAwaiting())
            let added = try await awaitResults(title: title, domain: domain, count: 1)
            #expect(added.first?.attributeSet.contentDescription?.contains("Ends") == true)
            payloads[0] = payloads[0].paused()
            #expect(await index.refreshAwaiting())
            let paused = try await awaitResults(title: title, domain: domain, count: 1, description: "Paused")
            #expect(paused.first?.attributeSet.contentDescription?.contains("Paused") == true)
            payloads.removeAll()
            #expect(await index.refreshAwaiting())
            let deleted = try await awaitResults(title: title, domain: domain, count: 0)
            #expect(deleted.isEmpty)

            // A new process has no cache: reconcile old indexed IDs against the store.
            payloads = [TimerPayload(id: token, label: title, duration: 300)]
            #expect(await index.refreshAwaiting())
            let restored = try await awaitResults(title: title, domain: domain, count: 1)
            #expect(restored.count == 1)
            let relaunched = TimerSpotlightIndex(domain: domain, loadPayloads: { [] })
            #expect(await relaunched.refreshAwaiting())
            let reconciled = try await awaitResults(title: title, domain: domain, count: 0)
            #expect(reconciled.isEmpty)
        } catch {
            payloads.removeAll()
            await index.refreshAwaiting()
            throw error
        }
    }

    /// Journaling completing doesn't mean the search engine has caught up, so poll —
    /// against a time budget rather than a try count, since one query can itself take
    /// seconds on a busy machine. Returns as soon as the expected state is visible.
    private func awaitResults(title: String, domain: String, count: Int, description: String? = nil,
                              timeout: Duration = .seconds(30)) async throws -> [CSSearchableItem] {
        let deadline = ContinuousClock.now + timeout
        var results: [CSSearchableItem] = []
        repeat {
            results = try await query(title: title).filter { $0.domainIdentifier == domain }
            if results.count == count, description == nil || results.first?.attributeSet.contentDescription?.contains(description!) == true { return results }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline
        return results
    }

    private func query(title: String) async throws -> [CSSearchableItem] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "contentDescription"]
        let query = CSSearchQuery(queryString: "title == \"\(title)\"", queryContext: context)
        let results = SpotlightQueryResults()
        let found: [CSSearchableItem] = try await withCheckedThrowingContinuation { continuation in
            query.foundItemsHandler = { results.append($0) }
            query.completionHandler = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results.snapshot()) }
            }
            query.start()
        }
        withExtendedLifetime(query) {}
        return found
    }
}

private final class SpotlightQueryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CSSearchableItem] = []
    func append(_ found: [CSSearchableItem]) {
        lock.lock()
        defer { lock.unlock() }
        items.append(contentsOf: found)
    }
    func snapshot() -> [CSSearchableItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
