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
    var onDisconnected: (() -> Void)?

    /// Called with postview URLs the camera reports through getEvent (e.g. after bulb).
    var onEventPostviews: (([URL]) -> Void)?

    private(set) var api: CameraAPI
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

    func connect() async {
        guard connection != .connecting else { return }
        disconnect()
        api = CameraAPI(client: SonyClient(baseURL: Self.configuredBase, session: session))
        connection = .connecting
        do {
            let apis = try await api.availableApis(timeout: 3)   // fails fast when not on the camera's Wi-Fi
            if apis.contains("startRecMode") { try await api.startRecMode() }
            merge(try await api.event(longPoll: false))
            await probeSystemAndSyncClock()
            connection = .connected
            onConnected?()
            startEventLoop()
            startLiveView()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        eventTask?.cancel(); eventTask = nil
        liveTask?.cancel(); liveTask = nil
        liveFrame = nil
        let wasConnected = connection == .connected
        if connection != .connecting { connection = .disconnected }
        if wasConnected { onDisconnected?() }
    }

    /// The A7II may or may not expose system.setCurrentTime. Log what it offers and use it when present.
    private func probeSystemAndSyncClock() async {
        clockSetAutomatically = false
        systemApis = (try? await api.availableApis(service: "system")) ?? []
        print("[probe] camera APIs: \(state.availableApis ?? [])")
        print("[probe] system APIs: \(systemApis)")
        if systemApis.contains("setCurrentTime") {
            do {
                try await api.setCurrentTime(Date())
                clockSetAutomatically = true
            } catch {
                print("[probe] setCurrentTime failed: \(error)")
            }
        }
    }

    private func startEventLoop() {
        eventTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let api = self?.api else { return }
                do {
                    let event = try await api.event(longPoll: true)
                    failures = 0
                    self?.merge(event)
                } catch let e as SonyError where e.code == SonyError.alreadyPolling {
                    try? await Task.sleep(for: .milliseconds(300))
                } catch is SonyError {
                    failures = 0
                    try? await Task.sleep(for: .seconds(1))
                } catch {
                    if Task.isCancelled { return }
                    if await self?.cameraAnswers(api) == true { failures = 0 } else { failures += 1 }
                    if failures >= 3 {
                        self?.connection = .failed("Lost connection to the camera")
                        self?.liveTask?.cancel()
                        self?.onDisconnected?()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// A long-poll can time out on a camera that simply has nothing to report, so ask it directly.
    private func cameraAnswers(_ api: CameraAPI) async -> Bool {
        do {
            merge(try await api.event(longPoll: false))
            return true
        } catch is SonyError {
            return true
        } catch {
            return false
        }
    }

    private func startLiveView() {
        guard connection == .connected, liveTask == nil, can("startLiveview") else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let api = self?.api else { return }
                do {
                    let url = try await api.startLiveview()
                    for await jpeg in LiveViewStream().frames(from: url) {
                        if Task.isCancelled { break }
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

    /// Runs a camera command and reports failures in `lastError` instead of throwing into the UI.
    func perform(_ op: @escaping @Sendable (CameraAPI) async throws -> Void) {
        let api = self.api
        Task {
            do { try await op(api) } catch { lastError = error.localizedDescription }
        }
    }

    func touchFocus(xPercent: Double, yPercent: Double) async -> Bool {
        do { return try await api.touchAF(x: xPercent, y: yPercent) } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
