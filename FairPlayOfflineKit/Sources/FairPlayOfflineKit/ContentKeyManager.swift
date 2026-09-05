import AVFoundation
import Foundation

enum ContentKeyManagerError: LocalizedError {
    case invalidContentIdentifier
    case cannotRequestPersistableKey(Error?)
    case missingPersistedKey

    var errorDescription: String? {
        switch self {
        case .invalidContentIdentifier:
            return "Could not read the content ID from the FairPlay key request."
        case .cannotRequestPersistableKey(let error):
            return "AVFoundation could not create a persistable key request: \(error?.localizedDescription ?? "unknown error")."
        case .missingPersistedKey:
            return "The persistent FairPlay key was not found."
        }
    }
}

@MainActor
final class ContentKeyManager: NSObject {
    enum Mode {
        case download(FairPlayAsset)
        case offline
    }

    var onKeyPersisted: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let entityID: String
    private let mode: Mode
    private let keyStore: PersistentKeyStore
    private let licenseClient: LicenseClient
    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)

    init(
        entityID: String,
        mode: Mode,
        keyStore: PersistentKeyStore,
        licenseClient: LicenseClient = LicenseClient()
    ) {
        self.entityID = entityID
        self.mode = mode
        self.keyStore = keyStore
        self.licenseClient = licenseClient
        super.init()
        session.setDelegate(self, queue: .main)
    }

    func bind(to asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
    }

    private func requestPersistableKey(from keyRequest: AVContentKeyRequest) {
        FairPlayLog.drm.info(
            "Requesting persistable key entityID=\(self.entityID, privacy: .public)"
        )
        do {
            try keyRequest
                .respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch let requestError {
            let wrappedError = ContentKeyManagerError.cannotRequestPersistableKey(requestError)
            keyRequest.processContentKeyResponseError(wrappedError)
            report(wrappedError)
        }
    }

    private func processOnlineRequest(_ keyRequest: AVPersistableContentKeyRequest) {
        guard case .download(let asset) = mode else {
            return
        }

        Task {
            do {
                FairPlayLog.drm.info(
                    "Persistable key request received entityID=\(self.entityID, privacy: .public)"
                )
                let contentIdentifier = try contentIdentifier(from: keyRequest)
                let certificate = try await licenseClient.fetchCertificate(
                    from: asset.certificateURL
                )
                let spc = try await keyRequest.makeStreamingContentKeyRequestData(
                    forApp: certificate,
                    contentIdentifier: contentIdentifier,
                    options: [AVContentKeyRequestProtocolVersionsKey: [1]]
                )
                let ckc = try await licenseClient.acquireCKC(
                    from: asset.licenseURL,
                    spc: spc
                )
                let persistedKey = try keyRequest.persistableContentKey(
                    fromKeyVendorResponse: ckc,
                    options: nil
                )

                try keyStore.saveKey(
                    persistedKey,
                    entityID: entityID,
                    contentIdentifier: contentIdentifier
                )
                FairPlayLog.drm.info(
                    """
                    Persistent key saved entityID=\(self.entityID, privacy: .public) \
                    bytes=\(persistedKey.count)
                    """
                )
                keyRequest.processContentKeyResponse(
                    AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistedKey)
                )
                onKeyPersisted?()
            } catch {
                keyRequest.processContentKeyResponseError(error)
                report(error)
            }
        }
    }

    private func processOfflineRequest(_ keyRequest: AVPersistableContentKeyRequest) {
        do {
            let contentIdentifier = try contentIdentifier(from: keyRequest)
            guard keyStore.hasKey(
                entityID: entityID,
                contentIdentifier: contentIdentifier
            ) else {
                throw ContentKeyManagerError.missingPersistedKey
            }
            let key = try keyStore.loadKey(
                entityID: entityID,
                contentIdentifier: contentIdentifier
            )
            FairPlayLog.drm.info(
                """
                Offline key loaded entityID=\(self.entityID, privacy: .public) \
                bytes=\(key.count)
                """
            )
            keyRequest.processContentKeyResponse(
                AVContentKeyResponse(fairPlayStreamingKeyResponseData: key)
            )
        } catch {
            keyRequest.processContentKeyResponseError(error)
            report(error)
        }
    }

    private func contentIdentifier(from keyRequest: AVContentKeyRequest) throws -> Data {
        if let identifier = keyRequest.identifier as? String {
            let contentID = identifier.replacingOccurrences(of: "skd://", with: "")
            if let data = contentID.data(using: .utf8), !data.isEmpty {
                return data
            }
        }

        if let data = keyRequest.identifier as? Data, !data.isEmpty {
            return data
        }

        throw ContentKeyManagerError.invalidContentIdentifier
    }

    private func report(_ error: Error) {
        FairPlayLog.error(
            error,
            context: "ContentKeyManager entityID=\(entityID)",
            logger: FairPlayLog.drm
        )
        onError?(error)
    }
}

extension ContentKeyManager: @preconcurrency AVContentKeySessionDelegate {
    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVContentKeyRequest
    ) {
        requestPersistableKey(from: keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        switch mode {
        case .download:
            processOnlineRequest(keyRequest)
        case .offline:
            processOfflineRequest(keyRequest)
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        switch retryReason {
        case .timedOut, .receivedResponseWithExpiredLease, .receivedObsoleteContentKey:
            return true
        default:
            return false
        }
    }
}
