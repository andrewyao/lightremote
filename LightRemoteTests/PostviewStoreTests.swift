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
        let store = PostviewStore(folder: folder.appendingPathComponent("store"))
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
        _ = await ingest(PostviewStore(folder: storeFolder), [postview]).results.value

        let relaunched = PostviewStore(folder: storeFolder)
        let again = ingest(relaunched, [postview])
        let results = await again.results.value

        XCTAssertFalse(again.isNewShot)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(relaunched.shots.count, 1)
    }

    func testFailedDownloadCanBeRetried() async throws {
        let store = PostviewStore(folder: folder.appendingPathComponent("store"))
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
        let store = PostviewStore(folder: folder.appendingPathComponent("store"))
        XCTAssertTrue(ingest(store, []).isNewShot)
    }

    private func ingest(_ store: PostviewStore, _ urls: [URL]) -> PostviewStore.Ingestion {
        store.ingest(urls, takenAt: Date(), settings: CameraEvent(), location: nil)
    }
}
