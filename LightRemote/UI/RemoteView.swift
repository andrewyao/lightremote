import SwiftUI

struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var focus: FocusMark?
    private let settings = ModeSettings()

    struct FocusMark: Equatable {
        enum Status { case focusing, locked, failed }
        var point: CGPoint
        var status: Status
    }

    private var camera: CameraController { model.camera }
    private var isMovieMode: Bool { camera.state.shootMode?.current == "movie" }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) { statusBar; liveView; ExposureBar(); ModeOptions().padding(.bottom, 4) }
                        VStack(spacing: 14) {
                            ModeStrip(mode: settings.$mode, vertical: true).frame(maxHeight: .infinity)
                            shutterButton
                        }
                        .frame(width: 120)
                        .padding(.vertical, 8)
                    }
                } else {
                    VStack(spacing: 8) {
                        statusBar
                        liveView
                        ExposureBar()
                        ModeOptions()
                        ModeStrip(mode: settings.$mode)
                        shutterButton.padding(.bottom, 8)
                    }
                }
                if let p = model.runner.progress { JobHUD(progress: p).transition(.opacity) }
            }
        }
        .alert("Camera", isPresented: errorBinding) {
            Button("OK") { camera.lastError = nil; model.runner.lastError = nil }
        } message: {
            Text(camera.lastError ?? model.runner.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { camera.lastError != nil || model.runner.lastError != nil },
                set: { if !$0 { camera.lastError = nil; model.runner.lastError = nil } })
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 12) {
            TrackChip()
            Label(settings.mode.label, systemImage: settings.mode.icon)
            if let f = camera.state.focusMode?.current { Text(f) }
            Spacer()
            if let n = camera.state.recordableImages { Label("\(n)", systemImage: "sdcard") }
            if let b = camera.state.batteryPercent { Label("\(b)%", systemImage: battery(b)) }
            Button { camera.autoConnect = false; camera.disconnect() } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Disconnect")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func battery(_ p: Int) -> String {
        p > 75 ? "battery.100" : p > 50 ? "battery.75" : p > 25 ? "battery.50" : "battery.25"
    }

    // MARK: Live view + touch focus

    private var liveView: some View {
        GeometryReader { geo in
            let image = camera.liveFrame
            let rect = fittedRect(image?.size ?? CGSize(width: 3, height: 2), in: geo.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image).resizable().frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    ProgressView("Starting live view…").tint(.white).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let focus { focusBox(focus) }
                if let last = model.gallery.shots.first, let thumb = model.gallery.thumbnail(last) {
                    Image(uiImage: thumb).resizable().scaledToFill().frame(width: 64, height: 44).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6)))
                        .offset(x: rect.minX + 10, y: rect.maxY - 54)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { cancelFocus() }
            .onTapGesture { location in tapFocus(location, in: rect) }
        }
    }

    private func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func tapFocus(_ location: CGPoint, in rect: CGRect) {
        guard camera.can("setTouchAFPosition"), rect.contains(location) else { return }
        let x = (location.x - rect.minX) / rect.width * 100
        let y = (location.y - rect.minY) / rect.height * 100
        focus = FocusMark(point: location, status: .focusing)
        Task {
            let locked = await camera.touchFocus(xPercent: x, yPercent: y)
            if focus?.point == location { focus?.status = locked ? .locked : .failed }
        }
    }

    private func cancelFocus() {
        focus = nil
        if camera.can("cancelTouchAFPosition") { camera.perform { try await $0.cancelTouchAF() } }
    }

    private func focusBox(_ f: FocusMark) -> some View {
        let color: Color = switch f.status { case .focusing: .white; case .locked: .green; case .failed: .red }
        return RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 2)
            .frame(width: 64, height: 64)
            .offset(x: f.point.x - 32, y: f.point.y - 32)
            .animation(.easeOut(duration: 0.2), value: f.status)
            .allowsHitTesting(false)
    }

    // MARK: Shutter + modes

    private var shutterButton: some View {
        ShutterButton(isMovie: settings.mode == .movie, isRunning: model.runner.isRunning, disabled: !canShoot) {
            shutter()
        }
    }

    private var canShoot: Bool {
        if camera.isChangingMode { return false }
        if model.runner.isRunning { return true }   // the button stops the job
        switch settings.mode {
        case .movie: return isMovieMode && camera.can("startMovieRec")   // waits for the camera to switch
        case .bulb: return camera.can("startBulbShooting") && camera.state.shutterSpeed?.current == "BULB"
        default: return !isMovieMode && camera.can("actTakePicture")
        }
    }

    private func shutter() {
        if model.runner.isRunning { model.runner.stop(); return }
        model.start(settings.job)
    }
}

struct ShutterButton: View {
    var isMovie: Bool
    var isRunning: Bool
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                if isRunning {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 28, height: 28)
                } else {
                    Circle().fill(isMovie ? .red : .white).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .sensoryFeedback(.impact, trigger: isRunning)
        .accessibilityLabel(isRunning ? "Stop" : isMovie ? "Record" : "Shutter")
    }
}
