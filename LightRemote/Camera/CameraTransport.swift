import Foundation

/// Sony serves previews and live view on ports separate from JSON-RPC, but always on the camera host.
struct CameraResourcePolicy: Sendable {
    let baseURL: URL

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), host == baseURL.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return baseURL.scheme?.lowercased() != "https" || scheme == "https"
    }

    func validate(_ url: URL) throws {
        guard allows(url) else { throw URLError(.unsupportedURL) }
    }
}

protocol PreviewDownloading: Sendable {
    func download(_ url: URL, policy: CameraResourcePolicy) async throws -> Data
}

struct CameraPreviewDownloader: PreviewDownloading {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func download(_ url: URL, policy: CameraResourcePolicy) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await CameraTransfer.fetch(request, policy: policy, limit: 20 * 1024 * 1024,
                                                 configuration: session.configuration)
        guard data.starts(with: [0xFF, 0xD8, 0xFF]) else { throw URLError(.cannotDecodeContentData) }
        return data
    }
}

/// A transfer owns a serial delegate queue. It rejects redirects and oversized bodies before buffering them.
final class CameraTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: CameraResourcePolicy
    private let limit: Int
    private var data = Data()
    private var failure: Error?
    private var continuation: CheckedContinuation<Data, any Error>?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(policy: CameraResourcePolicy, limit: Int) {
        self.policy = policy
        self.limit = limit
    }

    static func fetch(_ request: URLRequest, policy: CameraResourcePolicy, limit: Int,
                      configuration: URLSessionConfiguration) async throws -> Data {
        guard let url = request.url else { throw URLError(.badURL) }
        try policy.validate(url)
        let transfer = CameraTransfer(policy: policy, limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = configuration.copy() as! URLSessionConfiguration
                config.httpShouldSetCookies = false
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.timeoutIntervalForResource = min(config.timeoutIntervalForResource, request.timeoutInterval)
                let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
                let task = session.dataTask(with: request)
                transfer.continuation = continuation
                let cancelled = transfer.lock.withLock {
                    transfer.task = task
                    return transfer.cancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            transfer.lock.withLock {
                transfer.cancelled = true
                transfer.task?.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, policy.allows(url) else {
            failure = URLError(.unsupportedURL)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let url = response.url, policy.allows(url) else {
            failure = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = URLError(.dataLengthExceedsMaximum)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= limit - data.count else {
            failure = URLError(.dataLengthExceedsMaximum)
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        let continuation = self.continuation
        self.continuation = nil
        if let failure { continuation?.resume(throwing: failure) }
        else if lock.withLock({ cancelled }) { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: data) }
    }
}
