import ActivityKit
import Foundation
import Observation

/// Starts/ends the Lock Screen Live Activity as track recording starts/stops.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<TrackActivityAttributes>?

    func observe(_ track: TrackRecorder) {
        withObservationTracking {
            sync(recording: track.isRecording, startedAt: track.recordingStartedAt, clockError: track.cameraClockError)
        } onChange: {
            Task { @MainActor in self.observe(track) }
        }
    }

    private func sync(recording: Bool, startedAt: Date?, clockError: Int?) {
        let state = TrackActivityAttributes.ContentState(cameraClock: clockError.map { "camera \($0 >= 0 ? "+" : "")\($0) s" })
        if recording, let startedAt {
            if let activity {
                // ActivityKit's Activity isn't Sendable; it is only touched from this call.
                nonisolated(unsafe) let a = activity
                Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(attributes: TrackActivityAttributes(startedAt: startedAt),
                                                 content: ActivityContent(state: state, staleDate: nil))
            }
        } else if let activity {
            self.activity = nil
            nonisolated(unsafe) let a = activity
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
