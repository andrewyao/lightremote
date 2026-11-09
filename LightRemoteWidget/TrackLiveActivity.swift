import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LightRemoteWidgetBundle: WidgetBundle {
    var body: some Widget { TrackLiveActivity() }
}

struct TrackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LightRemote · GPS track").font(.headline)
                    if let clock = context.state.cameraClock { Text(clock).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .font(.title3.monospacedDigit()).multilineTextAlignment(.trailing).frame(width: 90)
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Track", systemImage: "location.north.line") }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let clock = context.state.cameraClock { Text(clock).font(.caption) }
                }
            } compactLeading: {
                Image(systemName: "location.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "location.fill").foregroundStyle(.red)
            }
        }
    }
}
