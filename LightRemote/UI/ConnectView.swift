import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cameraHost") private var cameraHost = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    cameraCard
                    instructions
                    TrackCard()
                    advanced
                }
                .padding(16)
            }
            .navigationTitle("LightRemote")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TrackChip() } }
            .task {
                // Keep trying while this screen is up: joining the camera's Wi-Fi is the only step.
                while !Task.isCancelled {
                    let c = model.camera
                    if c.autoConnect, c.connection != .connected, c.connection != .connecting { await c.connect() }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ILCE-7M2", systemImage: "camera")
                .font(.headline)
            if model.camera.autoConnect {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for the camera… Join its Wi-Fi and it connects by itself.")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Disconnected").font(.subheadline).foregroundStyle(.secondary)
                Button {
                    model.camera.autoConnect = true
                } label: {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .card()
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to connect").font(.headline)
            step(1, "On the camera: MENU › Application › Application List › **Smart Remote Control**.")
            step(2, "On the iPhone: Settings › Wi-Fi › join **DIRECT-xxxx:ILCE-7M2** with the password the camera shows.")
            step(3, "Come back here. LightRemote connects automatically and starts the GPS track.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(.orange.opacity(0.25)))
            Text(text).font(.subheadline)
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("192.168.122.1:8080", text: $cameraHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Text("Camera address. Leave empty for the A7II's default. Use localhost:8080 for the mock camera.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .card()
    }
}

/// Location tracking on the home screen.
struct TrackCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Location for geotagging", systemImage: "location.north.line").font(.headline)
            TrackControls()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Shared by the home screen and the Track tab: battery saver all day, precise GPS when it matters.
struct TrackControls: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoTrack") private var preciseWithCamera = true

    var body: some View {
        let track = model.track
        VStack(alignment: .leading, spacing: 10) {
            status(track)
            Toggle(isOn: Binding(get: { track.allDay }, set: { track.allDay = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Track all day")
                    Text("Battery saver: Wi-Fi/cell location (~100 m), a point every ~100 m you move.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $preciseWithCamera) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Precise GPS while the camera is connected")
                    Text("Full GPS (~5 m). Goes back to battery saver when the camera disconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(track.isRecording ? "Stop precise GPS" : "Precise GPS now") {
                track.isRecording ? track.stop() : track.start()
            }
            .buttonStyle(.bordered)
            .tint(track.isRecording ? .red : .orange)
            if track.allDay, track.authorization != .authorizedAlways {
                Button("Allow location “Always” so all-day tracking keeps running") { track.requestAlways() }
                    .font(.footnote)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private func status(_ track: TrackRecorder) -> some View {
        HStack(spacing: 6) {
            switch track.mode {
            case .precise: RecDot(label: "Precise GPS")
            case .lowPower:
                Image(systemName: "leaf.fill").foregroundStyle(.green)
                Text("Battery saver").foregroundStyle(.green).bold()
            case .off: Text("Not tracking").foregroundStyle(.secondary)
            }
            Spacer()
            if let last = track.today.points.last {
                Text("last point \(last.time, style: .relative) ago").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        Text("Today: \(track.today.points.count) points · \(track.today.shots.count) remote shots")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct TrackChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.track.isRecording, let start = model.track.recordingStartedAt {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(start, style: .timer).monospacedDigit()
            }
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.5)))
            .accessibilityLabel("GPS track recording")
        }
    }
}

struct RecDot: View {
    var label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(label).font(.caption.bold()).foregroundStyle(.red)
        }
    }
}

extension View {
    func card() -> some View {
        padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}
