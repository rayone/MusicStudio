import Foundation
public enum SongwriterAPIError: LocalizedError {
    case invalidURL
    case missingToken
    case invalidResponse
    case disabled
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid Songwriter API URL."
        case .missingToken:
            return "Enter a Songwriter Bearer token."
        case .invalidResponse:
            return "Songwriter returned an invalid response."
        case .disabled:
            return "Songwriter API integration is disabled in Settings."
        case .server(let status):
            return "Songwriter request failed (HTTP \(status))."
        }
    }
}

public final class SongwriterAPI {
    public static let shared = SongwriterAPI()
    public static let defaultBaseURL = "http://127.0.0.1:8000"
    public static let defaultLocalToken = "musicstudio"

    private static let baseURLKey = "songwriterAPIBaseURL"
    private static let tokenKey = "songwriterAPIToken"
    private static let enabledKey = "songwriterAPIEnabled"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    public static var configuredBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
    }

    public static var configuredToken: String {
        UserDefaults.standard.string(forKey: tokenKey) ?? defaultLocalToken
    }

    public static func saveConfiguration(baseURL: String, token: String, isEnabled: Bool? = nil) throws {
        let normalized = try validatedBaseURL(baseURL)
            .absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { throw SongwriterAPIError.missingToken }
        UserDefaults.standard.set(normalized, forKey: baseURLKey)
        UserDefaults.standard.set(cleanToken, forKey: tokenKey)
        if let isEnabled = isEnabled {
            self.isEnabled = isEnabled
        }
    }

    @discardableResult
    public func testConnection(baseURL: String, token: String) async throws -> Int {
        let root = try Self.validatedBaseURL(baseURL)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { throw SongwriterAPIError.missingToken }
        let response: SongwriterSongList = try await get(
            "v1/songs",
            queryItems: [
                URLQueryItem(name: "status", value: "ready"),
                URLQueryItem(name: "limit", value: "1")
            ],
            baseURL: root,
            token: cleanToken,
            as: SongwriterSongList.self
        )
        return response.songs.count
    }

    public func songs() async throws -> [SongwriterSongSummary] {
        guard Self.isEnabled else { throw SongwriterAPIError.disabled }
        let root = try Self.validatedBaseURL(Self.configuredBaseURL)
        var summaries = try await get(
            "v1/songs",
            queryItems: [
                URLQueryItem(name: "status", value: "ready"),
                URLQueryItem(name: "limit", value: "50")
            ],
            baseURL: root,
            token: Self.configuredToken,
            as: SongwriterSongList.self
        ).songs
        let missingIds = summaries.filter { $0.created_at == nil }.map(\.id)
        if !missingIds.isEmpty {
            let createdById = await withTaskGroup(of: (String, String?).self) { group in
                for id in missingIds {
                    group.addTask { [self] in
                        let detail = try? await get(
                            "v1/songs/\(id)",
                            baseURL: root,
                            token: Self.configuredToken,
                            as: SongwriterSongDetail.self
                        )
                        return (id, detail?.created_at)
                    }
                }
                var result: [String: String] = [:]
                for await (id, createdAt) in group {
                    if let createdAt { result[id] = createdAt }
                }
                return result
            }
            for index in summaries.indices {
                summaries[index].created_at = createdById[summaries[index].id]
            }
        }
        return summaries
    }

    public func song(id: String) async throws -> SongwriterSongDetail {
        guard Self.isEnabled else { throw SongwriterAPIError.disabled }
        let root = try Self.validatedBaseURL(Self.configuredBaseURL)
        return try await get(
            "v1/songs/\(id)",
            baseURL: root,
            token: Self.configuredToken,
            as: SongwriterSongDetail.self
        )
    }

    private func get<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        baseURL: URL,
        token: String,
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw SongwriterAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SongwriterAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SongwriterAPIError.server(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SongwriterAPIError.invalidResponse
        }
    }

    private static func validatedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              scheme == "http" || scheme == "https" else {
            throw SongwriterAPIError.invalidURL
        }
        return url
    }

}
