import XCTest
@testable import LightRemote

@MainActor
final class PostviewStoreTests: XCTestCase {
    private var folder: URL!
    private var postview: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        postview = folder.appendingPathComponent("pict0001.JPG")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: postview)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testPostviewReportedTwiceAtOnceIsStoredOnce() async {
        let store = makeStore(folder: folder.appendingPathComponent("store"))
        let first = ingest(store, [postview])
        let second = ingest(store, [postview])
        let firstResults = await first.results.value
        let secondResults = await second.results.value

        XCTAssertEqual(store.shots.count, 1)
        XCTAssertTrue(first.isNewShot)
        XCTAssertFalse(second.isNewShot)
        XCTAssertEqual(firstResults.map(\.shot), store.shots)
        XCTAssertEqual(secondResults.map(\.shot), store.shots, "the later report still gets the result for its clock measurement")
    }

    func testPostviewAlreadyInGalleryIsNotANewShot() async {
        let storeFolder = folder.appendingPathComponent("store")
        _ = await ingest(makeStore(folder: storeFolder), [postview]).results.value

        let relaunched = makeStore(folder: storeFolder)
        let again = ingest(relaunched, [postview])
        let results = await again.results.value

        XCTAssertFalse(again.isNewShot)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(relaunched.shots.count, 1)
    }

    func testFailedDownloadCanBeRetried() async throws {
        let store = makeStore(folder: folder.appendingPathComponent("store"))
        let late = folder.appendingPathComponent("pict0002.JPG")
        let failed = await ingest(store, [late]).results.value
        XCTAssertTrue(failed.isEmpty)
        XCTAssertNotNil(store.lastError)

        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: late)
        let retried = ingest(store, [late])
        _ = await retried.results.value

        XCTAssertTrue(retried.isNewShot)
        XCTAssertEqual(store.shots.count, 1)
    }

    func testShotWithoutPostviewStillCounts() async {
        let store = makeStore(folder: folder.appendingPathComponent("store"))
        XCTAssertTrue(ingest(store, []).isNewShot)
    }

    private func makeStore(folder: URL) -> PostviewStore {
        PostviewStore(folder: folder, downloader: FilePreviewDownloader(root: self.folder),
                      baseURL: URL(string: "http://camera.test:8080/sony")!)
    }

    func testDeletingPreviewAllowsTheURLToBeDownloadedAgain() async throws {
        let store = makeStore(folder: folder.appendingPathComponent("store"))
        _ = await ingest(store, [postview]).results.value
        let original = try XCTUnwrap(store.shots.first)
        store.delete(original)
        let again = ingest(store, [postview])
        _ = await again.results.value
        XCTAssertTrue(again.isNewShot)
        XCTAssertEqual(store.shots.count, 1)
        XCTAssertNotEqual(store.shots.first?.id, original.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(store.shots[0]).path))
    }

    func testReusedURLInNewSessionCreatesNewShot() async {
        let store = makeStore(folder: folder.appendingPathComponent("store"))
        let base = URL(string: "http://camera.test:8080/sony")!
        store.beginSession(UUID(), baseURL: base)
        _ = await ingest(store, [postview]).results.value
        store.beginSession(UUID(), baseURL: base)
        _ = await ingest(store, [postview]).results.value
        XCTAssertEqual(store.shots.count, 2)
        XCTAssertNotEqual(store.shots[0].fileName, store.shots[1].fileName)
    }

    func testFullGalleryEvictsOldestInsteadOfRejecting() async throws {
        let store = PostviewStore(folder: folder.appendingPathComponent("full"),
                                  downloader: FilePreviewDownloader(root: folder),
                                  baseURL: URL(string: "http://camera.test:8080/sony")!, shotLimit: 2)
        let names = ["pict0001.JPG", "pict0003.JPG", "pict0004.JPG"]
        for name in names.dropFirst() {   // pict0001.JPG is `postview`
            try FileManager.default.copyItem(at: postview, to: folder.appendingPathComponent(name))
        }
        var stored: [Shot] = []
        for name in names {
            let result = await ingest(store, [URL(fileURLWithPath: name)]).results.value
            stored.append(try XCTUnwrap(result.first?.shot))
        }
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.shots.map(\.sourceURL), [stored[2], stored[1]].map(\.sourceURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(stored[0]).path))
    }

    func testRejectsOtherHostsAndQueuesExtraDownloads() async {
        let downloader = HoldingDownloader()
        let store = PostviewStore(folder: folder.appendingPathComponent("bounded"), downloader: downloader,
                                  baseURL: URL(string: "http://camera.test/sony")!)
        let bad = store.ingest([URL(string: "http://other.test/secret")!], takenAt: Date(),
                               settings: CameraEvent(), location: nil)
        XCTAssertFalse(bad.isNewShot)
        let urls = (0..<20).map { URL(string: "http://camera.test/p\($0).jpg")! }
        let pending = store.ingest(urls, takenAt: Date(), settings: CameraEvent(), location: nil)
        for _ in 0..<20 { await Task.yield() }
        let count = await downloader.count
        XCTAssertEqual(count, 4)
        XCTAssertTrue(pending.isNewShot)
        await downloader.release()
        _ = await pending.results.value
        XCTAssertEqual(store.shots.count, 20, "queued previews are downloaded, not dropped")
    }

    private func ingest(_ store: PostviewStore, _ urls: [URL]) -> PostviewStore.Ingestion {
        store.ingest(urls.map { URL(string: "http://camera.test:8080/" + $0.lastPathComponent)! }, takenAt: Date(), settings: CameraEvent(), location: nil)
    }
}

private struct FilePreviewDownloader: PreviewDownloading {
    let root: URL
    func download(_ url: URL, policy: CameraResourcePolicy) async throws -> Data {
        try policy.validate(url)
        return try Data(contentsOf: root.appendingPathComponent(url.lastPathComponent))
    }
}

private actor HoldingDownloader: PreviewDownloading {
    private(set) var count = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func download(_ url: URL, policy: CameraResourcePolicy) async throws -> Data {
        count += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
        return Data([0xFF, 0xD8, 0xFF, 0xD9])
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
