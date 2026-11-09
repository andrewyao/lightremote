import CoreLocation
import Foundation
import Observation

/// Records the GPS track (one DayLog per local day), persists it, and writes `GPX/<day>.gpx`
/// to iCloud Drive (or the app's Documents folder when iCloud isn't available).
@MainActor @Observable
final class TrackRecorder {
    enum Mode: Equatable { case off, lowPower, precise }

    /// Precise GPS (camera connected or Record tapped). Drives the Live Activity and REC chip.
    private(set) var isRecording = false
    /// All-day tracking for battery: Wi-Fi/cell positioning (~100 m), a point per ~100 m moved, nothing while
    /// standing still. Survives app termination via significant-location-change relaunch.
    var allDay: Bool {
        didSet {
            UserDefaults.standard.set(allDay, forKey: Self.allDayKey)
            if allDay { manager.requestAlwaysAuthorization() }
            applyMode()
        }
    }
    private(set) var mode: Mode = .off
    private(set) var today: DayLog
    private(set) var lastFix: TrackPoint?
    private(set) var recordingStartedAt: Date?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var gpxFolder: URL
    private(set) var usesICloud = false

    private let manager = CLLocationManager()
    private let engine = LocationEngine()
    private var flushTask: Task<Void, Never>?
    private var background: CLBackgroundActivitySession?
    private let logFolder: URL
    private var dirty = false

    private static let recordingKey = "trackRecording"
    private static let allDayKey = "trackAllDay"
    static let lowPowerSpacing: TimeInterval = 30
    static let lowPowerDistance: CLLocationDistance = 100

    init() {
        let fm = FileManager.default
        logFolder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracks", isDirectory: true)
        let localGPX = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPX", isDirectory: true)
        gpxFolder = localGPX
        try? fm.createDirectory(at: logFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: localGPX, withIntermediateDirectories: true)
        authorization = manager.authorizationStatus
        allDay = UserDefaults.standard.object(forKey: Self.allDayKey) as? Bool ?? true
        let day = DayLog.dayString(Date())
        today = Self.load(day, from: logFolder) ?? DayLog(day: day)

        Task { await resolveICloudFolder() }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.noteTimeZone() }
        }
        engine.manager = manager
        manager.delegate = engine
        engine.onLocations = { [weak self] locs in for l in locs { self?.add(l) } }
        engine.onAuthorization = { [weak self] status in
            self?.authorization = status
            self?.applyMode()
        }
        // Precise GPS never resumes on relaunch (battery); all-day battery-saver tracking does, including a
        // background relaunch by a significant location change.
        UserDefaults.standard.removeObject(forKey: Self.recordingKey)
        applyMode()
    }

    /// Single place that turns the location hardware on/off and sets its accuracy.
    private func applyMode() {
        let new: Mode = isRecording ? .precise : allDay ? .lowPower : .off
        let canBackground = authorization == .authorizedAlways || (isRecording && authorization == .authorizedWhenInUse)
        switch new {
        case .off:
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        case .lowPower:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = Self.lowPowerDistance   // no updates (and little power) while stationary
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = canBackground
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
            if authorization == .authorizedAlways { manager.startMonitoringSignificantLocationChanges() }
        case .precise:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
            manager.activityType = .fitness
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = canBackground
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            if authorization == .authorizedAlways { manager.startMonitoringSignificantLocationChanges() }
        }
        if new == .precise, background == nil { background = CLBackgroundActivitySession() }
        if new != .precise { background?.invalidate(); background = nil }
        if new != .off, flushTask == nil {
            noteTimeZone()
            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.flush()
                }
            }
        } else if new == .off {
            flushTask?.cancel(); flushTask = nil
        }
        mode = new
    }

    /// iCloud lookup can block, so it runs off the main thread. Existing local GPX files are copied over.
    private func resolveICloudFolder() async {
        let local = gpxFolder
        let cloud: URL? = await Task.detached {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            let folder = root.appendingPathComponent("Documents/GPX", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for f in (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? [] {
                let target = folder.appendingPathComponent(f.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: f, to: target)
                }
            }
            return folder
        }.value
        if let cloud {
            gpxFolder = cloud
            usesICloud = true
            writeGPX()
        }
    }

    var gpxFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: gpxFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "gpx" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Precise GPS on (camera connected, or Record tapped).
    func start() {
        guard !isRecording else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        isRecording = true
        recordingStartedAt = Date()
        UserDefaults.standard.set(true, forKey: Self.recordingKey)
        applyMode()
    }

    /// Back to all-day low power (or off).
    func stop() {
        isRecording = false
        recordingStartedAt = nil
        UserDefaults.standard.set(false, forKey: Self.recordingKey)
        applyMode()
        flush()
    }

    /// Upgrades to "Always" so recording survives long sessions in the background.
    func requestAlways() { manager.requestAlwaysAuthorization() }

    private func add(_ loc: CLLocation) {
        let precise = mode == .precise
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= (precise ? 100 : 200) else { return }
        rollDayIfNeeded(loc.timestamp)
        let p = TrackPoint(time: loc.timestamp, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                           elevation: loc.verticalAccuracy >= 0 ? loc.altitude : nil, accuracy: loc.horizontalAccuracy)
        if let last = today.points.last {
            if last.time >= p.time { return }
            // Low power: drop bursts; a point per ~100 m moved is plenty for geotagging.
            if !precise, p.time.timeIntervalSince(last.time) < Self.lowPowerSpacing { return }
        }
        today.noteUTCOffset(at: p.time)
        today.appendFillingStationaryGap(p)
        lastFix = p
        dirty = true
    }

    func noteShot(at date: Date) {
        rollDayIfNeeded(date)
        today.shots.append(date)
        dirty = true
    }

    func noteClockOffset(cameraMinusUTC seconds: Int, at date: Date) {
        rollDayIfNeeded(date)
        today.clockOffsets.append(ClockOffsetEntry(measuredAt: date, cameraMinusUTCSeconds: seconds))
        dirty = true
        flush()
    }

    private func noteTimeZone() {
        today.noteUTCOffset(at: Date())
        dirty = true
    }

    func location(at date: Date) -> TrackPoint? {
        today.location(at: date) ?? (abs((lastFix?.time.timeIntervalSince(date) ?? .infinity)) < 300 ? lastFix : nil)
    }

    private func rollDayIfNeeded(_ date: Date) {
        let day = DayLog.dayString(date)
        guard day != today.day else { return }
        flush()
        today = Self.load(day, from: logFolder) ?? DayLog(day: day)
        today.noteUTCOffset(at: date)
    }

    /// Writes the JSON log and the GPX. Each write replaces the whole file, so a crash can't corrupt it.
    func flush() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(today) {
            try? data.write(to: logFolder.appendingPathComponent("\(today.day).json"), options: .atomic)
        }
        writeGPX()
    }

    private func writeGPX() {
        guard !today.points.isEmpty || !today.shots.isEmpty else { return }
        let url = gpxFolder.appendingPathComponent("\(today.day).gpx")
        let text = GPX.render(today)
        if usesICloud {
            // Coordinated write so iCloud picks up the change.
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
                try? text.write(to: u, atomically: true, encoding: .utf8)
            }
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func load(_ day: String, from folder: URL) -> DayLog? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(day).json")) else { return nil }
        return try? JSONDecoder().decode(DayLog.self, from: data)
    }

    // MARK: Clock / DST status for the Track screen

    /// Latest measured camera clock vs. the phone's local time, in seconds (positive = camera ahead).
    var cameraClockError: Int? {
        guard let measured = today.clockOffsets.last else { return nil }
        let phone = TimeZone.current.secondsFromGMT(for: measured.measuredAt)
        return measured.cameraMinusUTCSeconds - phone
    }

    /// True when the phone's UTC offset changed in the last 7 days (DST switch or travel).
    var recentUTCOffsetChange: Bool {
        let now = Date()
        return TimeZone.current.secondsFromGMT(for: now)
            != TimeZone.current.secondsFromGMT(for: now.addingTimeInterval(-7 * 86_400))
            || Set(today.utcOffsets.map(\.minutes)).count > 1
    }
}

/// CLLocationManager delegate. Kept separate because the delegate must be an NSObject.
/// The manager is created on the main thread, so CoreLocation calls these delegate methods there.
final class LocationEngine: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    weak var manager: CLLocationManager?
    @MainActor var onLocations: (([CLLocation]) -> Void)?
    @MainActor var onAuthorization: ((CLAuthorizationStatus) -> Void)?

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { onLocations?(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { onAuthorization?(status) }
    }
}
