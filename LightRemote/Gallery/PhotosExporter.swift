import CoreLocation
import Foundation
import Photos

enum PhotosExporter {
    static func save(_ jpeg: Data, takenAt: Date, point: TrackPoint?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "LightRemote", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Allow LightRemote to add photos in Settings."])
        }
        let data = point.flatMap { GeoTagger.addingGPS(to: jpeg, point: $0) } ?? jpeg
        let location = point.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.creationDate = takenAt
            request.location = location
        }
    }
}
