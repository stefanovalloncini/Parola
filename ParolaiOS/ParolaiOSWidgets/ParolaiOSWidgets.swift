import SwiftUI
import WidgetKit

@main
struct ParolaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ParolaQuickActionsWidget()
    }
}

struct ParolaQuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.parola.QuickActions",
            provider: ParolaTimelineProvider()
        ) { _ in
            ParolaWidgetView()
        }
        .configurationDisplayName("Parola")
        .description("Quick actions: start a recording or jump to your last transcript.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .containerBackgroundRemovable(false)
    }
}

struct ParolaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ParolaWidgetEntry {
        ParolaWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ParolaWidgetEntry) -> Void) {
        completion(ParolaWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ParolaWidgetEntry>) -> Void) {
        let entry = ParolaWidgetEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct ParolaWidgetEntry: TimelineEntry {
    let date: Date
}
