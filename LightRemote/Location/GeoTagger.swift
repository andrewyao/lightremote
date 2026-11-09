import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GeoTagger {
    /// Returns the JPEG with a GPS dictionary added. Pixels aren't re-encoded.
    static func addingGPS(to jpeg: Data, point: TrackPoint) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }

        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy:MM:dd"
        let dateStamp = utc.string(from: point.time)
        utc.dateFormat = "HH:mm:ss"
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(point.latitude),
            kCGImagePropertyGPSLatitudeRef: point.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(point.longitude),
            kCGImagePropertyGPSLongitudeRef: point.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSDateStamp: dateStamp,
            kCGImagePropertyGPSTimeStamp: utc.string(from: point.time),
            kCGImagePropertyGPSHPositioningError: point.accuracy,
        ]
        if let e = point.elevation {
            gps[kCGImagePropertyGPSAltitude] = abs(e)
            gps[kCGImagePropertyGPSAltitudeRef] = e >= 0 ? 0 : 1
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMergeMetadata: true,
            kCGImageDestinationMetadata: metadata(gps: gps),
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else { return nil }
        return out as Data
    }

    private static func metadata(gps: [CFString: Any]) -> CGImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        for (key, value) in gps {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, key, value as CFTypeRef)
        }
        return meta
    }

    /// EXIF DateTimeOriginal, read as if it were UTC (the camera stores local wall-clock time with no zone).
    static func cameraWallClock(of jpeg: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    static func gps(of jpeg: Data) -> (latitude: Double, longitude: Double)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = g[kCGImagePropertyGPSLatitude] as? Double,
              let lon = g[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        return ((g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat,
                (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon)
    }
}
