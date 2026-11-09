import ActivityKit
import Foundation

/// Lock Screen Live Activity shown while the GPS track records. Shared by the app and the widget extension.
struct TrackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// e.g. "camera +3 s", or nil before the camera clock was measured.
        var cameraClock: String?
    }

    var startedAt: Date
}
