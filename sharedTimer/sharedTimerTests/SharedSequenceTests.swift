import CloudKit
import Foundation
import Testing
import UserNotifications
@testable import sharedTimer

@MainActor
struct SharedSequenceTests {
    private func payload(end: Date = Date().addingTimeInterval(60), loops: Int = 3) -> TimerPayload {
        let phases = [SequencePhase(label: "Work & focus 💫", duration: 60, alarmEnabled: true, vibrationEnabled: false),
                      SequencePhase(label: "Rest / tea", duration: 30, alarmEnabled: false, vibrationEnabled: true)]
        return TimerPayload(id: UUID().uuidString, label: phases[0].label, endDate: end, duration: 60,
                            alarmEnabled: true, vibrationEnabled: false,
                            sequence: SequenceInfo(phases: phases, loopCount: loops, phaseIndex: 0, loopIndex: 0), updatedAt: Date())
    }

    @Test func linkPreservesDefinitionsTogglesLoopsAndPosition() throws {
        let source = payload().materializingPhase(globalIndex: 3, startingAt: Date())
        let decoded = try #require(TimerPayload.from(url: source.url()))
        #expect(decoded.sequence == source.sequence)
        #expect(decoded.label == source.label)
        #expect(decoded.alarmEnabled == false)
        #expect(decoded.vibrationEnabled == true)
        #expect(abs(decoded.endDate.timeIntervalSince(source.endDate)) < 0.001)
        #expect(abs(decoded.updatedAt!.timeIntervalSince(source.updatedAt!)) < 0.001)
    }
    @Test func scheduledLinkKeepsFutureStart() throws {
        var source = payload(end: Date().addingTimeInterval(180))
        source.scheduledStartDate = Date().addingTimeInterval(120)
        let decoded = try #require(TimerPayload.from(url: source.url()))
        #expect(decoded.isPending())
        #expect(decoded.sequence == source.sequence)
        #expect(abs(decoded.scheduledStartDate!.timeIntervalSince(source.scheduledStartDate!)) < 0.001)
    }
    @Test func pausedLinkNeverAdvancesEvenWithExpiredBoundary() throws {
        let source = payload(end: Date().addingTimeInterval(-150)).paused(at: Date().addingTimeInterval(-180))
        let decoded = try #require(TimerPayload.from(url: source.url()))
        #expect(decoded.sequence == source.sequence)
        #expect(decoded.pausedRemaining == source.pausedRemaining)
        #expect(decoded.resumed().sequence == source.sequence)
    }
    @Test func lateLinkCatchesUpAcrossLoopsWithoutChangingMutationStamp() throws {
        let source = payload(end: Date().addingTimeInterval(-150))
        let decoded = try #require(TimerPayload.from(url: source.url()))
        #expect(decoded.sequenceGlobalIndex == 4)
        #expect(decoded.label == "Work & focus 💫")
        #expect(abs(decoded.updatedAt!.timeIntervalSince(source.updatedAt!)) < 0.001)
        #expect(decoded.endDate > Date())
    }
    @Test func repeatedAndFinishedSequencesSurviveLinks() throws {
        let source = payload(end: Date().addingTimeInterval(-1000)).advancedSequence()
        let done = try #require(TimerPayload.from(url: source.url()))
        #expect(done.sequence?.loopIndex == done.sequence?.loopCount)
        let again = try #require(TimerPayload.from(url: done.repeated().url()))
        #expect(again.sequenceGlobalIndex == 0)
        #expect(again.sequence?.phases == source.sequence?.phases)
    }
    @Test func malformedAndFutureSequenceVersionsRejectTheLink() throws {
        let source = payload()
        var components = try #require(URLComponents(url: source.url(), resolvingAgainstBaseURL: false))
        for json in ["{}", "{\"version\":2,\"sequence\":{}}", String(repeating: "x", count: TimerSequenceWire.maximumBytes + 1)] {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "seq" } + [URLQueryItem(name: "seq", value: json)]
            #expect(TimerPayload.from(url: components.url) == nil)
        }
    }
    @Test func invalidBoundsAreRejectedBeforePhaseTraversal() throws {
        var sequence = try #require(payload().sequence)
        sequence.loopCount = Int.max
        #expect(!TimerSequenceWire.isValid(sequence))
        sequence.loopCount = 3
        sequence.phaseIndex = -1
        #expect(!TimerSequenceWire.isValid(sequence))
        sequence.phaseIndex = 0
        sequence.phases[0].duration = .infinity
        #expect(TimerSequenceWire.encode(sequence) == nil)
        sequence.phases = []
        #expect(!TimerSequenceWire.isValid(sequence))
    }
    @Test func cloudRoundTripPreservesSequencePauseAndStart() throws {
        var source = payload(end: Date().addingTimeInterval(180))
        source.scheduledStartDate = Date().addingTimeInterval(120)
        let record = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: source.id))
        CloudSyncController.applyFields(from: source, to: record)
        let decoded = try #require(CloudSyncController.makePayload(from: record))
        #expect(decoded.sequence == source.sequence)
        #expect(decoded.scheduledStartDate == source.scheduledStartDate)
        #expect(abs(decoded.updatedAt!.timeIntervalSince(source.updatedAt!)) < 0.001)
        source.scheduledStartDate = nil
        source = source.paused()
        CloudSyncController.applyFields(from: source, to: record)
        #expect(CloudSyncController.makePayload(from: record)?.pausedRemaining == source.pausedRemaining)
        #expect(record["scheduledStartDate"] == nil)
    }
    @Test func cloudLegacyRecordStaysPlainAndRejectsMalformedSequence() throws {
        let source = TimerPayload(label: "Legacy", duration: 100)
        let record = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: source.id))
        CloudSyncController.applyFields(from: source, to: record)
        record["alarmEnabled"] = nil
        record["vibrationEnabled"] = nil
        record["updatedAt"] = nil
        let old = try #require(CloudSyncController.makePayload(from: record))
        #expect(old.sequence == nil && old.updatedAt == nil)
        #expect(old.alarmEnabled && !old.vibrationEnabled)
        record["sequenceData"] = Data("bad".utf8) as CKRecordValue
        #expect(CloudSyncController.makePayload(from: record) == nil)
    }
    @Test func notificationWindowMatchesPhaseScheduleAndToggles() throws {
        let now = Date()
        let source = payload(end: now.addingTimeInterval(60), loops: 6)
        let requests = NotificationScheduler.requests(for: source, at: now)
        #expect(requests.count == 8)
        let phases = source.upcomingSequencePhases(limit: 8)
        for (request, phase) in zip(requests, phases) {
            #expect(request.content.title == phase.phase.label)
            #expect(request.content.userInfo["timerID"] as? String == source.id)
            #expect(request.content.userInfo["sequenceGlobalIndex"] as? Int == phase.globalIndex)
            let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
            #expect(abs(trigger.timeInterval - phase.endDate.timeIntervalSince(now)) < 0.001)
        }
        #expect(requests[0].content.sound != nil)
        #expect(requests[1].content.sound == nil)
        #expect(requests[1].content.categoryIdentifier == NotificationScheduler.vibrationFinishCategoryID)
        #expect(Set(requests.map(\.identifier)).isSubset(of: Set(NotificationScheduler.requestIDs(id: source.id))))
    }
    @Test func notificationsExcludePhasesAlreadyCoveredByAlarmKit() {
        let now = Date()
        let source = payload(end: now.addingTimeInterval(60), loops: 6)
        let requests = NotificationScheduler.requests(for: source, at: now, excludingSequenceIndices: [0, 2, 4, 6])
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { ($0.content.userInfo["sequenceGlobalIndex"] as? Int ?? 0) % 2 == 1 })
        #expect(NotificationScheduler.requests(for: source, at: now, excludingSequenceIndices: Set(0..<8)).isEmpty)
    }

    @Test func notificationPauseClearsWindowAndLateReadUsesCurrentPhase() {
        let now = Date()
        let source = payload(end: now.addingTimeInterval(-150))
        #expect(NotificationScheduler.requests(for: source.paused(at: now.addingTimeInterval(-180)), at: now).isEmpty)
        let requests = NotificationScheduler.requests(for: source, at: now)
        #expect(requests.count == 2)
        #expect(requests.first?.content.userInfo["sequenceGlobalIndex"] as? Int == 4)
        #expect(NotificationScheduler.requests(for: source, at: now.addingTimeInterval(1000)).isEmpty)
    }
}
