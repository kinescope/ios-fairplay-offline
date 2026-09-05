import AVFoundation
import Foundation

@MainActor
public final class FairPlayOfflineClient {
    public var onDownloadEvent: ((FairPlayDownloadEvent) -> Void)?
    public var onPlaybackError: ((Error) -> Void)?

    public var player: AVPlayer? {
        offlinePlayer.player
    }

    public var isDownloading: Bool {
        downloadManager.isDownloading
    }

    public var isPreparingDownload: Bool {
        downloadManager.isPreparingDownload
    }

    private let downloadManager: DownloadManager
    private let offlinePlayer: OfflinePlayer

    public convenience init() {
        let bundleID =
            Bundle.main.bundleIdentifier ?? "FairPlayOfflineKit"
        self.init(
            downloadSessionIdentifier: "\(bundleID).fairplay-download"
        )
    }

    public init(downloadSessionIdentifier: String) {
        let downloadStore = DownloadStore()
        let keyStore = PersistentKeyStore()
        downloadManager = DownloadManager(
            sessionIdentifier: downloadSessionIdentifier,
            downloadStore: downloadStore,
            keyStore: keyStore
        )
        offlinePlayer = OfflinePlayer(
            downloadStore: downloadStore,
            keyStore: keyStore
        )

        downloadManager.onEvent = { [weak self] event in
            self?.onDownloadEvent?(event)
        }
        offlinePlayer.onError = { [weak self] error in
            self?.onPlaybackError?(error)
        }
    }

    public func download(_ asset: FairPlayAsset) async throws {
        try await downloadManager.start(asset: asset)
    }

    public func isDownloaded(entityID: String) -> Bool {
        downloadManager.hasPlayableDownload(entityID: entityID)
    }

    public func play(entityID: String) throws {
        try offlinePlayer.play(entityID: entityID)
    }

    public func stop() {
        offlinePlayer.stop()
    }

    public func deleteDownload(entityID: String) async throws {
        try await downloadManager.deleteDownload(entityID: entityID)
    }
}
