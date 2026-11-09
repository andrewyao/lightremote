import SwiftUI

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var savingAll = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        let gallery = model.gallery
        NavigationStack {
            Group {
                if gallery.shots.isEmpty {
                    ContentUnavailableView("No shots yet", systemImage: "photo.on.rectangle",
                                           description: Text("Previews of photos you take with the remote appear here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(gallery.shots) { shot in
                                NavigationLink(value: shot.id) { Thumb(shot: shot) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationDestination(for: UUID.self) { id in
                if let shot = gallery.shots.first(where: { $0.id == id }) { ShotDetail(shot: shot) }
            }
            .toolbar {
                if gallery.shots.contains(where: { !$0.savedToPhotos }) {
                    Button {
                        Task { await saveAll() }
                    } label: {
                        if savingAll { ProgressView() } else { Label("Save all to Photos", systemImage: "square.and.arrow.down.on.square") }
                    }
                    .disabled(savingAll)
                }
            }
            .alert("Gallery", isPresented: Binding(get: { gallery.lastError != nil }, set: { if !$0 { gallery.lastError = nil } })) {
                Button("OK") {}
            } message: { Text(gallery.lastError ?? "") }
        }
    }

    private func saveAll() async {
        savingAll = true
        defer { savingAll = false }
        for shot in model.gallery.shots where !shot.savedToPhotos {
            do { try await model.gallery.saveToPhotos(shot, point: model.track.location(at: shot.takenAt)) } catch {
                model.gallery.lastError = error.localizedDescription
                return
            }
        }
    }
}

private struct Thumb: View {
    @Environment(AppModel.self) private var model
    var shot: Shot

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                if let t = model.gallery.thumbnail(shot) { Image(uiImage: t).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if shot.latitude != nil { Image(systemName: "mappin.circle.fill") }
                    if shot.savedToPhotos { Image(systemName: "checkmark.circle.fill") }
                }
                .font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(4)
            }
    }
}

struct ShotDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var shot: Shot
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = model.gallery.image(shot) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Grid(alignment: .leading, verticalSpacing: 8) {
                    row("Taken", shot.takenAt.formatted(date: .abbreviated, time: .standard))
                    row("Exposure", [shot.fNumber.map { "f/\($0)" }, shot.shutterSpeed, shot.iso.map { "ISO \($0)" }]
                        .compactMap { $0 }.joined(separator: "  "))
                    row("Location", locationText)
                }
                .font(.subheadline)
                Text("This is the camera's preview JPEG. The full-size JPEG/RAW stays on the SD card. Geotag it at home with the GPX track.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle(shot.takenAt.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(item: model.gallery.fileURL(shot))
                Spacer()
                Button {
                    Task {
                        saving = true
                        do { try await model.gallery.saveToPhotos(shot, point: model.track.location(at: shot.takenAt)) }
                        catch { model.gallery.lastError = error.localizedDescription }
                        saving = false
                    }
                } label: {
                    Label(shot.savedToPhotos ? "Saved" : "Save to Photos",
                          systemImage: shot.savedToPhotos ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(saving || shot.savedToPhotos)
                Spacer()
                Button(role: .destructive) { model.gallery.delete(shot); dismiss() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var locationText: String {
        let lat = shot.latitude ?? model.track.location(at: shot.takenAt)?.latitude
        let lon = shot.longitude ?? model.track.location(at: shot.takenAt)?.longitude
        guard let lat, let lon else { return "No GPS fix at that time" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v.isEmpty ? "—" : v)
        }
    }
}
