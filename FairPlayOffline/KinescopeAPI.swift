import Foundation
import FairPlayOfflineKit

struct KinescopeVideo: Sendable {
    let entityID: String
    let offlineAsset: FairPlayAsset?
}

enum KinescopeAPIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case fairPlayConfigurationMissing

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Could not create the metadata URL."
        case .invalidResponse:
            return "The metadata server returned an invalid response."
        case .httpStatus(let statusCode):
            return "The metadata server returned HTTP \(statusCode)."
        case .fairPlayConfigurationMissing:
            return "The .json?sdk response does not contain drm.fairplay. Use a commercial-DRM video."
        }
    }
}

struct KinescopeAPI {
    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = AppConfiguration.apiBaseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchVideo(videoID: String) async throws -> KinescopeVideo {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("\(videoID).json"),
            resolvingAgainstBaseURL: false
        ) else {
            throw KinescopeAPIError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "sdk", value: nil)]

        guard let url = components.url else {
            throw KinescopeAPIError.invalidEndpoint
        }

        AppLog.api.info(
            "Metadata request endpoint=\(AppLog.endpoint(url), privacy: .public)"
        )
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KinescopeAPIError.invalidResponse
        }
        AppLog.api.info(
            "Metadata response status=\(httpResponse.statusCode) bytes=\(data.count)"
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            throw KinescopeAPIError.httpStatus(httpResponse.statusCode)
        }

        return try decodeVideo(from: data)
    }

    func decodeVideo(from data: Data) throws -> KinescopeVideo {
        let payload = try JSONDecoder().decode(VideoPayload.self, from: data)
        return KinescopeVideo(
            entityID: payload.id,
            offlineAsset: payload.drm?.fairPlay.map {
                FairPlayAsset(
                    entityID: payload.id,
                    playlistURL: payload.hlsLink,
                    licenseURL: $0.licenseURL,
                    certificateURL: $0.certificateURL
                )
            }
        )
    }
}

private struct VideoPayload: Decodable {
    let id: String
    let hlsLink: URL
    let drm: DRMPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case hlsLink = "hls_link"
        case drm
    }
}

private struct DRMPayload: Decodable {
    let fairPlay: FairPlayPayload?

    enum CodingKeys: String, CodingKey {
        case fairPlay = "fairplay"
    }
}

private struct FairPlayPayload: Decodable {
    let licenseURL: URL
    let certificateURL: URL

    enum CodingKeys: String, CodingKey {
        case licenseURL = "licenseUrl"
        case certificateURL = "certificateUrl"
    }
}
