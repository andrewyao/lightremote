import Foundation

struct Setting<Value: Sendable & Equatable>: Sendable, Equatable {
    var current: Value
    var candidates: [Value]
}

/// Exposure compensation as the camera reports it: integer indices, `step` = 1 means 1/3 EV, 2 means 1/2 EV.
struct EVSetting: Sendable, Equatable {
    var currentIndex: Int
    var minIndex: Int
    var maxIndex: Int
    var step: Int

    var stepSize: Double { step == 2 ? 0.5 : 1.0 / 3.0 }
    var indices: [Int] {
        guard (-100...100).contains(minIndex), (-100...100).contains(maxIndex),
              minIndex <= maxIndex else { return [] }
        return Array(minIndex...maxIndex)
    }
    func ev(_ index: Int) -> Double { Double(index) * stepSize }
    static func label(_ ev: Double) -> String { ev == 0 ? "±0.0" : String(format: "%+.1f", ev) }
}

/// One `getEvent` result. Fields stay nil when that event didn't report them, so updates merge.
struct CameraEvent: Sendable, Equatable {
    var availableApis: [String]?
    var cameraStatus: String?
    var takePictureURLs: [URL] = []
    var shootMode: Setting<String>?
    var exposureMode: Setting<String>?
    var fNumber: Setting<String>?
    var shutterSpeed: Setting<String>?
    var iso: Setting<String>?
    var focusMode: Setting<String>?
    var selfTimer: Setting<Int>?
    var exposureCompensation: EVSetting?
    var recordableImages: Int?
    var batteryPercent: Int?

    /// The API returns a positional array whose entries are objects (or arrays of objects) tagged by "type".
    /// Index positions differ between cameras and versions, so we match on "type" only.
    init(result: [JSON]) {
        for entry in result {
            let objects: [JSON] = entry.array ?? [entry]
            for obj in objects { apply(obj) }
        }
    }

    init() {}

    private mutating func apply(_ o: JSON) {
        func setting(_ name: String) -> Setting<String>? {
            let key = name.prefix(1).uppercased() + name.dropFirst()
            guard let cur = o["current\(key)"]?.string else { return nil }
            return Setting(current: cur, candidates: o["\(name)Candidates"]?.strings ?? [])
        }
        switch o["type"]?.string {
        case "availableApiList": availableApis = o["names"]?.strings
        case "cameraStatus": cameraStatus = o["cameraStatus"]?.string
        case "takePicture":
            takePictureURLs += (o["takePictureUrl"]?.strings ?? []).compactMap(URL.init(string:))
        case "shootMode": shootMode = setting("shootMode")
        case "exposureMode": exposureMode = setting("exposureMode")
        case "fNumber": fNumber = setting("fNumber")
        case "shutterSpeed": shutterSpeed = setting("shutterSpeed")
        case "isoSpeedRate": iso = setting("isoSpeedRate")
        case "focusMode": focusMode = setting("focusMode")
        case "selfTimer":
            if let cur = o["currentSelfTimer"]?.int, (0...60).contains(cur) {
                selfTimer = Setting(current: cur, candidates: o["selfTimerCandidates"]?.array?.compactMap(\.int)
                    .filter { (0...60).contains($0) } ?? [])
            }
        case "exposureCompensation":
            if let cur = o["currentExposureCompensation"]?.int, (-100...100).contains(cur),
               let min = o["minExposureCompensation"]?.int, let max = o["maxExposureCompensation"]?.int,
               (-100...100).contains(min), (-100...100).contains(max), min <= cur, cur <= max {
                exposureCompensation = EVSetting(
                    currentIndex: cur,
                    minIndex: min,
                    maxIndex: max,
                    step: o["stepIndexOfExposureCompensation"]?.int ?? 1)
            }
        case "storageInformation":
            if let n = o["numberOfRecordableImages"]?.int, n >= 0 { recordableImages = n }
        case "batteryInfo":
            if let num = o["levelNumer"]?.int, let den = o["levelDenom"]?.int, den > 0, num >= 0, num <= den {
                batteryPercent = Int((Double(num) / Double(den) * 100).rounded(.towardZero))
            }
        default: break
        }
    }
}
