import Foundation
import Observation
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
    var sessionID: UUID?
    var savedToPhotos = false
}

/// Downloads postview JPEGs after each shot and keeps them as the session gallery.
@MainActor @Observable
final class PostviewStore {
    private(set) var shots: [Shot] = []
    var lastError: String?
    private let files: PreviewFiles
    private let downloader: any PreviewDownloading
    private let thumbnails = NSCache<NSUUID, UIImage>()
    private var sessionID: UUID?
    private var policy: CameraResourcePolicy
    private var downloads: [String: Task<Ingested?, Never>] = [:]
    private var activeDownloads = 0
    private var waitingDownloads: [CheckedContinuation<Void, Never>] = []
    private let shotLimit: Int
    static let concurrentDownloads = 4

    init(folder: URL? = nil, downloader: any PreviewDownloading = CameraPreviewDownloader(),
         baseURL: URL = CameraController.configuredBase, shotLimit: Int = 2000) {
        self.shotLimit = shotLimit
        files = PreviewFiles(folder: folder)
        self.downloader = downloader
        policy = CameraResourcePolicy(baseURL: baseURL)
        thumbnails.countLimit = 100
        do { shots = try files.load() }
        catch { lastError = "Couldn't load gallery: \(error.localizedDescription)" }
    }

    func beginSession(_ id: UUID, baseURL: URL) {
        downloads.values.forEach { $0.cancel() }
        sessionID = id
        policy = CameraResourcePolicy(baseURL: baseURL)
    }

    func fileURL(_ shot: Shot) -> URL { files.url(for: shot.fileName) }

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
        let tasks = urls.prefix(32).compactMap { url -> Task<Ingested?, Never>? in
            let key = "\(sessionID?.uuidString ?? "legacy"):\(url.absoluteString)"
            if let existing = downloads[key] { return existing }
            if let shot = shots.first(where: { $0.sourceURL == url.absoluteString && $0.sessionID == sessionID }) {
                return Task {
                    let data = try? Data(contentsOf: fileURL(shot))
                    return Ingested(shot: shot, cameraWallClock: data.flatMap(GeoTagger.cameraWallClock))
                }
            }
            guard policy.allows(url) else {
                lastError = "Preview rejected: not served by the camera."
                return nil
            }
            isNewShot = true
            let session = sessionID
            let policy = self.policy
            let task = Task {
                defer { downloads[key] = nil }
                return await download(url, takenAt: takenAt, settings: settings, location: location,
                                      session: session, policy: policy)
            }
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

    private func download(_ url: URL, takenAt: Date, settings: CameraEvent, location: TrackPoint?,
                          session: UUID?, policy: CameraResourcePolicy) async -> Ingested? {
        await acquireDownloadSlot()
        defer { releaseDownloadSlot() }
        do {
            try Task.checkCancellation()
            let data = try await downloader.download(url, policy: policy)
            try Task.checkCancellation()
            guard session == sessionID else { return nil }
            let name = UUID().uuidString + ".jpg"
            try makeRoom(for: data.count)
            try files.write(data, named: name)
            let shot = Shot(takenAt: takenAt, fileName: name, sourceURL: url.absoluteString,
                            fNumber: settings.fNumber?.current, shutterSpeed: settings.shutterSpeed?.current,
                            iso: settings.iso?.current, latitude: location?.latitude, longitude: location?.longitude, sessionID: session)
            shots.insert(shot, at: 0)
            saveIndex()
            return Ingested(shot: shot, cameraWallClock: GeoTagger.cameraWallClock(of: data))
        } catch is CancellationError {
            return nil
        } catch {
            lastError = "Couldn't download preview: \(error.localizedDescription)"
            return nil
        }
    }

    /// The camera serves one transfer at a time anyway; extra previews wait their turn instead of being dropped.
    private func acquireDownloadSlot() async {
        if activeDownloads < Self.concurrentDownloads { activeDownloads += 1; return }
        await withCheckedContinuation { waitingDownloads.append($0) }   // the releaser hands over its slot
    }

    private func releaseDownloadSlot() {
        if waitingDownloads.isEmpty { activeDownloads -= 1 } else { waitingDownloads.removeFirst().resume() }
    }

    /// Previews are a cache of what's on the card: drop the oldest to stay within the count and byte limits.
    private func makeRoom(for bytes: Int) throws {
        var total = try files.totalBytes()
        var evicted = false
        while let oldest = shots.last, shots.count >= shotLimit || total + bytes > PreviewFiles.byteLimit {
            total -= files.size(of: oldest.fileName)
            try files.delete(oldest.fileName)
            shots.removeLast()
            thumbnails.removeObject(forKey: oldest.id as NSUUID)
            evicted = true
        }
        if evicted { saveIndex() }
    }

    func thumbnail(_ shot: Shot) -> UIImage? {
        if let t = thumbnails.object(forKey: shot.id as NSUUID) { return t }
        guard let image = UIImage(contentsOfFile: fileURL(shot).path),
              let t = image.preparingThumbnail(of: CGSize(width: 240, height: 160)) else { return nil }
        thumbnails.setObject(t, forKey: shot.id as NSUUID)
        return t
    }

    func image(_ shot: Shot) -> UIImage? { UIImage(contentsOfFile: fileURL(shot).path) }

    /// Saves to the Photos library with GPS written into EXIF and set as the asset location.
    func saveToPhotos(_ shot: Shot, point: TrackPoint?) async throws {
        let point = point ?? shot.latitude.flatMap { latitude in
            shot.longitude.map { TrackPoint(time: shot.takenAt, latitude: latitude, longitude: $0,
                                             elevation: nil, accuracy: 10) }
        }
        try await PhotosExporter.save(Data(contentsOf: fileURL(shot)), takenAt: shot.takenAt, point: point)
        if let i = shots.firstIndex(where: { $0.id == shot.id }) {
            shots[i].savedToPhotos = true
            if let point { shots[i].latitude = point.latitude; shots[i].longitude = point.longitude }
        }
        saveIndex()
    }

    func delete(_ shot: Shot) {
        do { try files.delete(shot.fileName) }
        catch { lastError = "Couldn't delete preview: \(error.localizedDescription)"; return }
        shots.removeAll { $0.id == shot.id }
        thumbnails.removeObject(forKey: shot.id as NSUUID)
        saveIndex()
    }

    private func saveIndex() {
        do { try files.save(shots) }
        catch { lastError = "Couldn't save gallery: \(error.localizedDescription)" }
    }
}
