import SwiftUI

/// What the shutter button does. One tap on a chip selects it; no sheet.
enum ShootMode: String, CaseIterable, Identifiable {
    case single, timer2, timer10, interval, bulb, movie
    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: "Single"
        case .timer2: "2s"
        case .timer10: "10s"
        case .interval: "Interval"
        case .bulb: "Bulb"
        case .movie: "Movie"
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

/// Last-used mode settings, remembered across launches.
struct ModeSettings: DynamicProperty {
    @AppStorage("mode") var mode: ShootMode = .single
    @AppStorage("intervalSeconds") var intervalSeconds = 5
    @AppStorage("intervalShots") var shots = 100          // 0 = until stopped
    @AppStorage("bulbSeconds") var bulbSeconds = 30

    var job: ShootingJob {
        switch mode {
        case .single: .single
        case .timer2: .selfTimer(seconds: 2)
        case .timer10: .selfTimer(seconds: 10)
        case .interval: .interval(every: .seconds(intervalSeconds), count: shots == 0 ? nil : shots)
        case .bulb: .bulb(duration: .seconds(bulbSeconds))
        case .movie: .movie
        }
    }

    static let intervalPresets = [1, 2, 3, 5, 10, 15, 20, 30, 60, 120, 300, 600]
    static let shotPresets = [10, 30, 60, 100, 200, 300, 500, 1000, 0]
    static let bulbPresets = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300, 480, 600, 900, 1200, 1800]
}

/// Horizontal (portrait) or vertical (landscape) row of mode chips.
struct ModeStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: ShootMode
    var vertical = false

    private var camera: CameraController { model.camera }

    private var available: [ShootMode] {
        ShootMode.allCases.filter { m in
            switch m {
            case .single, .interval: camera.can("actTakePicture")
            case .timer2: camera.can("setSelfTimer") && (camera.state.selfTimer?.candidates.contains(2) ?? true)
            case .timer10: camera.can("setSelfTimer") && (camera.state.selfTimer?.candidates.contains(10) ?? true)
            case .bulb: camera.can("startBulbShooting")
            case .movie: camera.can("startMovieRec") && camera.can("setShootMode")
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    ForEach(available) { m in
                        Button { select(m) } label: {
                            Label(m.label, systemImage: m.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(m == mode ? Color.orange : Color.white.opacity(0.1)))
                                .foregroundStyle(m == mode ? .black : .white)
                        }
                        .id(m)
                    }
                }
                .padding(.horizontal, vertical ? 0 : 12)
            }
            .onAppear { proxy.scrollTo(mode, anchor: .center) }
        }
        .disabled(model.runner.isRunning)
        .sensoryFeedback(.selection, trigger: mode)
    }

    /// Selecting a mode also puts the camera in the state that mode needs, so there's no second step.
    private func select(_ m: ShootMode) {
        mode = m
        let wantsMovie = m == .movie
        let isMovie = camera.state.shootMode?.current == "movie"
        if wantsMovie != isMovie {
            camera.perform { try await $0.setShootMode(wantsMovie ? "movie" : "still") }
        }
        if m == .bulb, camera.state.shutterSpeed?.current != "BULB",
           camera.state.shutterSpeed?.candidates.contains("BULB") == true {
            camera.perform { try await $0.setShutterSpeed("BULB") }
        }
    }
}

/// Inline settings for interval and bulb: each value is a menu of presets (two taps, no steppers).
struct ModeOptions: View {
    let settings = ModeSettings()

    var body: some View {
        HStack(spacing: 8) {
            switch settings.mode {
            case .interval:
                pill("every \(format(settings.intervalSeconds))", ModeSettings.intervalPresets,
                     settings.$intervalSeconds) { format($0) }
                pill(settings.shots == 0 ? "until stopped" : "× \(settings.shots)", ModeSettings.shotPresets,
                     settings.$shots) { $0 == 0 ? "Until stopped" : "\($0) shots" }
                if settings.shots > 0 {
                    Text("≈ \(format(settings.intervalSeconds * (settings.shots - 1)))")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            case .bulb:
                pill("open \(format(settings.bulbSeconds))", ModeSettings.bulbPresets, settings.$bulbSeconds) { format($0) }
            default:
                EmptyView()
            }
        }
        .frame(height: settings.mode == .interval || settings.mode == .bulb ? 34 : 0)
        .clipped()
    }

    private func pill(_ title: String, _ presets: [Int], _ value: Binding<Int>,
                      label: @escaping (Int) -> String) -> some View {
        Menu {
            Picker(title, selection: value) {
                ForEach(presets, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().stroke(.orange, lineWidth: 1.5))
            .foregroundStyle(.orange)
        }
    }
}

func format(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
    return String(format: "%d h %02d min", seconds / 3600, seconds % 3600 / 60)
}
