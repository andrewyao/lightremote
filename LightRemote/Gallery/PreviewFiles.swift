import Foundation

/// Local gallery persistence, independent of networking and Photos authorization.
struct PreviewFiles {
    let folder: URL
    static let byteLimit = 500 * 1024 * 1024

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postviews", isDirectory: true)
    }

    func url(for name: String) -> URL { folder.appendingPathComponent(name) }

    func load() throws -> [Shot] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = url(for: "index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([Shot].self, from: Data(contentsOf: index)).filter {
            !$0.fileName.contains("/") && !$0.fileName.contains("\\") && !$0.fileName.hasPrefix(".")
                && FileManager.default.fileExists(atPath: url(for: $0.fileName).path)
        }
    }

    func totalBytes() throws -> Int {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        return try urls.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    func size(of name: String) -> Int {
        (try? url(for: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func write(_ data: Data, named name: String) throws {
        guard data.count <= Self.byteLimit - (try totalBytes()) else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url(for: name), options: .atomic)
    }

    func save(_ shots: [Shot]) throws {
        try JSONEncoder().encode(shots).write(to: url(for: "index.json"), options: .atomic)
    }

    func delete(_ name: String) throws {
        let file = url(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return }   // already gone is fine
        try FileManager.default.removeItem(at: file)
    }
}
