import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LightRemote

final class GPSTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func point(_ s: TimeInterval, _ lat: Double, _ lon: Double) -> TrackPoint {
        TrackPoint(time: t0.addingTimeInterval(s), latitude: lat, longitude: lon, elevation: 12, accuracy: 5)
    }

    func testLocationInterpolatesAndRespectsTolerance() throws {
        var log = DayLog(day: "x")
        log.points = [point(0, 37.0, -122.0), point(10, 37.001, -122.002)]
        let mid = try XCTUnwrap(log.location(at: t0.addingTimeInterval(5)))
        XCTAssertEqual(mid.latitude, 37.0005, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, -122.001, accuracy: 1e-9)
        XCTAssertEqual(log.location(at: t0.addingTimeInterval(200))?.latitude, 37.001)   // within 5 min
        XCTAssertNil(log.location(at: t0.addingTimeInterval(1000)))                      // too far from any fix
        XCTAssertNil(DayLog(day: "y").location(at: t0))
    }

    func testStationaryGapIsFilledButRealMovementIsNot() {
        var log = DayLog(day: "x")
        log.appendFillingStationaryGap(point(0, 37.0, -122.0))
        log.appendFillingStationaryGap(point(3600, 37.0005, -122.0))   // an hour later, ~55 m away: sat still
        // 14 fill points at 4-min spacing + one just before the new fix, all at the old position.
        XCTAssertEqual(log.points.count, 17)
        let gaps = zip(log.points, log.points.dropFirst()).map { $1.time.timeIntervalSince($0.time) }
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, 240)
        XCTAssertTrue(log.points[1..<16].allSatisfy { $0.latitude == 37.0 })
        // A photo in the middle of the hour now gets a location instead of falling in a gap.
        XCTAssertEqual(log.location(at: t0.addingTimeInterval(1800))?.latitude ?? 0, 37.0, accuracy: 1e-9)

        log.appendFillingStationaryGap(point(7200, 37.05, -122.0))     // 5 km away after a gap: travelled
        XCTAssertEqual(log.points.count, 18, "no fake 'stayed here' point when the phone actually moved")
        XCTAssertEqual(DayLog.meters(point(0, 37, -122), point(0, 37.001, -122)), 111.2, accuracy: 0.5)
    }

    func testUTCOffsetLoggedAcrossDSTChange() throws {
        // US DST ended 2026-11-01 at 2:00 local (09:00 UTC).
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        var log = DayLog(day: "2026-11-01")
        log.noteUTCOffset(at: iso.date(from: "2026-11-01T08:00:00Z")!, timeZone: la)
        log.noteUTCOffset(at: iso.date(from: "2026-11-01T08:30:00Z")!, timeZone: la)
        log.noteUTCOffset(at: iso.date(from: "2026-11-01T09:30:00Z")!, timeZone: la)
        XCTAssertEqual(log.utcOffsets.map(\.minutes), [-420, -480])
    }

    func testClockOffsetUsesMedian() {
        var log = DayLog(day: "x")
        log.clockOffsets = [3, 4, 30, 3].map { ClockOffsetEntry(measuredAt: t0, cameraMinusUTCSeconds: $0) }
        XCTAssertEqual(log.cameraMinusUTC, 4)
    }

    func testGPXIsValidXMLWithTrackAndMetadata() throws {
        var log = DayLog(day: "2026-11-07")
        log.points = [point(0, 37.7749, -122.4194), point(5, 37.775, -122.4195)]
        log.shots = [t0.addingTimeInterval(3)]
        log.utcOffsets = [UTCOffsetEntry(from: t0, minutes: -480, zone: "America/Los_Angeles")]
        log.clockOffsets = [ClockOffsetEntry(measuredAt: t0, cameraMinusUTCSeconds: -28797)]
        let gpx = GPX.render(log)

        final class Collector: NSObject, XMLParserDelegate {
            var elements: [String: [[String: String]]] = [:]
            func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                elements[name, default: []].append(attributes)
            }
        }
        let c = Collector()
        let parser = XMLParser(data: Data(gpx.utf8))
        parser.delegate = c
        XCTAssertTrue(parser.parse(), "\(parser.parserError?.localizedDescription ?? "")\n\(gpx)")
        XCTAssertEqual(c.elements["trkpt"]?.count, 2)
        XCTAssertEqual(c.elements["trkpt"]?.first?["lat"], "37.7749000")
        XCTAssertEqual(c.elements["lr:cameraClock"]?.first?["cameraMinusUtcSeconds"], "-28797")
        XCTAssertEqual(c.elements["lr:utcOffset"]?.first?["minutes"], "-480")
        XCTAssertEqual(c.elements["lr:shot"]?.count, 1)
        XCTAssertTrue(gpx.contains("<time>2026-10-26T"), "UTC timestamps")
    }

    // MARK: JPEG EXIF

    private func makeJPEG(dateTimeOriginal: String?) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let d = dateTimeOriginal { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: d] }
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testAddingGPSRoundTripsAndKeepsDateTimeOriginal() throws {
        let jpeg = try makeJPEG(dateTimeOriginal: "2026:11:07 10:42:07")
        let tagged = try XCTUnwrap(GeoTagger.addingGPS(to: jpeg, point: point(0, 37.7749, -122.4194)))
        let gps = try XCTUnwrap(GeoTagger.gps(of: tagged))
        XCTAssertEqual(gps.latitude, 37.7749, accuracy: 1e-4)
        XCTAssertEqual(gps.longitude, -122.4194, accuracy: 1e-4)
        XCTAssertEqual(GeoTagger.cameraWallClock(of: tagged), GeoTagger.cameraWallClock(of: jpeg))
    }

    func testCameraWallClockReadsDateTimeOriginalAsUTC() throws {
        let jpeg = try makeJPEG(dateTimeOriginal: "2026:11:07 10:42:07")
        XCTAssertEqual(GeoTagger.cameraWallClock(of: jpeg), ISO8601DateFormatter().date(from: "2026-11-07T10:42:07Z"))
        XCTAssertNil(GeoTagger.cameraWallClock(of: try makeJPEG(dateTimeOriginal: nil)))
    }
}
