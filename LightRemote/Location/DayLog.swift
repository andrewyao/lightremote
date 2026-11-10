import Foundation

struct TrackPoint: Codable, Equatable, Sendable {
    var time: Date
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var accuracy: Double
}

/// The phone's UTC offset starting at `from`. A new entry is logged whenever it changes (DST, travel).
struct UTCOffsetEntry: Codable, Equatable, Sendable {
    var from: Date
    var minutes: Int
    var zone: String
}

/// Camera wall clock minus UTC, measured from a remote shot's EXIF DateTimeOriginal.
/// Includes the camera's time zone, DST setting and drift in one number.
struct ClockOffsetEntry: Codable, Equatable, Sendable {
    var measuredAt: Date
    var cameraMinusUTCSeconds: Int
}

/// Everything recorded on one local calendar day; rendered to `GPX/<day>.gpx`.
struct DayLog: Codable, Equatable, Sendable {
    var day: String
    var points: [TrackPoint] = []
    var shots: [Date] = []
    var utcOffsets: [UTCOffsetEntry] = []
    var clockOffsets: [ClockOffsetEntry] = []

    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Logs the phone's UTC offset if it differs from the last entry.
    mutating func noteUTCOffset(at date: Date, timeZone: TimeZone = .current) {
        let minutes = timeZone.secondsFromGMT(for: date) / 60
        if utcOffsets.last?.minutes != minutes {
            utcOffsets.append(UTCOffsetEntry(from: date, minutes: minutes, zone: timeZone.identifier))
        }
    }

    /// Missing fixes are unknown travel, even when the next fix returns to the same place.
    mutating func append(_ point: TrackPoint) {
        guard points.last.map({ $0.time < point.time }) ?? true else { return }
        points.append(point)
    }

    static func meters(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Nearest fix within `tolerance`, interpolated between neighbours.
    func location(at date: Date, tolerance: TimeInterval = 300) -> TrackPoint? {
        guard !points.isEmpty else { return nil }
        let i = points.firstIndex { $0.time >= date } ?? points.count
        let before = i > 0 ? points[i - 1] : nil
        let after = i < points.count ? points[i] : nil
        switch (before, after) {
        case let (b?, a?):
            let span = a.time.timeIntervalSince(b.time)
            if span > 0, span <= tolerance * 2 {
                let t = date.timeIntervalSince(b.time) / span
                return TrackPoint(time: date, latitude: b.latitude + (a.latitude - b.latitude) * t,
                                  longitude: b.longitude + (a.longitude - b.longitude) * t,
                                  elevation: b.elevation, accuracy: max(b.accuracy, a.accuracy))
            }
            let nearest = date.timeIntervalSince(b.time) < a.time.timeIntervalSince(date) ? b : a
            return abs(nearest.time.timeIntervalSince(date)) <= tolerance ? nearest : nil
        case let (b?, nil): return date.timeIntervalSince(b.time) <= tolerance ? b : nil
        case let (nil, a?): return a.time.timeIntervalSince(date) <= tolerance ? a : nil
        default: return nil
        }
    }
}

enum GPX {
    static let namespace = "https://lightremote.app/gpx/1"

    static func render(_ log: DayLog) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func t(_ d: Date) -> String { iso.string(from: d) }
        func coord(_ v: Double) -> String { String(format: "%.7f", v) }

        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="LightRemote" xmlns="http://www.topografix.com/GPX/1/1" xmlns:lr="\(namespace)">
          <metadata>
            <name>\(log.day)</name>
            <extensions>

        """
        for o in log.utcOffsets {
            x += "      <lr:utcOffset from=\"\(t(o.from))\" minutes=\"\(o.minutes)\" zone=\"\(escape(o.zone))\"/>\n"
        }
        for c in log.clockOffsets {
            x += "      <lr:cameraClock measuredAt=\"\(t(c.measuredAt))\" cameraMinusUtcSeconds=\"\(c.cameraMinusUTCSeconds)\"/>\n"
        }
        for s in log.shots { x += "      <lr:shot time=\"\(t(s))\"/>\n" }
        x += """
            </extensions>
          </metadata>
          <trk>
            <name>\(log.day)</name>
            <trkseg>

        """
        for p in log.points {
            x += "      <trkpt lat=\"\(coord(p.latitude))\" lon=\"\(coord(p.longitude))\">"
            if let e = p.elevation { x += "<ele>\(String(format: "%.1f", e))</ele>" }
            x += "<time>\(t(p.time))</time><hdop>\(String(format: "%.1f", p.accuracy / 5))</hdop></trkpt>\n"
        }
        x += "    </trkseg>\n  </trk>\n</gpx>\n"
        return x
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
