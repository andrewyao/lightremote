import XCTest
@testable import LightRemote

final class ModeChangeTests: XCTestCase {
    private func state(shutter: String, shootMode: String = "still") -> CameraEvent {
        var event = CameraEvent()
        event.shutterSpeed = Setting(current: shutter, candidates: ["BULB", "1\"", "1/250"])
        event.shootMode = Setting(current: shootMode, candidates: ["still", "movie"])
        return event
    }

    func testEnteringBulbRemembersTheShutterSpeed() {
        XCTAssertEqual(ShootMode.bulb.change(from: state(shutter: "1/250"), shutterBeforeBulb: nil),
                       ModeChange(shutterSpeed: "BULB", shutterBeforeBulb: "1/250"))
    }

    func testLeavingBulbRestoresTheShutterSpeedOnce() {
        XCTAssertEqual(ShootMode.interval.change(from: state(shutter: "BULB"), shutterBeforeBulb: "1/250"),
                       ModeChange(shutterSpeed: "1/250", shutterBeforeBulb: nil))
    }

    func testReapplyingAModeTheCameraIsAlreadyInChangesNothing() {
        XCTAssertEqual(ShootMode.bulb.change(from: state(shutter: "BULB"), shutterBeforeBulb: "1/250"),
                       ModeChange(shutterBeforeBulb: "1/250"))
        XCTAssertEqual(ShootMode.single.change(from: state(shutter: "1/250"), shutterBeforeBulb: nil), ModeChange())
        XCTAssertEqual(ShootMode.movie.change(from: state(shutter: "1/250", shootMode: "movie"), shutterBeforeBulb: nil),
                       ModeChange())
    }

    func testSwitchingBetweenStillAndMovie() {
        XCTAssertEqual(ShootMode.movie.change(from: state(shutter: "1/250"), shutterBeforeBulb: nil).shootMode, "movie")
        XCTAssertEqual(ShootMode.single.change(from: state(shutter: "1/250", shootMode: "movie"), shutterBeforeBulb: nil).shootMode,
                       "still")
    }

    func testLeavingBulbWithNothingRememberedLeavesTheShutterAlone() {
        XCTAssertEqual(ShootMode.single.change(from: state(shutter: "BULB"), shutterBeforeBulb: nil), ModeChange())
    }

    func testRememberedSpeedTheCameraNoLongerOffersIsNotSent() {
        XCTAssertNil(ShootMode.single.change(from: state(shutter: "BULB"), shutterBeforeBulb: "1/8000").shutterSpeed)
    }
}
