import Foundation

struct SonyError: Error, Equatable, LocalizedError {
    let code: Int
    let message: String

    static let illegalState = 7          // e.g. shooting while busy
    static let notAvailableNow = 1
    static let longShooting = 40403      // awaitTakePicture needed
    static let alreadyPolling = 40402    // getEvent(true) already running
    static let noSuchMethod = 12

    var errorDescription: String? { "Camera error \(code): \(message)" }
}

/// JSON-RPC client for the Sony Camera Remote API.
/// Endpoints: `<base>/camera`, `<base>/system`, `<base>/avContent`.
actor SonyClient {
    let baseURL: URL
    private let session: URLSession
    private var nextID = 1

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Default endpoint of the A7II on its own Wi-Fi network.
    static let cameraBase = URL(string: "http://192.168.122.1:8080/sony")!

    func call(_ method: String, _ params: [JSON] = [], service: String = "camera",
              version: String = "1.0", timeout: TimeInterval = 10) async throws -> [JSON] {
        let id = nextID
        nextID += 1
        var request = URLRequest(url: baseURL.appendingPathComponent(service), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSON = ["method": .string(method), "params": .array(params), "id": .number(Double(id)),
                          "version": .string(version)]
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, _) = try await session.data(for: request)
            return try Self.parseResponse(data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()   // URLSession's spelling of task cancellation
        }
    }

    static func parseResponse(_ data: Data) throws -> [JSON] {
        let response = try JSONDecoder().decode(JSON.self, from: data)
        if let err = response["error"]?.array, let code = err.first?.int {
            throw SonyError(code: code, message: err.count > 1 ? err[1].string ?? "" : "")
        }
        return response["result"]?.array ?? response["results"]?.array ?? []
    }
}
