import SwiftUI

/// Bottom bar: f-number, shutter speed, ISO, EV, focus mode. Each shows only when the camera reports it
/// and lists only the values the camera offers.
/// - Swipe left/right on a value to step through it (no taps).
/// - Tap a value to open the full strip of choices.
struct ExposureBar: View {
    @Environment(AppModel.self) private var model
    @State private var open: Control?
    @State private var drag: (control: Control, index: Int)?

    enum Control: String, Identifiable { case f, tv, iso, ev, focus; var id: String { rawValue } }

    /// One adjustable setting: its choices (as labels), the current choice, and how to apply a choice.
    struct Item {
        var control: Control
        var labels: [String]
        var current: Int
        var apply: @MainActor (Int) -> Void
    }

    private var camera: CameraController { model.camera }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            if let open, let item = items.first(where: { $0.control == open }) {
                ValueStrip(item: item).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                ForEach(items, id: \.control) { item in cell(item) }
            }
            .padding(.horizontal, 8)
        }
        .background(.black)
        .disabled(model.runner.isRunning)
        .sensoryFeedback(.selection, trigger: drag?.index)
    }

    private func cell(_ item: Item) -> some View {
        let dragging = drag?.control == item.control
        let index = dragging ? drag!.index : item.current
        return Text(item.labels.indices.contains(index) ? item.labels[index] : "—")
            .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            .foregroundStyle(open == item.control || dragging ? .orange : .white)
            .scaleEffect(dragging ? 1.15 : 1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { open = open == item.control ? nil : item.control } }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { g in
                        let steps = Int((g.translation.width / 22).rounded(.towardZero))
                        drag = (item.control, min(max(item.current + steps, 0), item.labels.count - 1))
                    }
                    .onEnded { _ in
                        if let d = drag, d.index != item.current { item.apply(d.index) }
                        drag = nil
                    }
            )
            .accessibilityAdjustableAction { direction in
                let next = item.current + (direction == .increment ? 1 : -1)
                if item.labels.indices.contains(next) { item.apply(next) }
            }
    }

    private var items: [Item] {
        let s = camera.state
        let cam = camera
        var out: [Item] = []
        func add(_ c: Control, _ setting: Setting<String>?, _ method: String, prefix: String = "",
                 _ set: @escaping @Sendable (CameraAPI, String) async throws -> Void) {
            guard let setting, cam.can(method), let i = setting.candidates.firstIndex(of: setting.current) else { return }
            let values = setting.candidates
            out.append(Item(control: c, labels: values.map { prefix + $0 }, current: i) { k in
                let v = values[k]
                cam.perform { try await set($0, v) }
            })
        }
        add(.f, s.fNumber, "setFNumber", prefix: "f/") { try await $0.setFNumber($1) }
        add(.tv, s.shutterSpeed, "setShutterSpeed") { try await $0.setShutterSpeed($1) }
        add(.iso, s.iso, "setIsoSpeedRate", prefix: "ISO ") { try await $0.setISO($1) }
        if let ev = s.exposureCompensation, cam.can("setExposureCompensation"), !ev.indices.isEmpty {
            let indices = ev.indices
            out.append(Item(control: .ev, labels: indices.map { EVSetting.label(ev.ev($0)) },
                            current: indices.firstIndex(of: ev.currentIndex) ?? 0) { k in
                let v = indices[k]
                cam.perform { try await $0.setExposureCompensation(v) }
            })
        }
        add(.focus, s.focusMode, "setFocusMode") { try await $0.setFocusMode($1) }
        return out
    }
}

/// Horizontally scrolling choices with the current one centred and highlighted.
struct ValueStrip: View {
    var item: ExposureBar.Item

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(item.labels.indices, id: \.self) { i in
                        let selected = i == item.current
                        Button { item.apply(i) } label: {
                            Text(item.labels[i])
                                .font(.system(.callout, design: .rounded).weight(selected ? .bold : .regular))
                                .monospacedDigit()
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(selected ? Color.orange : Color.white.opacity(0.08)))
                                .foregroundStyle(selected ? .black : .white)
                        }
                        .id(i)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(item.current, anchor: .center) }
            .onChange(of: item.current) { _, c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
        }
        .background(Color.white.opacity(0.04))
    }
}
