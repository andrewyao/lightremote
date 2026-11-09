import SwiftUI

/// Progress overlay while a job runs.
struct JobHUD: View {
    @Environment(AppModel.self) private var model
    var progress: JobProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let now = ContinuousClock.now
            VStack(spacing: 8) {
                Text(title).font(.headline)
                detail(now)
                Button("Stop", role: .destructive) { model.runner.stop() }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(18)
            .frame(minWidth: 220)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 44)
        }
    }

    private var title: String {
        switch progress.job {
        case .interval(_, let count):
            "INTERVAL  \(progress.shotsTaken) / \(count.map(String.init) ?? "∞")"
        case .movie: "● REC"
        default: progress.job.title.uppercased()
        }
    }

    @ViewBuilder private func detail(_ now: ContinuousClock.Instant) -> some View {
        switch progress.job {
        case .interval(_, let count):
            if let next = progress.nextEventAt, next > now { Text("next in \(clock(next - now))").monospacedDigit() }
            if let count, count > 0 {
                ProgressView(value: Double(progress.shotsTaken), total: Double(count))
            }
            if let end = progress.endsAt, end > now {
                Text("ends ≈ \(Date().addingTimeInterval(seconds(end - now)).formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .bulb(let duration):
            Text("\(clock(now - progress.startedAt)) / \(clock(duration))")
                .font(.system(.largeTitle, design: .rounded).monospacedDigit())
        case .selfTimer:
            if let next = progress.nextEventAt, next > now {
                Text(clock(next - now)).font(.system(.largeTitle, design: .rounded).monospacedDigit())
            }
        case .movie:
            Text(clock(now - progress.startedAt)).font(.system(.largeTitle, design: .rounded).monospacedDigit())
                .foregroundStyle(.red)
        case .single:
            ProgressView()
        }
    }

    private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    private func clock(_ d: Duration) -> String {
        let s = max(0, Int(seconds(d).rounded(.up)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
