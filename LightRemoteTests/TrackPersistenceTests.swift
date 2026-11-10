import XCTest
@testable import LightRemote

final class TrackPersistenceTests: XCTestCase {
    func testFailedLocalWriteSurvivesRolloverAndRetriesWithoutNewPoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = true
        var writes: [String] = []
        let store = TrackPersistence(logFolder: root.appendingPathComponent("logs"),
                                     localGPX: root.appendingPathComponent("GPX")) { data, url, _ in
            if fail && url.pathExtension == "json" { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            writes.append(url.lastPathComponent)
        }
        var first = DayLog(day: "2026-11-08")
        first.shots = [Date(timeIntervalSince1970: 1)]
        store.stage(first)
        XCTAssertNotNil(store.flush())
        store.stage(DayLog(day: "2026-11-09"))
        XCTAssertEqual(store.load(first.day), first, "unsaved previous day remains available")
        fail = false
        XCTAssertNil(store.flush())
        XCTAssertEqual(store.load(first.day), first)
        XCTAssertTrue(writes.contains("2026-11-08.json"))
        XCTAssertTrue(writes.contains("2026-11-09.json"))
        let count = writes.count
        XCTAssertNil(store.flush())
        XCTAssertEqual(writes.count, count, "successful destinations aren't rewritten")
    }

    func testCloudFailureKeepsLocalBackupAndRecoversAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        var failCloud = true
        let writer: TrackPersistence.Writer = { data, url, coordinated in
            if coordinated && failCloud { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let first = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        first.setCloudFolder(cloud)
        var log = DayLog(day: "2026-11-08")
        log.shots = [Date()]
        first.stage(log)
        XCTAssertNotNil(first.flush())
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("2026/11/2026-11-08.gpx").path))
        failCloud = false
        let relaunched = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        relaunched.setCloudFolder(cloud)
        XCTAssertNil(relaunched.flush())
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("2026/11/2026-11-08.gpx")),
                       Data(GPX.render(log).utf8))
    }

    func testRelaunchOnlyExportsMissingOrOutdatedDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        var writes: [String] = []
        let writer: TrackPersistence.Writer = { data, url, coordinated in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            writes.append((coordinated ? "cloud/" : "") + url.lastPathComponent)
        }
        let first = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        first.setCloudFolder(cloud)
        for day in ["2026-11-07", "2026-11-08", "2026-11-09"] { first.stage(DayLog(day: day)) }
        XCTAssertNil(first.flush())

        try FileManager.default.removeItem(at: local.appendingPathComponent("2026/11/2026-11-07.gpx"))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
                                              ofItemAtPath: cloud.appendingPathComponent("2026/11/2026-11-08.gpx").path)
        writes = []
        let relaunched = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        relaunched.setCloudFolder(cloud)
        XCTAssertNil(relaunched.flush())
        XCTAssertEqual(Set(writes), ["2026-11-07.gpx", "cloud/2026-11-08.gpx"])
    }

    func testUndownloadedICloudPlaceholderInMonthFolderCountsAsExported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        var writes: [String] = []
        let writer: TrackPersistence.Writer = { data, url, coordinated in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            writes.append((coordinated ? "cloud/" : "") + url.lastPathComponent)
        }
        let first = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        first.setCloudFolder(cloud)
        first.stage(DayLog(day: "2025-01-31"))
        XCTAssertNil(first.flush())
        let month = cloud.appendingPathComponent("2025/01")
        try FileManager.default.removeItem(at: month.appendingPathComponent("2025-01-31.gpx"))
        FileManager.default.createFile(atPath: month.appendingPathComponent(".2025-01-31.gpx.icloud").path, contents: Data())
        writes = []
        let relaunched = TrackPersistence(logFolder: logs, localGPX: local, write: writer)
        relaunched.setCloudFolder(cloud)
        XCTAssertNil(relaunched.flush())
        XCTAssertEqual(writes, [])
    }
}
