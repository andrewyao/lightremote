# LightRemote architecture

```mermaid
flowchart TB
    subgraph Camera["Sony A7II (Wi-Fi, Camera Remote API)"]
        CAM_RPC["JSON-RPC /sony/camera, /sony/system"]
        CAM_LV["Liveview stream URL"]
        CAM_PV["Postview JPEG URLs"]
    end
    MOCK["MockCamera/mock_camera.py<br/>(localhost:8080 stand-in)"] -.dev.-> CAM_RPC

    subgraph App["App/"]
        LRA["LightRemoteApp<br/>RootView · RemoteTab"]
        AM["AppModel<br/>(wires everything via callbacks)"]
        LAC["LiveActivityController"]
    end

    subgraph UI["UI/ (SwiftUI views)"]
        CV["ConnectView<br/>TrackCard/Controls"]
        RV["RemoteView<br/>ShutterButton"]
        EB["ExposureBar"]
        MC["ModeStrip / ModeOptions"]
        JH["JobHUD"]
        GV["GalleryView / ShotDetail"]
        TV["TrackView"]
    end

    subgraph CameraMod["Camera/"]
        CC["CameraController<br/>connect · getEvent loop · liveview · setters"]
        API["CameraAPI<br/>(typed methods, conforms to Shooter)"]
        SC["SonyClient (actor)<br/>JSON-RPC"]
        CT["CameraTransport<br/>CameraResourcePolicy · CameraTransfer<br/>CameraPreviewDownloader"]
        LVS["LiveViewStream + LiveViewParser"]
        CE["CameraEvent / Setting / EVSetting"]
        JS["JSON"]
    end

    subgraph Shooting["Shooting/"]
        JR["JobRunner<br/>ShootingJob · Ticker"]
        SM["ShootMode / ModeChange"]
    end

    subgraph Gallery["Gallery/"]
        PS["PostviewStore<br/>Shot · ingest · download queue"]
        PF["PreviewFiles<br/>(on-disk JPEGs + index)"]
        PE["PhotosExporter"]
    end

    subgraph Location["Location/"]
        TR["TrackRecorder<br/>+ LocationEngine (CoreLocation)"]
        TP["TrackPersistence<br/>(local + iCloud)"]
        DL["DayLog / TrackPoint<br/>clock & UTC offsets · GPX"]
        GT["GeoTagger<br/>(EXIF GPS, camera wall clock)"]
    end

    subgraph Widget["LightRemoteWidget/"]
        TLA["TrackLiveActivity"]
        TAA["TrackActivityAttributes (Shared/)"]
    end

    MAC["MacHelper/geotag.py<br/>(exiftool + GPX)"]
    PHOTOS[("Photos library")]
    ICLOUD[("iCloud Drive › LightRemote › GPX")]

    %% App wiring
    LRA --> AM
    LRA --> CV & RV & GV & TV
    AM --> CC & JR & PS & TR
    AM --> LAC
    LAC -- observes --> TR
    LAC --> TAA --> TLA

    %% UI reads observable state via AppModel
    RV --> EB & MC & JH
    MC --> SM
    CV -.-> CC & TR
    RV -.-> CC & JR
    GV -.-> PS
    TV -.-> TR

    %% Camera stack
    CC --> API --> SC --> CT
    CC --> LVS --> CT
    CC --> CE
    SC --> JS
    CE --> JS
    SC <--> CAM_RPC
    LVS <--> CAM_LV
    CT <--> CAM_PV

    %% Shooting
    JR -- "takePicture (Shooter)" --> API
    JR -- onShot(ShotResult) --> AM
    CC -- "onEventPostviews / onConnected /<br/>onDisconnected / onClockSynchronized" --> AM

    %% Gallery
    AM -- "ingest(urls, settings, location)" --> PS
    PS --> CT
    PS --> PF
    PS --> GT
    PS --> PE --> GT
    PE --> PHOTOS

    %% Location
    AM -- "location(at:) · noteShot · noteClockOffset" --> TR
    TR --> TP --> DL
    TP --> ICLOUD
    ICLOUD --> MAC
```

## Notes

- **`AppModel` is the only hub.** `CameraController`, `JobRunner`, `PostviewStore` and `TrackRecorder` never reference each other. `AppModel` connects them through closure callbacks such as `onShot`, `onEventPostviews` and `onConnected`.
- **Every camera call goes through `CameraTransport`.** JSON-RPC, liveview and postview downloads all pass through `CameraResourcePolicy` and `CameraTransfer`, so they share the same host checks and size limits.
- **A shot follows one path:** `JobRunner` → `ShotResult` → `AppModel`. `AppModel` looks up the GPS point from `TrackRecorder`, then `PostviewStore` downloads and stores the preview. When the shot's timing is reliable, the camera clock read from the JPEG's EXIF goes back to `TrackRecorder` as a clock offset.
- **Geotagging the full-size files happens off the phone.** The GPX tracks sync through iCloud, and `MacHelper/geotag.py` uses them to tag the RAW and JPEG files from the SD card.
