//
//  TimerTagsTests.swift
//  sharedTimerTests
//
//  N5: tags and notes (this phone only) — the pure rules, the list filter and the
//  store's never-lose-a-note guarantees, against a private UserDefaults suite.
//

import Foundation
import Testing
@testable import sharedTimer

@Suite(.serialized)
struct TimerTagsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func timer(_ id: String) -> TimerPayload {
        TimerPayload(id: id, label: id, endDate: now.addingTimeInterval(300), duration: 300)
    }

    @Test func tagsAreDedupedTrimmedAndRenamedInPlace() throws {
        var o = TimerOrganizer()
        let kitchenMade = o.addTag(named: "  Kitchen ")
        let kitchen = try #require(kitchenMade)
        #expect(kitchen.name == "Kitchen")
        let again = o.addTag(named: "kitchen")
        #expect(again?.id == kitchen.id)
        let blank = o.addTag(named: "   ")
        #expect(blank == nil)
        let long = o.addTag(named: String(repeating: "x", count: 50))
        #expect(long?.name.count == TimerOrganizer.maxTagLength)
        o.toggle(tagID: kitchen.id, for: "pizza")
        o.rename(tagID: kitchen.id, to: "Cooking")
        // Same id: the timer keeps it, and a filter on it survives the rename.
        #expect(o.tags(for: "pizza").map(\.name) == ["Cooking"])
        #expect(o.filter([timer("pizza"), timer("trip")], tagID: kitchen.id).shown.map(\.id) == ["pizza"])
    }

    @Test func theFilterShowsTaggedTimersAndCountsTheRest() throws {
        var o = TimerOrganizer()
        let workMade = o.addTag(named: "Work")
        let work = try #require(workMade)
        o.setTags([work.id], for: "a")
        let all = [timer("a"), timer("b"), timer("c")]
        let split = o.filter(all, tagID: work.id)
        #expect(split.shown.map(\.id) == ["a"])
        #expect(split.hidden.map(\.id) == ["b", "c"])
        // No filter, or one whose tag was deleted: everything shows.
        #expect(o.filter(all, tagID: nil).hidden.isEmpty)
        o.deleteTag(id: work.id)
        #expect(o.filter(all, tagID: work.id).shown.count == 3)
        #expect(o.tags(for: "a").isEmpty)
        #expect(o.tagsByTimer["a"] == nil)
    }

    @Test func notesAreTrimmedCappedAndClearedWhenEmpty() {
        var o = TimerOrganizer()
        o.setNote("  200°, cover with foil.  ", for: "roast")
        #expect(o.note(for: "roast") == "200°, cover with foil.")
        o.setNote(String(repeating: "n", count: 2_000), for: "roast")
        #expect(o.note(for: "roast")?.count == TimerOrganizer.maxNoteLength)
        o.setNote("   ", for: "roast")
        #expect(o.note(for: "roast") == nil)
    }

    @Test func setTagsIgnoresUnknownAndRepeatedIDs() throws {
        var o = TimerOrganizer()
        let aMade = o.addTag(named: "A")
        let a = try #require(aMade)
        o.setTags([a.id, "gone", a.id], for: "t")
        #expect(o.tagsByTimer["t"] == [a.id])
    }

    @Test func pruneDropsOnlyTimersNoLongerStored() throws {
        var o = TimerOrganizer()
        let aMade = o.addTag(named: "A")
        let a = try #require(aMade)
        o.setTags([a.id], for: "kept"); o.setNote("x", for: "kept")
        o.setTags([a.id], for: "gone"); o.setNote("y", for: "gone")
        o.prune(keeping: ["kept"])
        #expect(o.tagsByTimer.keys.sorted() == ["kept"])
        #expect(o.notes.keys.sorted() == ["kept"])
        #expect(o.tags.count == 1)
    }

    @Test func theStoreRoundTripsAndNeverOverwritesWhatItCannotRead() throws {
        let suite = "timer-tags-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = TimerTagStore.defaults
        TimerTagStore.defaults = defaults
        defer { TimerTagStore.defaults = saved; defaults.removePersistentDomain(forName: suite) }

        TimerTagStore.update { o in
            if let tag = o.addTag(named: "Kitchen") { o.setTags([tag.id], for: "pizza") }
            o.setNote("Turn at half time", for: "pizza")
        }
        let loaded = TimerTagStore.load()
        #expect(loaded.tags(for: "pizza").map(\.name) == ["Kitchen"])
        #expect(loaded.note(for: "pizza") == "Turn at half time")

        // A blob this build can't decode at all stays exactly as it was.
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "timerOrganizer.v1")
        TimerTagStore.update { $0.setNote("lost?", for: "pizza") }
        #expect(defaults.data(forKey: "timerOrganizer.v1") == garbage)

        // A field this build doesn't understand is dropped, the rest kept.
        let partial = Data(#"{"tags":[{"id":"k","name":"Kitchen"}],"notes":{"pizza":"Hot"},"future":42,"tagsByTimer":"oops"}"#.utf8)
        defaults.set(partial, forKey: "timerOrganizer.v1")
        let lenient = TimerTagStore.load()
        #expect(lenient.tags.map(\.name) == ["Kitchen"])
        #expect(lenient.note(for: "pizza") == "Hot")
        #expect(lenient.tagsByTimer.isEmpty)
    }

    @Test func recentsCarryTagsAndNotesToTheNextRun() {
        var o = TimerOrganizer()
        let kitchenMade = o.addTag(named: "Kitchen")
        let kitchen = kitchenMade!.id
        // First run, from New Timer: its own tag and note become the recent's.
        o.setTags([kitchen], for: "run1"); o.setNote("Turn at half time", for: "run1")
        o.adopt(timerID: "run1", recentKey: "Pasta|480")
        #expect(o.recentExtras["Pasta|480"]?.tagIDs == [kitchen])
        #expect(o.recentExtras["Pasta|480"]?.note == "Turn at half time")
        // A later change on the timer follows to the recent.
        o.setNote("Salt the water", for: "run1")
        #expect(o.recentExtras["Pasta|480"]?.note == "Salt the water")
        // New Timer with the list filtered by another tag: that tag stays, the
        // remembered tag and note are added — never replaced by "nothing".
        let workMade = o.addTag(named: "Work")
        let work = workMade!.id
        o.setTags([work], for: "fresh")
        o.adopt(timerID: "fresh", recentKey: "Pasta|480")
        #expect(o.tags(for: "fresh").map(\.id) == [work, kitchen])
        #expect(o.note(for: "fresh") == "Salt the water")
        #expect(o.recentExtras["Pasta|480"]?.note == "Salt the water")
        // A note typed for this run wins over the remembered one.
        o.setNote("Less salt", for: "typed")
        o.adopt(timerID: "typed", recentKey: "Pasta|480")
        #expect(o.note(for: "typed") == "Less salt")
        o.setTags([kitchen], for: "fresh"); o.setNote("Salt the water", for: "fresh")
        // Started again from the chip: a new timer gets them.
        o.adopt(timerID: "run2", recentKey: "Pasta|480")
        #expect(o.tags(for: "run2").map(\.id) == [kitchen])
        #expect(o.note(for: "run2") == "Salt the water")
        // Clearing them on the new run clears the recent too.
        o.setTags([], for: "run2"); o.setNote(nil, for: "run2")
        #expect(o.recentExtras["Pasta|480"] == nil)
        // A deleted tag leaves the remembered value.
        o.setTags([kitchen], for: "run2")
        o.deleteTag(id: kitchen)
        #expect(o.recentExtras["Pasta|480"]?.tagIDs.isEmpty ?? true)
        // Kept after the timer itself is gone (and whether or not it's still in Recents).
        o.setNote("x", for: "run2")
        o.prune(keeping: [])
        #expect(o.recentExtras["Pasta|480"]?.note == "x")
        #expect(o.recentOf.isEmpty)
    }

    @Test func rememberedValuesAreCappedByLeastRecentUse() {
        var o = TimerOrganizer()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0...(TimerOrganizer.maxRemembered) {
            o.setNote("n\(i)", for: "t\(i)")
            o.adopt(timerID: "t\(i)", recentKey: "k\(i)", at: base.addingTimeInterval(Double(i)))
        }
        #expect(o.recentExtras.count == TimerOrganizer.maxRemembered + 1)
        o.prune(keeping: [])
        #expect(o.recentExtras.count == TimerOrganizer.maxRemembered)
        #expect(o.recentExtras["k0"] == nil)
        #expect(o.recentExtras["k\(TimerOrganizer.maxRemembered)"] != nil)
    }

    @Test func aPlainTimerIsFiledUnderItsRecentByNameAndLength() {
        let pasta = TimerPayload.compose(label: "Pasta", kind: .timer, minutes: 8, targetDate: Date(), alarmEnabled: false, vibrationEnabled: true)
        #expect(RecentTimer.key(for: pasta) == RecentTimer(label: "Pasta", duration: 480, alarmEnabled: true, vibrationEnabled: false).id)
        let countdown = TimerPayload.compose(label: "Trip", kind: .countdown, minutes: 0, targetDate: Date().addingTimeInterval(86_400))
        #expect(RecentTimer.key(for: countdown) == nil)
    }
}
