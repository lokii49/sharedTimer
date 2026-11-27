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
    /// A configured timer that's gone still resolves (as a placeholder), so the widget
    /// keeps its selection and shows empty — dropping it let WidgetKit treat the
    /// parameter as unset and quietly switch to the next active timer.
    func entities(for identifiers: [String]) async throws -> [WatchTimerChoice] {
        let cached = WatchTimerCache.load()
        return identifiers.map { id in
            WatchTimerChoice(id: id, label: cached.first { $0.id == id }?.label ?? String(localized: "Timer"))
        }
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
        // Paused, finished or empty: nothing changes until the phone sends a new context,
        // and every received context reloads (WatchTimerCache) — polling every 15 min
        // only spent the reload budget; 6 h is a safety net. Running: the live text ticks by itself, so a
        // reload just after the finish (the next timer takes over), or when a coarse
        // "3d 4h" crosses the hour.
        guard let first = entries.first?.snapshot, first.isRunning, let timer = first.timer else {
            // A slow safety net, as on iOS (`TimerWidgetSnapshot.idleReloadInterval`).
            return Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600)))
        }
        let left = timer.endDate.timeIntervalSince(now)
        let nextReload = left < 86400
            ? entries.last!.date.addingTimeInterval(60)
            : now.addingTimeInterval(max(60, left.truncatingRemainder(dividingBy: 3600) + 1))
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
