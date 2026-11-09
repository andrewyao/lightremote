import Foundation
import Observation
import Photos
import UIKit

struct Shot: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var takenAt: Date
    var fileName: String
    var sourceURL: String
    var fNumber: String?
    var shutterSpeed: String?
    var iso: String?
    var latitude: Double?
    var longitude: Double?
    var savedToPhotos = false
}

/// Downloads postview JPEGs after each shot and keeps them as the session gallery.
@MainActor @Observable
final class PostviewStore {
    private(set) var shots: [Shot] = []
    var lastError: String?
    private let folder: URL
    private var thumbnails: [UUID: UIImage] = [:]
    private var downloads: [String: Task<Ingested?, Never>] = [:]

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Shot].self, from: data) {
            shots = saved
        }
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    func fileURL(_ shot: Shot) -> URL { folder.appendingPathComponent(shot.fileName) }

    struct Ingested: Sendable { var shot: Shot; var cameraWallClock: Date? }

    struct Ingestion {
        /// False when every URL was already reported, so this isn't another shot.
        var isNewShot: Bool
        var results: Task<[Ingested], Never>
    }

    /// actTakePicture and getEvent report the same postview almost simultaneously, in either order. Claims each URL
    /// before returning, so the first report starts the download and later ones share its result.
    func ingest(_ urls: [URL], takenAt: Date, settings: CameraEvent, location: TrackPoint?) -> Ingestion {
        var isNewShot = urls.isEmpty
        let tasks = urls.compactMap { url -> Task<Ingested?, Never>? in
            let key = url.absoluteString
            if let existing = downloads[key] { return existing }
            if shots.contains(where: { $0.sourceURL == key }) { return nil }
            isNewShot = true
            let task = Task { await download(url, takenAt: takenAt, settings: settings, location: location) }
            downloads[key] = task
            return task
        }
        return Ingestion(isNewShot: isNewShot, results: Task {
            var results: [Ingested] = []
            for task in tasks {
                if let ingested = await task.value { results.append(ingested) }
            }
            return results
        })
    }

    private func download(_ url: URL, takenAt: Date, settings: CameraEvent, location: TrackPoint?) async -> Ingested? {
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let name = "\(Int(takenAt.timeIntervalSince1970 * 1000))-\(url.lastPathComponent)"
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            let shot = Shot(takenAt: takenAt, fileName: name, sourceURL: url.absoluteString,
                            fNumber: settings.fNumber?.current, shutterSpeed: settings.shutterSpeed?.current,
                            iso: settings.iso?.current, latitude: location?.latitude, longitude: location?.longitude)
            shots.insert(shot, at: 0)
            saveIndex()
            return Ingested(shot: shot, cameraWallClock: GeoTagger.cameraWallClock(of: data))
        } catch {
            downloads[url.absoluteString] = nil
            lastError = "Couldn't download preview: \(error.localizedDescription)"
            return nil
        }
    }

    func thumbnail(_ shot: Shot) -> UIImage? {
        if let t = thumbnails[shot.id] { return t }
        guard let image = UIImage(contentsOfFile: fileURL(shot).path),
              let t = image.preparingThumbnail(of: CGSize(width: 240, height: 160)) else { return nil }
        thumbnails[shot.id] = t
        return t
    }

    func image(_ shot: Shot) -> UIImage? { UIImage(contentsOfFile: fileURL(shot).path) }

    /// Saves to the Photos library with GPS written into EXIF and set as the asset location.
    func saveToPhotos(_ shot: Shot, point: TrackPoint?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "LightRemote", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Allow LightRemote to add photos in Settings."])
        }
        var data = try Data(contentsOf: fileURL(shot))
        let point = point ?? shot.latitude.map {
            TrackPoint(time: shot.takenAt, latitude: $0, longitude: shot.longitude ?? 0, elevation: nil, accuracy: 10)
        }
        if let point, let tagged = GeoTagger.addingGPS(to: data, point: point) { data = tagged }
        let location = point.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let takenAt = shot.takenAt
        let jpeg = data
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpeg, options: nil)
            request.creationDate = takenAt
            request.location = location
        }
        if let i = shots.firstIndex(where: { $0.id == shot.id }) {
            shots[i].savedToPhotos = true
            if let point { shots[i].latitude = point.latitude; shots[i].longitude = point.longitude }
        }
        saveIndex()
    }

    func delete(_ shot: Shot) {
        try? FileManager.default.removeItem(at: fileURL(shot))
        shots.removeAll { $0.id == shot.id }
        thumbnails[shot.id] = nil
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(shots) { try? data.write(to: indexURL, options: .atomic) }
    }
}
