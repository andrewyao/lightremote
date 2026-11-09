import XCTest
@testable import LightRemote

@MainActor
final class AppModelTests: XCTestCase {
    func testDisconnectingDuringAJobEndsTheJobAndPreciseGPS() async throws {
        let model = AppModel()
        model.camera.onConnected?()
        XCTAssertTrue(model.track.isRecording)

        let shooter = FakeShooter()
        model.runner.start(.movie, on: shooter)
        try await Task.sleep(for: .milliseconds(100))
        model.camera.onDisconnected?()

        let deadline = ContinuousClock.now + .seconds(2)
        while model.runner.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(shooter.calls, ["movie start", "movie stop"])
        XCTAssertFalse(model.track.isRecording)
        model.runner.stop()
    }
}
