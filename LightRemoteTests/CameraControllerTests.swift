import XCTest
@testable import LightRemote

/// Answers the camera's JSON-RPC calls from a test-supplied script.
final class StubCamera: URLProtocol, @unchecked Sendable {
    enum Reply {
        case result(String)
        case sonyError(Int)
        case transportFailure(URLError.Code)
        case hang
    }
    struct Call: Equatable {
        var method: String
        var longPoll: Bool
    }
    typealias Script = @Sendable (Call) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: Script = { _ in .hang }
    nonisolated(unsafe) private static var recorded: [Call] = []

    static var calls: [Call] { lock.withLock { recorded } }

    static func session(script: @escaping Script) -> URLSession {
        lock.withLock {
            self.script = script
            recorded = []
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubCamera.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.body(of: request)
        let params = body["params"] as? [Any]
        let call = Call(method: body["method"] as? String ?? "", longPoll: params?.first as? Bool ?? false)
        let reply = Self.lock.withLock {
            Self.recorded.append(call)
            return Self.script
        }(call)
        switch reply {
        case .hang: return
        case .transportFailure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .sonyError(let code): finish(#"{"error":[\#(code),"stub"],"id":1}"#)
        case .result(let json): finish(#"{"result":\#(json),"id":1}"#)
        }
    }

    private func finish(_ json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private let idleEvent = #"[{"type":"availableApiList","names":["getEvent"]}]"#

@MainActor
final class CameraControllerTests: XCTestCase {
    private func connected(longPoll: @escaping @Sendable () -> StubCamera.Reply,
                           probe: @escaping @Sendable () -> StubCamera.Reply) async -> CameraController {
        let startup = AtomicFlag()
        let session = StubCamera.session { call in
            switch (call.method, call.longPoll) {
            case ("getEvent", true): return longPoll()
            case ("getEvent", false): return startup.testAndSet() ? probe() : .result(idleEvent)
            case ("getAvailableApiList", _): return .result(#"[["getEvent"]]"#)
            default: return .result("[0]")
            }
        }
        let camera = CameraController(session: session)
        await camera.connect()
        XCTAssertEqual(camera.connection, .connected)
        return camera
    }

    private func waitForLongPolls(_ count: Int, timeout: Duration = .seconds(6)) async {
        let deadline = ContinuousClock.now + timeout
        while StubCamera.calls.filter(\.longPoll).count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testQuietLongPollsThatTimeOutKeepTheConnection() async {
        let camera = await connected(longPoll: { .transportFailure(.timedOut) }, probe: { .result(idleEvent) })
        await waitForLongPolls(4)
        XCTAssertEqual(camera.connection, .connected)
        camera.disconnect()
    }

    func testCameraErrorsDuringLongPollKeepTheConnection() async {
        let camera = await connected(longPoll: { .sonyError(40401) }, probe: { .result(idleEvent) })
        await waitForLongPolls(4)
        XCTAssertEqual(camera.connection, .connected)
        camera.disconnect()
    }

    func testLiveViewStartsWhenTheCameraOffersItAfterConnecting() async {
        let delivered = AtomicFlag()
        let camera = await connected(
            longPoll: {
                delivered.testAndSet() ? .hang : .result(#"[{"type":"availableApiList","names":["getEvent","startLiveview"]}]"#)
            },
            probe: { .result(idleEvent) })
        let deadline = ContinuousClock.now + .seconds(3)
        while !StubCamera.calls.contains(where: { $0.method == "startLiveview" }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(StubCamera.calls.contains { $0.method == "startLiveview" })
        camera.disconnect()
    }

    func testCameraThatStopsAnsweringIsReportedLost() async {
        let camera = await connected(longPoll: { .transportFailure(.timedOut) },
                                     probe: { .transportFailure(.timedOut) })
        var disconnected = false
        camera.onDisconnected = { disconnected = true }
        await waitForLongPolls(3)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(camera.connection, .failed("Lost connection to the camera"))
        XCTAssertTrue(disconnected)
    }
}

/// True from the second call on.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func testAndSet() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return isSet
        }
    }
}
