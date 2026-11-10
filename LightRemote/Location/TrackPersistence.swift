import Foundation

/// Keeps failed writes across day rollover; local logs and each export destination retry independently.
final class TrackPersistence {
    typealias Writer = (Data, URL, Bool) throws -> Void
    let logFolder: URL
    let localGPX: URL
    private(set) var cloudGPX: URL?
    private var logs: [String: DayLog] = [:]
    private var localExports: Set<String> = []
    private var cloudExports: Set<String> = []
    private let write: Writer

    init(logFolder: URL, localGPX: URL, write: @escaping Writer = TrackPersistence.writeFile) {
        self.logFolder = logFolder
        self.localGPX = localGPX
        self.write = write
        localExports = staleDays(in: localGPX)
    }

    /// Days whose GPX in `folder` is missing or older than the saved log, e.g. an export that failed before the
    /// app quit. Up-to-date exports are left alone so a launch doesn't rewrite the whole history.
    private func staleDays(in folder: URL) -> Set<String> {
        let fm = FileManager.default
        let logs = (try? fm.contentsOfDirectory(at: logFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Set(logs.compactMap { log -> String? in
            let day = log.deletingPathExtension().lastPathComponent
            guard log.pathExtension == "json", Self.validDay(day) else { return nil }
            let gpx = folder.appendingPathComponent(GPX.relativePath(day: day))
            // An iCloud file that isn't downloaded shows up only as a placeholder; treat it as current.
            let placeholder = gpx.deletingLastPathComponent().appendingPathComponent(".\(day).gpx.icloud")
            guard let exported = Self.modified(gpx) ?? (fm.fileExists(atPath: placeholder.path) ? .distantFuture : nil)
            else { return day }
            return (Self.modified(log) ?? .distantPast) > exported ? day : nil
        })
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func validDay(_ day: String) -> Bool {
        day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    func load(_ day: String) -> DayLog? {
        guard Self.validDay(day) else { return nil }
        if let log = logs[day] { return log }
        guard let data = try? Data(contentsOf: logFolder.appendingPathComponent("\(day).json")) else { return nil }
        guard let log = try? JSONDecoder().decode(DayLog.self, from: data), log.day == day else { return nil }
        return log
    }

    func stage(_ log: DayLog) {
        guard Self.validDay(log.day) else { return }
        logs[log.day] = log
        localExports.insert(log.day)
        if cloudGPX != nil { cloudExports.insert(log.day) }
    }

    func setCloudFolder(_ folder: URL) {
        cloudGPX = folder
        cloudExports.formUnion(staleDays(in: folder))
        cloudExports.formUnion(logs.keys)
    }

    /// Returns errors for the UI while retaining only the destinations that still need writing.
    func flush() -> String? {
        var errors: [String] = []
        for (day, log) in logs {
            do {
                try write(JSONEncoder().encode(log), logFolder.appendingPathComponent("\(day).json"), false)
                logs[day] = nil
            } catch { errors.append("Track \(day): \(error.localizedDescription)") }
        }
        for day in localExports {
            do {
                guard let log = load(day) else { throw CocoaError(.fileReadCorruptFile) }
                try write(Data(GPX.render(log).utf8), localGPX.appendingPathComponent(GPX.relativePath(day: day)), false)
                localExports.remove(day)
            } catch { errors.append("GPX \(day): \(error.localizedDescription)") }
        }
        if let cloudGPX {
            for day in cloudExports {
                do {
                    guard let log = load(day) else { throw CocoaError(.fileReadCorruptFile) }
                    try write(Data(GPX.render(log).utf8), cloudGPX.appendingPathComponent(GPX.relativePath(day: day)), true)
                    cloudExports.remove(day)
                } catch { errors.append("iCloud GPX \(day): \(error.localizedDescription)") }
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private static func writeFile(_ data: Data, _ url: URL, _ coordinated: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !coordinated { try data.write(to: url, options: .atomic); return }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}
