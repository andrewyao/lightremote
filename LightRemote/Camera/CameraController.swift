import Foundation
import Observation
import UIKit

/// Owns the camera connection: startup sequence, getEvent long-poll loop, live view, and setters.
@MainActor @Observable
final class CameraController {
    enum Connection: Equatable { case disconnected, connecting, connected, failed(String) }

    private(set) var connection: Connection = .disconnected
    private(set) var state = CameraEvent()
    private(set) var liveFrame: UIImage?
    private(set) var systemApis: [String] = []
    /// Set when the camera accepted `setCurrentTime` on this connection.
    private(set) var clockSetAutomatically = false
    var lastError: String?
    /// While true, the connect screen keeps retrying. Cleared when the user disconnects on purpose.
    var autoConnect = true
    var onConnected: (() -> Void)?
    var onConnecting: (() -> Void)?
    var onClockSynchronized: ((Date) -> Void)?
    var onDisconnected: (() -> Void)?

    /// Called with postview URLs the camera reports through getEvent (e.g. after bulb).
    var onEventPostviews: (([URL]) -> Void)?

    private(set) var api: CameraAPI
    private(set) var sessionID = UUID()
    private(set) var isChangingMode = false
    private var connectionTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var modeRevision = 0
    private var eventTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    /// Host override for development (e.g. `localhost:8080` for the mock). Set in Advanced settings
    /// or with the launch argument `-cameraHost localhost:8080`.
    static var configuredBase: URL {
        if let host = UserDefaults.standard.string(forKey: "cameraHost"), !host.isEmpty,
           let url = URL(string: "http://\(host)/sony") { return url }
        return SonyClient.cameraBase
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        api = CameraAPI(client: SonyClient(baseURL: Self.configuredBase, session: session))
    }

    func can(_ method: String) -> Bool { state.availableApis?.contains(method) ?? false }

    var isBusy: Bool { (state.cameraStatus ?? "IDLE") != "IDLE" }

    /// Retry policy lives with the connection rather than in a view.
    func search() async {
        while !Task.isCancelled {
            if autoConnect, connection != .connected, connection != .connecting { await connect() }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    func connect() async {
        guard connection != .connecting else { return }
        disconnect()
        let id = sessionID
        let api = CameraAPI(client: SonyClient(baseURL: Self.configuredBase, session: session))
        self.api = api
        connection = .connecting
        onConnecting?()
        let task = Task { await establish(api, id: id) }
        connectionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if sessionID == id { connectionTask = nil }
    }

    private func checkSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
    }

    private func establish(_ api: CameraAPI, id: UUID) async {
        do {
            try checkSession(id)
            let apis = try await api.availableApis(timeout: 3)
            try checkSession(id)
            if apis.contains("startRecMode") { try await api.startRecMode(); try checkSession(id) }
            let event = try await api.event(longPoll: false)
            try checkSession(id)
            merge(event)
            await probeSystemAndSyncClock(api, id: id)
            try checkSession(id)
            connection = .connected
            onConnected?()
            startEventLoop()
            startLiveView()
        } catch {
            guard sessionID == id else { return }
            disconnect()
            if !(error is CancellationError) { connection = .failed(error.localizedDescription) }
        }
    }

    func disconnect() {
        let wasConnected = connection == .connected
        sessionID = UUID()
        connectionTask?.cancel(); connectionTask = nil
        eventTask?.cancel(); eventTask = nil
        liveTask?.cancel(); liveTask = nil
        modeTask?.cancel(); modeTask = nil
        modeRevision += 1
        isChangingMode = false
        liveFrame = nil
        state = CameraEvent()
        systemApis = []
        clockSetAutomatically = false
        lastError = nil
        connection = .disconnected
        if wasConnected { onDisconnected?() }
    }

    private func probeSystemAndSyncClock(_ api: CameraAPI, id: UUID) async {
        do {
            let apis = try await api.availableApis(service: "system")
            try checkSession(id)
            systemApis = apis
            if apis.contains("setCurrentTime") {
                let date = Date()
                try await api.setCurrentTime(date)
                try checkSession(id)
                clockSetAutomatically = true
                onClockSynchronized?(date)
            }
        } catch { /* Clock sync is optional; establish checks cancellation before publishing the connection. */ }
    }

    private func startEventLoop() {
        let id = sessionID
        let api = self.api
        eventTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard self?.sessionID == id else { return }
                do {
                    let event = try await api.event(longPoll: true)
                    guard !Task.isCancelled, self?.sessionID == id else { return }
                    failures = 0
                    self?.merge(event)
                } catch let e as SonyError where e.code == SonyError.alreadyPolling {
                    try? await Task.sleep(for: .milliseconds(300))
                } catch is SonyError {
                    failures = 0
                    try? await Task.sleep(for: .seconds(1))
                } catch {
                    if Task.isCancelled { return }
                    let answers = await self?.cameraAnswers(api, id: id) == true
                    guard !Task.isCancelled, self?.sessionID == id else { return }
                    if answers { failures = 0 } else { failures += 1 }
                    if failures >= 3 {
                        self?.disconnect()
                        self?.connection = .failed("Lost connection to the camera")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// A long-poll can time out on a camera that simply has nothing to report, so ask it directly.
    private func cameraAnswers(_ api: CameraAPI, id: UUID) async -> Bool {
        do {
            let event = try await api.event(longPoll: false)
            try checkSession(id)
            merge(event)
            return true
        } catch is SonyError {
            return true
        } catch {
            return false
        }
    }

    private func startLiveView() {
        guard connection == .connected, liveTask == nil, can("startLiveview") else { return }
        let id = sessionID
        let api = self.api
        let policy = CameraResourcePolicy(baseURL: Self.configuredBase)
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.sessionID == id else { return }
                do {
                    let url = try await api.startLiveview()
                    try policy.validate(url)
                    guard !Task.isCancelled, self?.sessionID == id else { return }
                    for await jpeg in LiveViewStream().frames(from: url, policy: policy) {
                        if Task.isCancelled || self?.sessionID != id { break }
                        if let image = UIImage(data: jpeg) { self?.liveFrame = image }
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(1)) // stream dropped: reconnect
            }
        }
    }

    func merge(_ e: CameraEvent) {
        if let v = e.availableApis {
            state.availableApis = v
            startLiveView()   // the camera may only offer it some time after startRecMode
        }
        if let v = e.cameraStatus { state.cameraStatus = v }
        if let v = e.shootMode { state.shootMode = v }
        if let v = e.exposureMode { state.exposureMode = v }
        if let v = e.fNumber { state.fNumber = v }
        if let v = e.shutterSpeed { state.shutterSpeed = v }
        if let v = e.iso { state.iso = v }
        if let v = e.focusMode { state.focusMode = v }
        if let v = e.selfTimer { state.selfTimer = v }
        if let v = e.exposureCompensation { state.exposureCompensation = v }
        if let v = e.recordableImages { state.recordableImages = v }
        if let v = e.batteryPercent { state.batteryPercent = v }
        if !e.takePictureURLs.isEmpty { onEventPostviews?(e.takePictureURLs) }
    }

    /// Queue transitions so a delayed older command cannot overtake the latest selection.
    func selectMode(_ mode: ShootMode) {
        guard connection == .connected else { return }
        let previous = modeTask
        let id = sessionID
        let api = self.api
        modeRevision += 1
        let revision = modeRevision
        isChangingMode = true
        modeTask = Task {
            await previous?.value
            do {
                try checkSession(id)
                let saved = UserDefaults.standard.string(forKey: "shutterBeforeBulb")
                var change = mode.change(from: state, shutterBeforeBulb: saved)
                if let value = change.shootMode {
                    try await api.setShootMode(value)
                    try await confirmMode(api, id: id, shootMode: value)
                    change = mode.change(from: state, shutterBeforeBulb: saved)
                }
                if let value = change.shutterSpeed {
                    try await api.setShutterSpeed(value)
                    try await confirmMode(api, id: id, shutterSpeed: value)
                }
                try checkSession(id)
                UserDefaults.standard.set(change.shutterBeforeBulb, forKey: "shutterBeforeBulb")
            } catch {
                if sessionID == id, !(error is CancellationError) { lastError = error.localizedDescription }
            }
            if sessionID == id, modeRevision == revision { isChangingMode = false; modeTask = nil }
        }
    }

    private func confirmMode(_ api: CameraAPI, id: UUID, shootMode: String? = nil,
                             shutterSpeed: String? = nil) async throws {
        for _ in 0..<10 {
            let event = try await api.event(longPoll: false)
            try checkSession(id)
            merge(event)
            if (shootMode == nil || state.shootMode?.current == shootMode),
               (shutterSpeed == nil || state.shutterSpeed?.current == shutterSpeed) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SonyError(code: -1, message: "Camera did not confirm the selected mode")
    }

    /// Waits for queued mode transitions (also useful to callers that need a ready camera).
    func waitForMode() async { await modeTask?.value }

    /// Runs a camera command and reports failures in `lastError` instead of throwing into the UI.
    func perform(_ op: @escaping @Sendable (CameraAPI) async throws -> Void) {
        let api = self.api
        let id = sessionID
        Task {
            do { try await op(api) }
            catch { if sessionID == id, !Task.isCancelled { lastError = error.localizedDescription } }
        }
    }

    func touchFocus(xPercent: Double, yPercent: Double) async -> Bool {
        let id = sessionID
        do {
            let locked = try await api.touchAF(x: xPercent, y: yPercent)
            try checkSession(id)
            return locked
        } catch {
            if sessionID == id, !(error is CancellationError) { lastError = error.localizedDescription }
            return false
        }
    }
}
