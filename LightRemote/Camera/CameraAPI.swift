import Foundation

/// Typed wrappers over the Camera Remote API calls LightRemote uses.
struct CameraAPI: Sendable {
    let client: SonyClient

    func availableApis(service: String = "camera", timeout: TimeInterval = 10) async throws -> [String] {
        try await client.call("getAvailableApiList", service: service, timeout: timeout).first?.strings ?? []
    }

    func startRecMode() async throws { _ = try await client.call("startRecMode", timeout: 30) }

    /// `longPoll: true` blocks until something changes on the camera.
    func event(longPoll: Bool) async throws -> CameraEvent {
        CameraEvent(result: try await client.call("getEvent", [.bool(longPoll)], timeout: longPoll ? 70 : 10))
    }

    func startLiveview() async throws -> URL {
        guard let s = try await client.call("startLiveview").first?.string, let url = URL(string: s) else {
            throw SonyError(code: -1, message: "No live view URL")
        }
        return url
    }

    func stopLiveview() async throws { _ = try await client.call("stopLiveview") }

    /// Returns postview URLs. Long exposures answer 40403 and finish via `awaitTakePicture`.
    func takePicture() async throws -> [URL] {
        do {
            return Self.urls(try await client.call("actTakePicture", timeout: 40))
        } catch let e as SonyError where e.code == SonyError.longShooting {
            return Self.urls(try await client.call("awaitTakePicture", timeout: 120))
        }
    }

    func set(_ method: String, _ value: JSON) async throws { _ = try await client.call(method, [value]) }

    func setFNumber(_ v: String) async throws { try await set("setFNumber", .string(v)) }
    func setShutterSpeed(_ v: String) async throws { try await set("setShutterSpeed", .string(v)) }
    func setISO(_ v: String) async throws { try await set("setIsoSpeedRate", .string(v)) }
    func setFocusMode(_ v: String) async throws { try await set("setFocusMode", .string(v)) }
    func setShootMode(_ v: String) async throws { try await set("setShootMode", .string(v)) }
    func setSelfTimer(_ seconds: Int) async throws { try await set("setSelfTimer", .number(Double(seconds))) }
    func setExposureCompensation(_ index: Int) async throws {
        try await set("setExposureCompensation", .number(Double(index)))
    }

    /// x, y in percent of the live view frame (0...100). Returns whether AF locked.
    func touchAF(x: Double, y: Double) async throws -> Bool {
        let r = try await client.call("setTouchAFPosition", [.number(x), .number(y)], timeout: 15)
        return r.first?["AFResult"]?.bool ?? false
    }
    func cancelTouchAF() async throws { _ = try await client.call("cancelTouchAFPosition") }
    func halfPress() async throws { _ = try await client.call("actHalfPressShutter", timeout: 15) }
    func cancelHalfPress() async throws { _ = try await client.call("cancelHalfPressShutter") }

    func startMovie() async throws { _ = try await client.call("startMovieRec") }
    func stopMovie() async throws { _ = try await client.call("stopMovieRec", timeout: 30) }
    func startBulb() async throws { _ = try await client.call("startBulbShooting") }
    func stopBulb() async throws { _ = try await client.call("stopBulbShooting", timeout: 60) }

    /// System service. Sets the camera clock from the phone (UTC time + zone + DST offsets).
    func setCurrentTime(_ date: Date, timeZone: TimeZone = .current) async throws {
        let dst = Int(timeZone.daylightSavingTimeOffset(for: date) / 60)
        let total = timeZone.secondsFromGMT(for: date) / 60
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        let params: JSON = ["dateTime": .string(f.string(from: date)),
                            "timeZoneOffsetMinute": .number(Double(total - dst)),
                            "dstOffsetMinute": .number(Double(dst))]
        _ = try await client.call("setCurrentTime", [params], service: "system")
    }

    private static func urls(_ result: [JSON]) -> [URL] {
        (result.first?.strings ?? []).compactMap(URL.init(string:))
    }
}
