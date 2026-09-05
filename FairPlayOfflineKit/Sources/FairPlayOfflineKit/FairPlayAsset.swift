import Foundation

public struct FairPlayAsset: Sendable {
    public let entityID: String
    public let playlistURL: URL
    public let licenseURL: URL
    public let certificateURL: URL

    public init(
        entityID: String,
        playlistURL: URL,
        licenseURL: URL,
        certificateURL: URL
    ) {
        self.entityID = entityID
        self.playlistURL = playlistURL
        self.licenseURL = licenseURL
        self.certificateURL = certificateURL
    }
}
