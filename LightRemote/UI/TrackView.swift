import MapKit
import SwiftUI

struct TrackView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let track = model.track
        NavigationStack {
            List {
                Section { map.listRowInsets(EdgeInsets()) }

                Section {
                    TrackControls()
                } footer: {
                    Text("Keeps running with the screen locked. If iOS or you close LightRemote, it restarts the next time you move a few hundred metres (needs “Always” location).")
                }

                if let error = track.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry saving") { track.flush() }
                    }
                }
                clockSection

                Section {
                    ForEach(track.gpxFiles, id: \.self) { url in
                        HStack {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                            Spacer()
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                    if track.gpxFiles.isEmpty { Text("No GPX files yet").foregroundStyle(.secondary) }
                } header: { Text("GPX files") } footer: {
                    Text(track.usesICloud
                         ? "Saved in iCloud Drive › LightRemote › GPX. They sync to your Mac automatically."
                         : "Saved in Files › On My iPhone › LightRemote › GPX. Turn on iCloud Drive to sync them to your Mac automatically.")
                }
            }
            .navigationTitle("Track")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TrackChip() } }
        }
    }

    @ViewBuilder private var clockSection: some View {
        let track = model.track
        Section {
            if model.camera.clockSetAutomatically {
                Label("Camera clock set from iPhone on connect", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let err = track.cameraClockError {
                let ok = abs(err) <= 30
                Label(ok ? "Camera clock: \(signed(err)) ✓" : "Camera clock is off by \(describe(err))",
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                if let m = track.today.clockOffsets.last {
                    Text("Measured \(m.measuredAt.formatted(date: .omitted, time: .shortened)); geotag.py corrects for it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Not measured yet. Take one remote shot and LightRemote measures it automatically.")
                    .foregroundStyle(.secondary)
            }
            if track.recentUTCOffsetChange {
                Label("Daylight saving or time zone changed recently. Check the camera's clock and DST setting.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: { Text("Camera clock") } footer: {
            Text("Geotagging matches photo times to the track, so keep the A7II clock set to iPhone time (MENU › Setup › Date/Time Setup).")
        }
    }

    private func signed(_ s: Int) -> String { s == 0 ? "in sync" : (s > 0 ? "+\(s) s" : "\(s) s") }

    private func describe(_ s: Int) -> String {
        let a = abs(s)
        let text = a >= 3600 ? String(format: "%.1f h", Double(a) / 3600) : a >= 60 ? "\(a / 60) min" : "\(a) s"
        return text + (s > 0 ? " (fast)" : " (slow)")
    }

    private var map: some View {
        let points = model.track.today.points
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let shots = model.track.today.shots.compactMap { model.track.today.location(at: $0) }
        return Map(initialPosition: .userLocation(fallback: .automatic)) {
            if coords.count > 1 { MapPolyline(coordinates: coords).stroke(.orange, lineWidth: 4) }
            ForEach(Array(shots.enumerated()), id: \.offset) { _, p in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                    Circle().fill(.white).stroke(.orange, lineWidth: 2).frame(width: 10, height: 10)
                }
            }
            UserAnnotation()
        }
        .frame(height: 260)
    }
}
