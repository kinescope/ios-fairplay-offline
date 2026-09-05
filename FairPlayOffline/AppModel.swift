import AVFoundation
import FairPlayOfflineKit
import Foundation
import OSLog

enum AppViewState {
    case configurationRequired
    case readyToDownload
    case fetchingMetadata
    case downloading(progress: Double, keyPersisted: Bool, keyError: String?)
    case ready
    case playing
    case deleting
    case failure(String)

    var status: String {
        switch self {
        case .configurationRequired:
            return "Enter a commercial-DRM video ID."
        case .readyToDownload:
            return "Ready to download."
        case .fetchingMetadata:
            return "Loading .json?sdk…"
        case let .downloading(_, keyPersisted, keyError):
            if let keyError {
                return "FairPlay key error: \(keyError)"
            }
            return keyPersisted
                ? "The persistent key is saved. Downloading video…"
                : "Downloading HLS and requesting a persistent key…"
        case .ready:
            return "Ready. You can enable Airplane Mode."
        case .playing:
            return "Playing offline. No network request is used for the key."
        case .deleting:
            return "Cancelling the task and deleting data…"
        case .failure(let message):
            return "Error: \(message)"
        }
    }

    var progress: Double? {
        guard case .downloading(let progress, _, _) = self else {
            return nil
        }
        return progress
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppViewState
    @Published private(set) var videoID: String

    var player: AVPlayer? {
        fairPlay.player
    }

    private(set) var entityID: String?
    private let api: KinescopeAPI
    private let videoStore: KinescopeVideoStore
    private let fairPlay: FairPlayOfflineClient

    convenience init() {
        self.init(
            api: KinescopeAPI(),
            videoStore: KinescopeVideoStore(),
            fairPlay: FairPlayOfflineClient()
        )
    }

    init(
        api: KinescopeAPI,
        videoStore: KinescopeVideoStore,
        fairPlay: FairPlayOfflineClient
    ) {
        self.api = api
        self.videoStore = videoStore
        self.fairPlay = fairPlay

        let selectedVideoID = videoStore.selectedVideoID(
            defaultValue: AppConfiguration.defaultVideoID
        )
        videoID = selectedVideoID
        let normalizedVideoID = Self.normalize(selectedVideoID)
        let storedEntityID = videoStore.entityID(forVideoID: normalizedVideoID)
        entityID = storedEntityID
        if normalizedVideoID.isEmpty {
            state = .configurationRequired
        } else if let storedEntityID,
                  fairPlay.isDownloaded(entityID: storedEntityID) {
            state = .ready
        } else {
            state = .readyToDownload
        }

        fairPlay.onDownloadEvent = { [weak self] event in
            self?.handleDownloadEvent(event)
        }
        fairPlay.onPlaybackError = { [weak self] error in
            self?.state = .failure("Playback error: \(error.localizedDescription)")
        }
    }

    var canDownload: Bool {
        let stateAllowsDownload: Bool
        switch state {
        case .readyToDownload, .failure:
            stateAllowsDownload = true
        default:
            stateAllowsDownload = false
        }

        return stateAllowsDownload &&
            hasConfiguredVideoID &&
            !fairPlay.isDownloading &&
            !hasOfflineContent &&
            !isDeleting
    }

    var canPlay: Bool {
        hasOfflineContent && !isDeleting
    }

    var canDelete: Bool {
        entityID != nil &&
            !fairPlay.isPreparingDownload &&
            !isDeleting
    }

    var canEditVideoID: Bool {
        switch state {
        case .fetchingMetadata, .downloading, .deleting:
            return false
        default:
            return true
        }
    }

    func updateVideoID(_ value: String) {
        guard canEditVideoID else {
            return
        }

        fairPlay.stop()
        videoID = value
        videoStore.saveSelectedVideoID(value)
        refreshSelectedVideo()
    }

    func startDownload() async {
        guard canDownload else {
            return
        }
        let requestedVideoID = normalizedVideoID
        state = .fetchingMetadata

        do {
            let video = try await api.fetchVideo(videoID: requestedVideoID)
            guard let asset = video.offlineAsset else {
                throw KinescopeAPIError.fairPlayConfigurationMissing
            }

            entityID = video.entityID
            videoStore.saveEntityID(video.entityID, forVideoID: requestedVideoID)
            state = .downloading(progress: 0, keyPersisted: false, keyError: nil)
            try await fairPlay.download(asset)
        } catch {
            log(error, context: "AppModel.startDownload", logger: AppLog.api)
            state = .failure(error.localizedDescription)
        }
    }

    func playOffline() {
        guard let entityID else {
            state = .failure("No saved entity_id was found.")
            return
        }

        do {
            try fairPlay.play(entityID: entityID)
            state = .playing
        } catch {
            log(error, context: "AppModel.playOffline", logger: AppLog.player)
            state = .failure(error.localizedDescription)
        }
    }

    func deleteDownload() async {
        guard let entityID else {
            return
        }

        state = .deleting
        fairPlay.stop()
        do {
            try await fairPlay.deleteDownload(entityID: entityID)
            videoStore.clearEntityID(forVideoID: normalizedVideoID)
            self.entityID = nil
            state = hasConfiguredVideoID
                ? .readyToDownload
                : .configurationRequired
        } catch {
            log(error, context: "AppModel.deleteDownload", logger: AppLog.download)
            state = .failure("Delete failed: \(error.localizedDescription)")
        }
    }

    private var hasOfflineContent: Bool {
        guard let entityID else {
            return false
        }
        return fairPlay.isDownloaded(entityID: entityID)
    }

    private var normalizedVideoID: String {
        Self.normalize(videoID)
    }

    private var hasConfiguredVideoID: Bool {
        !normalizedVideoID.isEmpty
    }

    private var isDeleting: Bool {
        if case .deleting = state {
            return true
        }
        return false
    }

    private func handleDownloadEvent(_ event: FairPlayDownloadEvent) {
        switch event {
        case .progress(let value):
            guard case let .downloading(_, keyPersisted, keyError) = state else {
                return
            }
            state = .downloading(
                progress: value,
                keyPersisted: keyPersisted,
                keyError: keyError
            )
        case .keyPersisted:
            guard case let .downloading(progress, _, keyError) = state else {
                return
            }
            state = .downloading(
                progress: progress,
                keyPersisted: true,
                keyError: keyError
            )
        case .keyFailed(let error):
            guard case let .downloading(progress, keyPersisted, _) = state else {
                return
            }
            state = .downloading(
                progress: progress,
                keyPersisted: keyPersisted,
                keyError: error.localizedDescription
            )
        case .completed:
            state = hasOfflineContent
                ? .ready
                : .failure("The download finished, but the asset or key was not found.")
        case .failed(let error):
            state = .failure("Download failed: \(error.localizedDescription)")
        }
    }

    private func log(_ error: Error, context: String, logger: Logger) {
        AppLog.error(error, context: context, logger: logger)
    }

    private func refreshSelectedVideo() {
        let videoID = normalizedVideoID
        guard !videoID.isEmpty else {
            entityID = nil
            state = .configurationRequired
            return
        }

        entityID = videoStore.entityID(forVideoID: videoID)
        state = entityID.map { fairPlay.isDownloaded(entityID: $0) } == true
            ? .ready
            : .readyToDownload
    }

    private static func normalize(_ videoID: String) -> String {
        videoID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
