import AppIntents
import SwiftUI
import WidgetKit

struct WatchTimerChoice: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static var defaultQuery = WatchTimerQuery()
    let id: String
    let label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

struct WatchTimerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchTimerChoice] {
        WatchTimerCache.load().filter { identifiers.contains($0.id) }
            .map { WatchTimerChoice(id: $0.id, label: $0.label) }
    }
    func suggestedEntities() async throws -> [WatchTimerChoice] {
        WatchTimerCache.load().filter { !$0.isFinished }
            .sorted { $0.endDate < $1.endDate }
            .map { WatchTimerChoice(id: $0.id, label: $0.label) }
    }
}

struct SelectWatchTimerIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Timer"
    static var description = IntentDescription("Choose a timer synced from your iPhone, or show the next active timer.")
    @Parameter(title: "Timer") var timer: WatchTimerChoice?
}

struct WatchTimerEntry: TimelineEntry {
    let snapshot: WatchTimerSnapshot
    var date: Date { snapshot.date }
}

struct WatchTimerProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<SelectWatchTimerIntent>] {
        var result = [AppIntentRecommendation(intent: SelectWatchTimerIntent(), description: "Next active timer")]
        for timer in WatchTimerCache.load().filter({ !$0.isFinished }).sorted(by: { $0.endDate < $1.endDate }).prefix(3) {
            let intent = SelectWatchTimerIntent()
            intent.timer = WatchTimerChoice(id: timer.id, label: timer.label)
            result.append(AppIntentRecommendation(intent: intent, description: timer.label))
        }
        return result
    }
    func placeholder(in context: Context) -> WatchTimerEntry {
        WatchTimerEntry(snapshot: WatchTimerSnapshot(date: .now, timer: TimerPayload(label: "Tea", duration: 180)))
    }
    func snapshot(for configuration: SelectWatchTimerIntent, in context: Context) async -> WatchTimerEntry {
        if context.isPreview { return placeholder(in: context) }
        return WatchTimerEntry(snapshot: .select(WatchTimerCache.load(), id: configuration.timer?.id, at: .now))
    }
    func timeline(for configuration: SelectWatchTimerIntent, in context: Context) async -> Timeline<WatchTimerEntry> {
        let now = Date()
        let entries = WatchTimerSnapshot.timeline(WatchTimerCache.load(), id: configuration.timer?.id, at: now)
            .map { WatchTimerEntry(snapshot: $0) }
        let nextReload = entries.first?.snapshot.isRunning == true
            ? min(now.addingTimeInterval(900), entries.last!.date.addingTimeInterval(60))
            : now.addingTimeInterval(900)
        return Timeline(entries: entries, policy: .after(nextReload))
    }
}

@main
struct WatchTimerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WatchTimerWidget", intent: SelectWatchTimerIntent.self, provider: WatchTimerProvider()) { entry in
            WatchTimerWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Shared Timer")
        .description("See a synced timer on your watch face or in the Smart Stack.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
