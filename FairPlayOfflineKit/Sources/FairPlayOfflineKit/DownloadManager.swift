import AVFoundation
import Foundation

public enum FairPlayDownloadEvent {
    case progress(Double)
    case keyPersisted
    case keyFailed(Error)
    case completed
    case failed(Error)
}

enum DownloadManagerError: LocalizedError {
    case cannotCreateDownloadTask
    case downloadAlreadyExists
    case downloadAlreadyInProgress
    case downloadPreparationInProgress
    case deletionAlreadyInProgress
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .cannotCreateDownloadTask:
            return "AVFoundation could not create the download task."
        case .downloadAlreadyExists:
            return "The video is already downloaded. Delete the existing download first."
        case .downloadAlreadyInProgress:
            return "A video is already being downloaded."
        case .downloadPreparationInProgress:
            return "The download is still being prepared. Try deleting it again in a moment."
        case .deletionAlreadyInProgress:
            return "The download is already being deleted."
        case .incompleteDownload:
            return "The download finished without a local asset or persistent key."
        }
    }
}

@MainActor
final class DownloadManager: NSObject {
    var onEvent: ((FairPlayDownloadEvent) -> Void)?
    var isDownloading: Bool { isPreparingDownload || activeTask != nil }
    private(set) var isPreparingDownload = false

    private let sessionIdentifier: String
    private let downloadStore: DownloadStore
    private let keyStore: PersistentKeyStore
    private var session: AVAssetDownloadURLSession?
    private var activeTask: AVAggregateAssetDownloadTask?
    private var keyManager: ContentKeyManager?
    private var keyFailure: Error?
    private var deletionContinuation: CheckedContinuation<Void, Error>?

    init(
        sessionIdentifier: String,
        downloadStore: DownloadStore,
        keyStore: PersistentKeyStore
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.downloadStore = downloadStore
        self.keyStore = keyStore
        super.init()
    }

    func start(asset: FairPlayAsset) async throws {
        guard !isDownloading else {
            throw DownloadManagerError.downloadAlreadyInProgress
        }
        guard !hasPlayableDownload(entityID: asset.entityID) else {
            throw DownloadManagerError.downloadAlreadyExists
        }

        isPreparingDownload = true
        defer { isPreparingDownload = false }

        try removeStoredFiles(entityID: asset.entityID)

        // FairPlay requires the key session and recipient before the download session.
        let urlAsset = AVURLAsset(url: asset.playlistURL)
        let keyManager = makeKeyManager(asset: asset)
        keyManager.bind(to: urlAsset)

        let mediaSelection = try await urlAsset.load(.preferredMediaSelection)
        let session = makeSession()
        let task = session.aggregateAssetDownloadTask(
            with: urlAsset,
            mediaSelections: [mediaSelection],
            assetTitle: asset.entityID,
            assetArtworkData: nil,
            options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 265_000]
        )
        guard let task else {
            throw DownloadManagerError.cannotCreateDownloadTask
        }

        downloadStore.markStarted(entityID: asset.entityID)
        task.taskDescription = asset.entityID
        self.keyManager = keyManager
        keyFailure = nil
        activeTask = task

        FairPlayLog.download.info(
            "Starting task id=\(task.taskIdentifier) entityID=\(asset.entityID, privacy: .public)"
        )
        task.resume()
        onEvent?(.progress(0))
    }

    func deleteDownload(entityID: String) async throws {
        guard !isPreparingDownload else {
            throw DownloadManagerError.downloadPreparationInProgress
        }
        guard deletionContinuation == nil else {
            throw DownloadManagerError.deletionAlreadyInProgress
        }
        guard activeTask?.taskDescription == entityID else {
            try removeStoredFiles(entityID: entityID)
            return
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            deletionContinuation = continuation
            activeTask?.cancel()
        }
    }

    func hasPlayableDownload(entityID: String) -> Bool {
        downloadStore.isCompleted(entityID: entityID) &&
            downloadStore.assetURL(for: entityID) != nil &&
            keyStore.hasAnyKey(entityID: entityID)
    }

    private func makeSession() -> AVAssetDownloadURLSession {
        if let session {
            return session
        }

        let configuration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )
        configuration.isDiscretionary = false
        let session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
        self.session = session
        return session
    }

    private func makeKeyManager(asset: FairPlayAsset) -> ContentKeyManager {
        let manager = ContentKeyManager(
            entityID: asset.entityID,
            mode: .download(asset),
            keyStore: keyStore
        )
        manager.onKeyPersisted = { [weak self] in
            self?.onEvent?(.keyPersisted)
        }
        manager.onError = { [weak self] error in
            self?.keyFailure = error
            self?.onEvent?(.keyFailed(error))
        }
        return manager
    }

    private func removeStoredFiles(entityID: String) throws {
        if let assetURL = downloadStore.assetURL(for: entityID) {
            try FileManager.default.removeItem(at: assetURL)
        }
        try keyStore.deleteKeys(entityID: entityID)
        downloadStore.removeMetadata(entityID: entityID)
    }

    private func clearActiveDownload() {
        activeTask = nil
        keyManager = nil
        keyFailure = nil
    }

    private func reportFailure(_ failure: Error, entityID: String) {
        FairPlayLog.error(
            failure,
            context: "download entityID=\(entityID)",
            logger: FairPlayLog.download
        )
        do {
            try removeStoredFiles(entityID: entityID)
        } catch let cleanupError {
            FairPlayLog.error(
                cleanupError,
                context: "cleanup entityID=\(entityID)",
                logger: FairPlayLog.download
            )
        }
        onEvent?(.failed(failure))
    }
}

extension DownloadManager: @preconcurrency AVAssetDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard aggregateAssetDownloadTask.taskIdentifier == activeTask?.taskIdentifier else {
            return
        }
        guard let entityID = aggregateAssetDownloadTask.taskDescription else {
            return
        }
        downloadStore.savePendingAssetLocation(location, for: entityID)
    }

    func urlSession(
        _ session: URLSession,
        aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange,
        for mediaSelection: AVMediaSelection
    ) {
        guard aggregateAssetDownloadTask.taskIdentifier == activeTask?.taskIdentifier else {
            return
        }
        let expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expected.isFinite, expected > 0 else {
            return
        }
        let loaded = loadedTimeRanges.reduce(0.0) {
            $0 + CMTimeGetSeconds($1.timeRangeValue.duration)
        }
        onEvent?(.progress(min(max(loaded / expected, 0), 1)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard task.taskIdentifier == activeTask?.taskIdentifier else {
            return
        }
        guard let entityID = task.taskDescription else {
            clearActiveDownload()
            return
        }

        defer { clearActiveDownload() }

        if let continuation = deletionContinuation {
            deletionContinuation = nil
            do {
                try removeStoredFiles(entityID: entityID)
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
            return
        }

        if let error {
            reportFailure(error, entityID: entityID)
            return
        }

        do {
            if let keyFailure {
                throw keyFailure
            }
            try downloadStore.finalizeAssetLocation(for: entityID)
            guard hasPlayableDownloadCandidate(entityID: entityID) else {
                throw DownloadManagerError.incompleteDownload
            }
            downloadStore.markCompleted(entityID: entityID)
            onEvent?(.progress(1))
            onEvent?(.completed)
        } catch {
            reportFailure(error, entityID: entityID)
        }
    }

    private func hasPlayableDownloadCandidate(entityID: String) -> Bool {
        downloadStore.assetURL(for: entityID) != nil &&
            keyStore.hasAnyKey(entityID: entityID)
    }
}
