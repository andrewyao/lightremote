import Foundation

/// What the shutter button does. One tap on a chip selects it; no sheet.
enum ShootMode: String, CaseIterable, Identifiable {
    case single, timer2, timer10, interval, bulb, movie
    var id: String { rawValue }

    var kind: ShootingKind {
        switch self {
        case .single: .single
        case .timer2, .timer10: .selfTimer
        case .interval: .interval
        case .bulb: .bulb
        case .movie: .movie
        }
    }

    var label: String {
        switch self {
        case .timer2: "2s"
        case .timer10: "10s"
        default: kind.title
        }
    }

    var icon: String {
        switch self {
        case .single: "camera"
        case .timer2, .timer10: "timer"
        case .interval: "repeat"
        case .bulb: "moon.stars"
        case .movie: "video"
        }
    }
}

/// What the camera has to change for a mode to work.
struct ModeChange: Equatable {
    var shootMode: String?
    var shutterSpeed: String?
    /// The shutter speed to go back to on leaving Bulb, remembered across launches.
    var shutterBeforeBulb: String?
}

extension ShootMode {
    func change(from state: CameraEvent, shutterBeforeBulb saved: String?) -> ModeChange {
        var change = ModeChange(shutterBeforeBulb: saved)
        if (self == .movie) != (state.shootMode?.current == "movie") {
            change.shootMode = self == .movie ? "movie" : "still"
        }
        guard let shutter = state.shutterSpeed else { return change }
        if self == .bulb {
            if shutter.current != "BULB", shutter.candidates.contains("BULB") {
                change.shutterSpeed = "BULB"
                change.shutterBeforeBulb = shutter.current
            }
        } else if shutter.current == "BULB", let saved, shutter.candidates.contains(saved) {
            change.shutterSpeed = saved
            change.shutterBeforeBulb = nil
        }
        return change
    }
}


/// Shared names for selected modes and running jobs.
enum ShootingKind {
    case single, selfTimer, interval, bulb, movie
    var title: String {
        switch self {
        case .single: "Single"
        case .selfTimer: "Self-timer"
        case .interval: "Interval"
        case .bulb: "Bulb"
        case .movie: "Movie"
        }
    }
}
