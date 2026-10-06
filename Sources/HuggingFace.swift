import Foundation

public struct HFModelItem: Identifiable, Codable, Hashable {
    public var id: String
    public var author: String?
    public var downloads: Int?
    public var likes: Int?
    public var lastModified: String?
    public var tags: [String]?

    public var shortName: String {
        if let slash = id.firstIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }
}

public struct HFFileTreeItem: Codable, Hashable {
    public var type: String
    public var path: String
    public var size: Int64?
}

public struct HFDownloadProgress: Identifiable {
    public var id: String { "\(repoId):\(subfolder ?? "root")" }
    public var repoId: String
    public var subfolder: String?
    public var currentFile: String
    public var filesCompleted: Int
    public var totalFiles: Int
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var speedBytesPerSec: Double
    public var isComplete: Bool
    public var isCancelled: Bool
    public var error: String?

    public var progressFraction: Double {
        if totalBytes > 0 {
            return min(1.0, max(0.0, Double(bytesDownloaded) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            return min(1.0, max(0.0, Double(filesCompleted) / Double(totalFiles)))
        }
        return 0.0
    }
}

@MainActor
public final class HuggingFaceClient: NSObject, ObservableObject {
    public static let shared = HuggingFaceClient()

    @Published public var searchResults: [HFModelItem] = []
    @Published public var isSearching = false
    @Published public var activeDownloads: [String: HFDownloadProgress] = [:]

    private var urlSession: URLSession!
    private var downloadTasks: [URL: URLSessionDownloadTask] = [:]

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        self.urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }

    public var apiToken: String? {
        get {
            let token = UserDefaults.standard.string(forKey: "hfToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty ?? true) ? nil : token
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hfToken")
        }
    }

    private func applyAuth(to request: inout URLRequest) {
        if let token = apiToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    public func searchModels(query: String = "") async throws -> [HFModelItem] {
        isSearching = true
        defer { isSearching = false }

        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: "text-to-audio"),
            URLQueryItem(name: "full", value: "true"),
            URLQueryItem(name: "limit", value: "30")
        ]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        applyAuth(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "HuggingFace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to search HuggingFace models."])
        }

        let results = try JSONDecoder().decode([HFModelItem].self, from: data)
        self.searchResults = results
        return results
    }

    public func fetchFileTree(repoId: String) async throws -> [HFFileTreeItem] {
        let endpoint = "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=true"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "HuggingFace", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid repo URL"])
        }

        var request = URLRequest(url: url)
        applyAuth(to: &request)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "HuggingFace", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve repository tree for \(repoId) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."])
        }

        return try JSONDecoder().decode([HFFileTreeItem].self, from: data)
    }

    public func downloadModel(
        repoId: String,
        subfolder: String? = nil,
        destinationDir: URL,
        onProgress: @escaping (HFDownloadProgress) -> Void
    ) async throws {
        let downloadKey = "\(repoId):\(subfolder ?? "root")"
        let tree = try await fetchFileTree(repoId: repoId)

        // Filter files belonging to subfolder or root
        let files = tree.filter { item in
            guard item.type == "file" else { return false }
            if let sub = subfolder, !sub.isEmpty {
                return item.path.hasPrefix("\(sub)/")
            }
            return true
        }

        let totalBytes = files.compactMap { $0.size }.reduce(0, +)
        var state = HFDownloadProgress(
            repoId: repoId,
            subfolder: subfolder,
            currentFile: "",
            filesCompleted: 0,
            totalFiles: files.count,
            bytesDownloaded: 0,
            totalBytes: totalBytes,
            speedBytesPerSec: 0,
            isComplete: false,
            isCancelled: false,
            error: nil
        )
        self.activeDownloads[downloadKey] = state
        onProgress(state)

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let startTime = CFAbsoluteTimeGetCurrent()

        for (idx, file) in files.enumerated() {
            state.currentFile = file.path
            state.filesCompleted = idx
            self.activeDownloads[downloadKey] = state
            onProgress(state)

            // Local relative path
            let relativePath: String
            if let sub = subfolder, !sub.isEmpty, file.path.hasPrefix("\(sub)/") {
                relativePath = String(file.path.dropFirst(sub.count + 1))
            } else {
                relativePath = file.path
            }

            let fileDestURL = destinationDir.appendingPathComponent(relativePath)
            try fm.createDirectory(at: fileDestURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Check if file already downloaded with correct size
            if fm.fileExists(atPath: fileDestURL.path),
               let attrs = try? fm.attributesOfItem(atPath: fileDestURL.path),
               let existingSize = attrs[.size] as? Int64,
               let expectedSize = file.size, existingSize == expectedSize {
                state.bytesDownloaded += existingSize
                continue
            }

            let rawDownloadURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path)")!
            var request = URLRequest(url: rawDownloadURL)
            applyAuth(to: &request)

            let (tempURL, response) = try await urlSession.download(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "HuggingFace", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed downloading \(file.path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
            }

            if fm.fileExists(atPath: fileDestURL.path) {
                try fm.removeItem(at: fileDestURL)
            }
            try fm.moveItem(at: tempURL, to: fileDestURL)

            state.bytesDownloaded += file.size ?? 0
            let elapsed = max(0.1, CFAbsoluteTimeGetCurrent() - startTime)
            state.speedBytesPerSec = Double(state.bytesDownloaded) / elapsed
            self.activeDownloads[downloadKey] = state
            onProgress(state)
        }

        state.isComplete = true
        state.filesCompleted = files.count
        self.activeDownloads[downloadKey] = state
        onProgress(state)
    }
}
