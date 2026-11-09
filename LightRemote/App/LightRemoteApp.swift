import SwiftUI

@main
struct LightRemoteApp: App {
    /// Unit tests run inside the app; don't start location, camera search or Live Activities for them.
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @State private var model: AppModel? = isTestHost ? nil : AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(.orange)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.track.flush() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            RemoteTab()
                .tabItem { Label("Remote", systemImage: "camera.aperture") }
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
            TrackView()
                .tabItem { Label("Track", systemImage: "location.north.line") }
        }
    }
}

/// Connect screen until the camera is connected, then the full remote.
struct RemoteTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.camera.connection == .connected {
            RemoteView()
        } else {
            ConnectView()
        }
    }
}
