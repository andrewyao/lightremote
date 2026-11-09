import Foundation
import Observation
import UIKit

/// Wires the camera, job runner, gallery and track recorder together.
@MainActor @Observable
final class AppModel {
    let camera = CameraController()
    let runner = JobRunner()
    let gallery = PostviewStore()
    let track = TrackRecorder()
    /// Precise GPS that the camera connection turned on (not the user), so it can be turned off again.
    private var preciseFromCamera = false

    init() {
        runner.onShot = { [weak self] result in self?.handle(result) }
        runner.onRunningChanged = { running in UIApplication.shared.isIdleTimerDisabled = running }
        camera.onEventPostviews = { [weak self] urls in
            self?.handle(ShotResult(urls: urls, takenAt: Date(), clockReliable: false))
        }
        camera.onConnected = { [weak self] in
            guard let self, UserDefaults.standard.object(forKey: "autoTrack") as? Bool ?? true else { return }
            if !self.track.isRecording { self.track.start(); self.preciseFromCamera = true }
        }
        // Save battery: back to low-power tracking once the camera is gone.
        camera.onDisconnected = { [weak self] in
            guard let self, self.preciseFromCamera, !self.runner.isRunning else { return }
            self.preciseFromCamera = false
            self.track.stop()
        }
        LiveActivityController.shared.observe(track)
    }

    func start(_ job: ShootingJob) {
        runner.start(job, on: camera.api)
    }

    private func handle(_ result: ShotResult) {
        track.noteShot(at: result.takenAt)
        let settings = camera.state
        let point = track.location(at: result.takenAt)
        Task {
            let ingested = await gallery.ingest(result.urls, takenAt: result.takenAt, settings: settings, location: point)
            guard result.clockReliable, let wall = ingested.first?.cameraWallClock else { return }
            let seconds = Int(wall.timeIntervalSince(result.takenAt).rounded())
            track.noteClockOffset(cameraMinusUTC: seconds, at: result.takenAt)
        }
    }
}
