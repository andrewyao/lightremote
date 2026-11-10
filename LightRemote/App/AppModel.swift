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
        camera.onConnecting = { [weak self] in
            guard let self else { return }
            self.gallery.beginSession(self.camera.sessionID, baseURL: CameraController.configuredBase)
        }
        camera.onClockSynchronized = { [weak self] date in
            self?.track.noteClockOffset(cameraMinusUTC: TimeZone.current.secondsFromGMT(for: date), at: date)
        }
        camera.onConnected = { [weak self] in
            guard let self, UserDefaults.standard.object(forKey: "autoTrack") as? Bool ?? true else { return }
            if !self.track.isRecording { self.track.start(); self.preciseFromCamera = true }
        }
        camera.onDisconnected = { [weak self] in
            guard let self else { return }
            self.runner.stop()   // the connect screen has no Stop button, so a job can't outlive the connection
            // Save battery: back to low-power tracking once the camera is gone.
            guard self.preciseFromCamera else { return }
            self.preciseFromCamera = false
            self.track.stop()
        }
        LiveActivityController.shared.observe(track)
    }

    func start(_ job: ShootingJob) {
        guard camera.connection == .connected, !camera.isChangingMode else { return }
        runner.start(job, on: camera.api)
    }

    private func handle(_ result: ShotResult) {
        let point = track.location(at: result.takenAt)
        let ingestion = gallery.ingest(result.urls, takenAt: result.takenAt, settings: camera.state, location: point)
        if ingestion.isNewShot { track.noteShot(at: result.takenAt) }
        guard result.clockReliable else { return }
        let session = camera.sessionID
        Task {
            guard let wall = await ingestion.results.value.first?.cameraWallClock else { return }
            guard camera.sessionID == session,
                  let seconds = Int(exactly: wall.timeIntervalSince(result.takenAt).rounded()) else { return }
            track.noteClockOffset(cameraMinusUTC: seconds, at: result.takenAt)
        }
    }
}
