import Foundation

@MainActor
final class KinescopeVideoStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveEntityID(_ entityID: String, forVideoID videoID: String) {
        defaults.set(entityID, forKey: entityIDKey(for: videoID))
    }

    func entityID(forVideoID videoID: String) -> String? {
        defaults.string(forKey: entityIDKey(for: videoID))
    }

    func clearEntityID(forVideoID videoID: String) {
        defaults.removeObject(forKey: entityIDKey(for: videoID))
    }

    func saveSelectedVideoID(_ videoID: String) {
        defaults.set(videoID, forKey: selectedVideoIDKey)
    }

    func selectedVideoID(defaultValue: String) -> String {
        defaults.string(forKey: selectedVideoIDKey) ?? defaultValue
    }

    private var selectedVideoIDKey: String {
        "offlineAsset.selectedVideoID"
    }

    private func entityIDKey(for videoID: String) -> String {
        "offlineAsset.entityID.\(videoID)"
    }
}
