import ActivityKit
import XCTest
@testable import LightRemote

@MainActor
final class LiveActivityTests: XCTestCase {
    func testActivityLeftOverFromAPreviousRunIsEndedAtLaunch() async throws {
        let state = TrackActivityAttributes.ContentState(cameraClock: nil)
        let leftover: Activity<TrackActivityAttributes>
        do {
            leftover = try Activity.request(attributes: TrackActivityAttributes(startedAt: Date()),
                                            content: ActivityContent(state: state, staleDate: nil))
        } catch {
            throw XCTSkip("Live Activities unavailable here: \(error)")
        }
        let id = leftover.id

        _ = LiveActivityController()

        let deadline = ContinuousClock.now + .seconds(2)
        while Activity<TrackActivityAttributes>.activities.contains(where: { $0.id == id && $0.activityState == .active }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(Activity<TrackActivityAttributes>.activities.contains { $0.id == id && $0.activityState == .active })
    }
}
