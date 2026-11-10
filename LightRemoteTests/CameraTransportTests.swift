import XCTest
@testable import LightRemote

final class CameraTransportTests: XCTestCase {
    private let base = URL(string: "http://camera.test:8080/sony")!

    func testPolicyAcceptsCameraPortsAndRejectsUntrustedURLs() {
        let policy = CameraResourcePolicy(baseURL: base)
        XCTAssertTrue(policy.allows(URL(string: "http://camera.test:60152/liveview")!))
        for text in ["http://other.test/image.jpg", "file:///private/test.jpg", "ftp://camera.test/image.jpg",
                     "http://user:password@camera.test/image.jpg", "http://camera.test.evil/image.jpg"] {
            XCTAssertFalse(policy.allows(URL(string: text)!))
        }
        XCTAssertFalse(CameraResourcePolicy(baseURL: URL(string: "https://camera.test/sony")!)
            .allows(URL(string: "http://camera.test/image.jpg")!))
    }

    func testRejectsOversizedBodiesWithOrWithoutContentLengthAndHTTPFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceStub.self]
        for path in ["declared", "chunked", "status"] {
            let request = URLRequest(url: base.appendingPathComponent(path))
            do {
                _ = try await CameraTransfer.fetch(request, policy: CameraResourcePolicy(baseURL: base),
                                                   limit: 8, configuration: configuration)
                XCTFail("accepted \(path)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, path == "status" ? .badServerResponse : .dataLengthExceedsMaximum)
            }
        }
    }

    func testAllowsBodyAtLimitAndRejectsNonJPEGPreview() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceStub.self]
        let request = URLRequest(url: base.appendingPathComponent("ok"))
        let data = try await CameraTransfer.fetch(request, policy: CameraResourcePolicy(baseURL: base),
                                                  limit: 8, configuration: configuration)
        XCTAssertEqual(data, Data(repeating: 1, count: 8))
        do {
            _ = try await CameraPreviewDownloader(session: URLSession(configuration: configuration))
                .download(request.url!, policy: CameraResourcePolicy(baseURL: base))
            XCTFail("accepted non-JPEG response")
        } catch let error as URLError { XCTAssertEqual(error.code, .cannotDecodeContentData) }
    }

    func testCrossHostRedirectIsRejected() async throws {
        // Exercise the delegate directly: URLProtocol redirect support varies by test runtime.
        let policy = CameraResourcePolicy(baseURL: base)
        let stream = LiveViewStream()
        let frames = stream.frames(from: URL(string: "file:///invalid")!, policy: policy)
        var received = 0
        for await _ in frames { received += 1 }
        XCTAssertEqual(received, 0)
        let response = HTTPURLResponse(url: base, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: base)
        let transfer = CameraTransfer(policy: policy, limit: 8)
        transfer.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: URL(string: "http://other.test/image")!)) { request in
            XCTAssertNil(request)
        }
        let safe = URLRequest(url: URL(string: "http://camera.test:60152/image.jpg")!)
        transfer.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: safe) { request in
            XCTAssertEqual(request?.url, safe.url)
        }
    }
}

private final class ResourceStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let headers = path == "declared" ? ["Content-Length": "100"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "status" ? 503 : 200,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 8))
        if path == "chunked" { client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
