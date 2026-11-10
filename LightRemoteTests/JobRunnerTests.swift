import XCTest
@testable import LightRemote

/// Clock that jumps straight to each deadline, recording when each sleep was asked to end.
final class FakeTicker: Ticker, @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    let origin: ContinuousClock.Instant
    private(set) var deadlines: [Duration] = []
    var blockForever = false

    init() { origin = current }

    var now: ContinuousClock.Instant { lock.withLock { current } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        if blockForever {
            while true { try await Task.sleep(for: .milliseconds(5)) }   // ends only when cancelled
        }
        lock.withLock {
            deadlines.append(deadline - origin)
            if deadline > current { current = deadline }
        }
        await Task.yield()
    }

    func advance(_ d: Duration) { lock.withLock { current += d } }
}

final class FakeShooter: Shooter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var ticker: FakeTicker?
    var shotDuration: Duration = .zero
    var failShots: Set<Int> = []

    private func log(_ s: String) { lock.withLock { calls.append(s) } }

    func takePicture() async throws -> [URL] {
        let n = lock.withLock { calls.filter { $0 == "shot" }.count }
        log("shot")
        ticker?.advance(shotDuration)
        if failShots.contains(n) { throw SonyError(code: SonyError.illegalState, message: "busy") }
        return [URL(string: "http://cam/p\(n).JPG")!]
    }
    func setSelfTimer(_ seconds: Int) async throws { log("timer \(seconds)") }
    func startBulb() async throws { log("bulb start") }
    func stopBulb() async throws { log("bulb stop") }
    func startMovie() async throws { log("movie start") }
    func stopMovie() async throws { log("movie stop") }
}

private struct UncheckedReply: @unchecked Sendable { let value: StubCamera.Reply }

@MainActor
final class JobRunnerTests: XCTestCase {
    func testIntervalShootsOnFixedScheduleWithoutDrift() async {
        let ticker = FakeTicker()
        let shooter = FakeShooter()
        shooter.ticker = ticker
        shooter.shotDuration = .seconds(2)       // slow shots must not push later shots back
        let runner = JobRunner(ticker: ticker)
        var results: [ShotResult] = []
        runner.onShot = { results.append($0) }

        runner.start(.interval(every: .seconds(10), count: 4), on: shooter)
        await runner.wait()

        XCTAssertEqual(shooter.calls, ["shot", "shot", "shot", "shot"])
        XCTAssertEqual(ticker.deadlines, [.seconds(10), .seconds(20), .seconds(30)])
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy(\.clockReliable))
        XCTAssertFalse(runner.isRunning)
    }

    func testIntervalSkipsBusyShotAndContinues() async {
        let shooter = FakeShooter()
        shooter.failShots = [1]
        let runner = JobRunner(ticker: FakeTicker())
        var count = 0
        runner.onShot = { _ in count += 1 }
        runner.start(.interval(every: .seconds(5), count: 3), on: shooter)
        await runner.wait()
        XCTAssertEqual(shooter.calls.count, 3)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(runner.lastError, "Shot 2 skipped: camera busy")
    }

    func testBulbOpensForDurationThenCloses() async {
        let ticker = FakeTicker()
        let shooter = FakeShooter()
        let runner = JobRunner(ticker: ticker)
        runner.start(.bulb(duration: .seconds(240)), on: shooter)
        await runner.wait()
        XCTAssertEqual(shooter.calls, ["bulb start", "bulb stop"])
        XCTAssertEqual(ticker.deadlines, [.seconds(240)])
    }

    func testStoppingBulbEarlyStillClosesShutter() async throws {
        let ticker = FakeTicker()
        ticker.blockForever = true
        let shooter = FakeShooter()
        let runner = JobRunner(ticker: ticker)
        runner.start(.bulb(duration: .seconds(600)), on: shooter)
        try await Task.sleep(for: .milliseconds(50))
        runner.stop()
        await runner.wait()
        XCTAssertEqual(shooter.calls, ["bulb start", "bulb stop"])
        XCTAssertNil(runner.lastError)
    }

    func testMovieRecordsUntilStopped() async throws {
        let shooter = FakeShooter()
        let runner = JobRunner(ticker: SystemTicker())
        runner.start(.movie, on: shooter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(runner.isRunning)
        runner.stop()
        await runner.wait()
        XCTAssertEqual(shooter.calls, ["movie start", "movie stop"])
    }

    func testLongExposureIsNotUsedForClockSync() async {
        let ticker = FakeTicker()
        let shooter = FakeShooter()
        shooter.ticker = ticker
        shooter.shotDuration = .seconds(30)
        let runner = JobRunner(ticker: ticker)
        var results: [ShotResult] = []
        runner.onShot = { results.append($0) }
        runner.start(.single, on: shooter)
        await runner.wait()
        XCTAssertEqual(results.map(\.clockReliable), [false])
    }

    private func stubbedAPI(_ reply: StubCamera.Reply) -> CameraAPI {
        let reply = UncheckedReply(value: reply)
        let session = StubCamera.session { _ in reply.value }
        return CameraAPI(client: SonyClient(baseURL: URL(string: "http://stub.invalid/sony")!, session: session))
    }

    func testStoppingDuringACameraCallIsNotAnError() async throws {
        let runner = JobRunner(ticker: FakeTicker())
        runner.start(.single, on: stubbedAPI(.hang))
        try await Task.sleep(for: .milliseconds(100))
        runner.stop()
        await runner.wait()
        XCTAssertNil(runner.lastError)
        XCTAssertFalse(runner.isRunning)
    }

    func testLosingTheCameraDuringAShotIsReported() async {
        let runner = JobRunner(ticker: FakeTicker())
        runner.start(.single, on: stubbedAPI(.transportFailure(.networkConnectionLost)))
        await runner.wait()
        XCTAssertNotNil(runner.lastError)
    }

    func testSelfTimerShotIsNotUsedForClockSync() async throws {
        let shooter = FakeShooter()
        let runner = JobRunner(ticker: FakeTicker())
        var results: [ShotResult] = []
        runner.onShot = { results.append($0) }
        runner.start(.selfTimer(seconds: 10), on: shooter)
        await runner.wait()
        try await Task.sleep(for: .milliseconds(20))   // timer reset runs in a follow-up task
        XCTAssertEqual(shooter.calls, ["timer 10", "shot", "timer 0"])
        XCTAssertEqual(results.map(\.clockReliable), [false])
    }
    func testCancelledStartStillAttemptsToStopBulbAndMovie() async {
        for job in [ShootingJob.bulb(duration: .seconds(10)), .movie] {
            let shooter = InterruptedStartShooter()
            let runner = JobRunner(ticker: FakeTicker())
            runner.start(job, on: shooter)
            await runner.wait()
            let stops = await shooter.stops
            XCTAssertEqual(stops, 1)
            XCTAssertFalse(runner.isRunning)
            XCTAssertNil(runner.lastError)
        }
    }

    func testTransportFailureAfterStartStillAttemptsStop() async {
        let shooter = InterruptedStartShooter(transportFailure: true)
        let runner = JobRunner(ticker: FakeTicker())
        runner.start(.movie, on: shooter)
        await runner.wait()
        let stops = await shooter.stops
        XCTAssertEqual(stops, 1)
        XCTAssertNotNil(runner.lastError)
    }

    func testUserStopWhileStartRequestIsPendingStillClosesCameraSession() async {
        for job in [ShootingJob.bulb(duration: .seconds(10)), .movie] {
            let shooter = InterruptedStartShooter(waitForCancellation: true)
            let runner = JobRunner(ticker: FakeTicker())
            runner.start(job, on: shooter)
            while !(await shooter.started) { await Task.yield() }
            runner.stop()
            await runner.wait()
            let stops = await shooter.stops
            XCTAssertEqual(stops, 1)
            XCTAssertNil(runner.lastError)
        }
    }

    func testStopFailureIsReportedInsteadOfPretendingTheCameraStopped() async {
        let shooter = InterruptedStartShooter(stopFails: true)
        let runner = JobRunner(ticker: FakeTicker())
        runner.start(.movie, on: shooter)
        await runner.wait()
        XCTAssertNotNil(runner.lastError)
    }

}

private actor InterruptedStartShooter: Shooter {
    let transportFailure: Bool
    let stopFails: Bool
    let waitForCancellation: Bool
    private(set) var started = false
    private(set) var stops = 0
    init(transportFailure: Bool = false, stopFails: Bool = false, waitForCancellation: Bool = false) {
        self.transportFailure = transportFailure
        self.stopFails = stopFails
        self.waitForCancellation = waitForCancellation
    }
    func takePicture() async throws -> [URL] { [] }
    func setSelfTimer(_ seconds: Int) async throws {}
    func startBulb() async throws {
        started = true
        if waitForCancellation { try await Task.sleep(for: .seconds(60)) }
        if transportFailure { throw URLError(.networkConnectionLost) }
        throw CancellationError()
    }
    func startMovie() async throws { try await startBulb() }
    func stopBulb() async throws {
        try Task.checkCancellation()
        stops += 1
        if stopFails { throw URLError(.notConnectedToInternet) }
    }
    func stopMovie() async throws { try await stopBulb() }
}
