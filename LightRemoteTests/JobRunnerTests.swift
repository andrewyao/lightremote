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
}
