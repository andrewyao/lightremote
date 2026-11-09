import Foundation
import Observation

enum ShootingJob: Equatable, Sendable {
    case single
    case selfTimer(seconds: Int)
    /// `count == nil` runs until stopped.
    case interval(every: Duration, count: Int?)
    case bulb(duration: Duration)
    case movie

    var title: String {
        switch self {
        case .single: "Single"
        case .selfTimer: "Self-timer"
        case .interval: "Interval"
        case .bulb: "Bulb"
        case .movie: "Movie"
        }
    }
}

/// The camera operations a job needs. `CameraAPI` conforms; tests use a recording fake.
protocol Shooter: Sendable {
    func takePicture() async throws -> [URL]
    func setSelfTimer(_ seconds: Int) async throws
    func startBulb() async throws
    func stopBulb() async throws
    func startMovie() async throws
    func stopMovie() async throws
}
extension CameraAPI: Shooter {}

protocol Ticker: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct SystemTicker: Ticker {
    var now: ContinuousClock.Instant { .now }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}

struct JobProgress: Equatable {
    var job: ShootingJob
    var shotsTaken = 0
    var startedAt: ContinuousClock.Instant
    /// Next shot (interval), shutter release (self-timer) or exposure end (bulb).
    var nextEventAt: ContinuousClock.Instant?
    var endsAt: ContinuousClock.Instant?
}

/// How a finished shot should be treated: self-timer and bulb shots can't be used to measure the camera clock,
/// because the phone doesn't know exactly when the exposure started.
struct ShotResult: Sendable {
    var urls: [URL]
    var takenAt: Date
    var clockReliable: Bool
}

@MainActor @Observable
final class JobRunner {
    private(set) var progress: JobProgress?
    var lastError: String?
    var isRunning: Bool { progress != nil }

    var onShot: ((ShotResult) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var stopRequested = false
    private let ticker: any Ticker
    /// EXIF records when the shutter opened and the shot is timed at the midpoint of the camera call, so a call
    /// this short keeps the error within a second. Long exposures take longer than this.
    private static let maxClockSyncRoundTrip: Duration = .seconds(2)

    init(ticker: any Ticker = SystemTicker()) { self.ticker = ticker }

    func start(_ job: ShootingJob, on shooter: any Shooter) {
        guard task == nil else { return }
        stopRequested = false
        progress = JobProgress(job: job, startedAt: ticker.now)
        onRunningChanged?(true)
        task = Task {
            do {
                try await run(job, shooter)
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
            progress = nil
            task = nil
            onRunningChanged?(false)
        }
    }

    /// Stops the running job. Bulb and movie are closed on the camera; intervals stop before the next shot.
    func stop() {
        stopRequested = true
        task?.cancel()
    }

    /// Waits for the task to finish (tests).
    func wait() async { await task?.value }

    private func shoot(_ shooter: any Shooter, clockReliable: Bool) async throws {
        let started = ticker.now
        let before = Date()
        let urls = try await shooter.takePicture()
        let after = Date()
        progress?.shotsTaken += 1
        onShot?(ShotResult(urls: urls, takenAt: before.addingTimeInterval(after.timeIntervalSince(before) / 2),
                           clockReliable: clockReliable && ticker.now - started <= Self.maxClockSyncRoundTrip))
    }

    private func run(_ job: ShootingJob, _ shooter: any Shooter) async throws {
        switch job {
        case .single:
            try await shoot(shooter, clockReliable: true)

        case .selfTimer(let seconds):
            try await shooter.setSelfTimer(seconds)
            progress?.nextEventAt = ticker.now + .seconds(seconds)
            defer { Task { try? await shooter.setSelfTimer(0) } }
            try await shoot(shooter, clockReliable: false)

        case .interval(let every, let count):
            let start = ticker.now
            if let count { progress?.endsAt = start + every * (count - 1) }
            var k = 0
            while count == nil || k < count! {
                try Task.checkCancellation()
                let scheduled = start + every * k
                progress?.nextEventAt = scheduled
                if scheduled > ticker.now { try await ticker.sleep(until: scheduled) }
                try Task.checkCancellation()
                do {
                    try await shoot(shooter, clockReliable: true)
                } catch let e as SonyError where e.code == SonyError.illegalState {
                    lastError = "Shot \(k + 1) skipped: camera busy"   // keep the sequence going
                }
                k += 1
            }

        case .bulb(let duration):
            let end = ticker.now + duration
            progress?.nextEventAt = end
            progress?.endsAt = end
            try await shooter.startBulb()
            do {
                try await ticker.sleep(until: end)
            } catch {
                // Stopped early: still close the shutter. A fresh Task isn't cancelled.
                try await Task { try await shooter.stopBulb() }.value
                progress?.shotsTaken += 1
                throw error
            }
            try await shooter.stopBulb()
            progress?.shotsTaken += 1   // postview arrives through getEvent

        case .movie:
            try await shooter.startMovie()
            while !stopRequested {
                do { try await ticker.sleep(until: ticker.now + .milliseconds(250)) } catch { break }
            }
            try await Task { try await shooter.stopMovie() }.value
        }
    }
}
