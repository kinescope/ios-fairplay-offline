import Foundation

enum DownloadStoreError: LocalizedError {
    case assetLocationMissing

    var errorDescription: String? {
        "AVFoundation did not create a local asset at the saved URL."
    }
}

@MainActor
final class DownloadStore {
    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
    }

    func savePendingAssetLocation(_ location: URL, for entityID: String) {
        defaults.set(location.absoluteString, forKey: assetLocationKey(for: entityID))
    }

    func finalizeAssetLocation(for entityID: String) throws {
        guard let location = assetURL(for: entityID) else {
            throw DownloadStoreError.assetLocationMissing
        }
        try saveBookmark(location, entityID: entityID)
    }

    func assetURL(for entityID: String) -> URL? {
        let key = assetLocationKey(for: entityID)

        if let bookmark = defaults.data(forKey: key) {
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ),
                fileManager.fileExists(atPath: url.path)
            else {
                return nil
            }

            if isStale {
                try? saveBookmark(url, entityID: entityID)
            }
            return url
        }

        guard
            let urlString = defaults.string(forKey: key),
            let url = URL(string: urlString),
            url.isFileURL,
            fileManager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    func markStarted(entityID: String) {
        defaults.set(false, forKey: completionKey(for: entityID))
    }

    func markCompleted(entityID: String) {
        defaults.set(true, forKey: completionKey(for: entityID))
    }

    func isCompleted(entityID: String) -> Bool {
        defaults.bool(forKey: completionKey(for: entityID))
    }

    func removeMetadata(entityID: String) {
        defaults.removeObject(forKey: assetLocationKey(for: entityID))
        defaults.removeObject(forKey: completionKey(for: entityID))
    }

    private func saveBookmark(_ url: URL, entityID: String) throws {
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: assetLocationKey(for: entityID))
    }

    private func assetLocationKey(for entityID: String) -> String {
        "offlineAsset.location.\(entityID)"
    }

    private func completionKey(for entityID: String) -> String {
        "offlineAsset.completed.\(entityID)"
    }
}
