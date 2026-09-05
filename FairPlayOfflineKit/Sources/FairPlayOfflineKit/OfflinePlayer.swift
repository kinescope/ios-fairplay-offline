import AVFoundation

enum OfflinePlayerError: LocalizedError {
    case assetNotFound
    case keyNotFound

    var errorDescription: String? {
        switch self {
        case .assetNotFound:
            return "The downloaded asset was not found."
        case .keyNotFound:
            return "The persistent FairPlay key was not found."
        }
    }
}

@MainActor
final class OfflinePlayer {
    typealias KeySessionFactory = (
        _ entityID: String,
        _ asset: AVURLAsset,
        _ onError: @escaping (Error) -> Void
    ) -> AnyObject

    private(set) var player: AVPlayer?
    var onError: ((Error) -> Void)?

    private let downloadStore: DownloadStore
    private let keyStore: PersistentKeyStore
    private let makePlayer: (AVPlayerItem) -> AVPlayer
    private let pausePlayer: (AVPlayer) -> Void
    private let makeKeySession: KeySessionFactory
    private var keySession: AnyObject?

    init(
        downloadStore: DownloadStore,
        keyStore: PersistentKeyStore,
        makePlayer: @escaping (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) },
        pausePlayer: @escaping (AVPlayer) -> Void = { $0.pause() },
        makeKeySession: KeySessionFactory? = nil
    ) {
        self.downloadStore = downloadStore
        self.keyStore = keyStore
        self.makePlayer = makePlayer
        self.pausePlayer = pausePlayer
        self.makeKeySession = makeKeySession ?? { entityID, asset, onError in
            let manager = ContentKeyManager(
                entityID: entityID,
                mode: .offline,
                keyStore: keyStore
            )
            manager.onError = onError
            manager.bind(to: asset)
            return manager
        }
    }

    func play(entityID: String) throws {
        guard
            downloadStore.isCompleted(entityID: entityID),
            let assetURL = downloadStore.assetURL(for: entityID)
        else {
            throw OfflinePlayerError.assetNotFound
        }
        guard keyStore.hasAnyKey(entityID: entityID) else {
            throw OfflinePlayerError.keyNotFound
        }

        stop()

        let asset = AVURLAsset(url: assetURL)
        keySession = makeKeySession(entityID, asset) { [weak self] error in
            self?.onError?(error)
        }

        let player = makePlayer(AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = false
        self.player = player
        player.play()
    }

    func stop() {
        if let player {
            pausePlayer(player)
        }
        player = nil
        keySession = nil
    }
}
