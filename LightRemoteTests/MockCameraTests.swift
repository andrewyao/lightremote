import XCTest
@testable import LightRemote

/// Runs against MockCamera/mock_camera.py. Start it first:
///   python3 MockCamera/mock_camera.py --port 8099
/// Skipped when the mock isn't reachable.
final class MockCameraTests: XCTestCase {
    private let api = CameraAPI(client: SonyClient(baseURL: URL(string: "http://localhost:8099/sony")!))

    override func setUp() async throws {
        do { _ = try await api.availableApis() } catch {
            throw XCTSkip("Mock camera not running on localhost:8099")
        }
    }

    func testSettingAValueShowsUpInEvents() async throws {
        let before = try await api.event(longPoll: false)
        let target = try XCTUnwrap(before.fNumber?.candidates.first { $0 != before.fNumber?.current })
        try await api.setFNumber(target)
        let after = try await api.event(longPoll: false)
        XCTAssertEqual(after.fNumber?.current, target)
    }

    func testIllegalValueIsRejected() async throws {
        do {
            try await api.setISO("123456")
            XCTFail("expected an error")
        } catch let e as SonyError {
            XCTAssertEqual(e.code, 3)
        }
    }

    func testTakePictureReturnsDownloadablePostviewWithExifTime() async throws {
        try await api.setShutterSpeed("1/250")
        let urls = try await api.takePicture()
        let url = try XCTUnwrap(urls.first)
        let (data, _) = try await URLSession.shared.data(from: url)
        let wall = try XCTUnwrap(GeoTagger.cameraWallClock(of: data))
        // Mock camera: local wall clock + 3 s. cameraMinusUTC therefore ≈ zone offset + 3 s.
        let measured = wall.timeIntervalSince(Date())
        let expected = Double(TimeZone.current.secondsFromGMT()) + 3
        XCTAssertEqual(measured, expected, accuracy: 2)
    }

    func testLongExposureGoesThroughAwaitTakePicture() async throws {
        try await api.setShutterSpeed("1\"")
        let urls = try await api.takePicture()
        try await api.setShutterSpeed("1/250")
        XCTAssertEqual(urls.count, 1)
    }

    func testLiveViewDeliversJPEGFrames() async throws {
        let url = try await api.startLiveview()
        var frames = 0
        for await jpeg in LiveViewStream().frames(from: url) {
            XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
            frames += 1
            if frames == 5 { break }
        }
        XCTAssertEqual(frames, 5)
    }
}
