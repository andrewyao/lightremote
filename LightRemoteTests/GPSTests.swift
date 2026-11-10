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

    func testMissingFixesDoNotFabricateAStationaryStay() {
        var log = DayLog(day: "x")
        log.append(point(0, 37.0, -122.0))
        log.append(point(3600, 37.0005, -122.0))
        XCTAssertEqual(log.points.count, 2)
        XCTAssertNil(log.location(at: t0.addingTimeInterval(1800)))
        log.append(point(7200, 37.05, -122.0))
        XCTAssertEqual(log.points.count, 3)
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

    func testSharedClockFixturesPreserveMeasurementTimesAndCoverageInGPX() throws {
        let url = try XCTUnwrap(Bundle(for: GPSTests.self).url(forResource: "clock_matching", withExtension: "json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let iso = ISO8601DateFormatter()
        for item in cases {
            var log = DayLog(day: "2026-11-08")
            let times = try XCTUnwrap(item["points"] as? [String])
            log.points = try times.map { text in
                TrackPoint(time: try XCTUnwrap(iso.date(from: text)), latitude: 37, longitude: -122,
                           elevation: nil, accuracy: 5)
            }
            let clocks = try XCTUnwrap(item["clock"] as? [[Any]])
            log.clockOffsets = try clocks.map { values in
                ClockOffsetEntry(measuredAt: try XCTUnwrap(iso.date(from: values[0] as! String)),
                                 cameraMinusUTCSeconds: values[1] as! Int)
            }
            let offsets = try XCTUnwrap(item["offsets"] as? [[Any]])
            log.utcOffsets = try offsets.map { values in
                UTCOffsetEntry(from: try XCTUnwrap(iso.date(from: values[0] as! String)),
                               minutes: values[1] as! Int, zone: "Test")
            }
            let gpx = GPX.render(log)
            XCTAssertTrue(XMLParser(data: Data(gpx.utf8)).parse())
            for values in clocks {
                XCTAssertTrue(gpx.contains("measuredAt=\"\(values[0])\" cameraMinusUtcSeconds=\"\(values[1])\""))
            }
            for time in times { XCTAssertTrue(gpx.contains("<time>\(time)</time>")) }
            if let offset = item["expectedOffset"] as? Int {
                let wall = try XCTUnwrap(iso.date(from: (item["wall"] as! String) + "Z"))
                XCTAssertNotNil(log.location(at: wall.addingTimeInterval(-Double(offset))))
            }
        }
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
