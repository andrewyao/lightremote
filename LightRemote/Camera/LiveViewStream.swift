import Foundation

/// Incremental parser for Sony's live view stream:
/// 8-byte common header (0xFF, payload type, seq u16, timestamp u32)
/// + 128-byte payload header (start code 24 35 68 79, JPEG size u24, padding u8, ...)
/// + JPEG bytes + padding. Payload type 0x01 is a JPEG frame; 0x02 (frame info) is skipped.
struct LiveViewParser {
    static let commonHeaderSize = 8
    static let payloadHeaderSize = 128
    static let startCode: [UInt8] = [0x24, 0x35, 0x68, 0x79]

    private var buffer = Data()

    /// Feed bytes; returns every complete JPEG frame now available.
    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while true {
            // Resync to the next common header start byte.
            guard let start = buffer.firstIndex(of: 0xFF) else { buffer.removeAll(); break }
            if start != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            let headers = Self.commonHeaderSize + Self.payloadHeaderSize
            guard buffer.count >= headers else { break }
            let b = [UInt8](buffer.prefix(headers))
            let payloadType = b[1]
            guard Array(b[8..<12]) == Self.startCode else {
                buffer.removeFirst() // false 0xFF; keep scanning
                continue
            }
            let size = Int(b[12]) << 16 | Int(b[13]) << 8 | Int(b[14])
            let padding = Int(b[15])
            let total = headers + size + padding
            guard buffer.count >= total else { break }
            if payloadType == 0x01 {
                let s = buffer.startIndex + headers
                frames.append(Data(buffer[s..<(s + size)]))
            }
            buffer.removeFirst(total)
        }
        buffer = Data(buffer) // re-base indices so the buffer doesn't keep growing its start offset
        return frames
    }
}

/// Streams JPEG frames from a live view URL. Ends when the connection drops; callers reconnect.
final class LiveViewStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var parser = LiveViewParser()
    private var continuation: AsyncStream<Data>.Continuation?
    private var task: URLSessionDataTask?
    private let lock = NSLock()

    func frames(from url: URL) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock { self.continuation = continuation }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: url)
            lock.withLock { self.task = task }
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    func cancel() { lock.withLock { task?.cancel() } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            for frame in parser.feed(data) { continuation?.yield(frame) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { continuation?.finish() }
    }
}
