import CryptoKit
import Foundation

@MainActor
final class PersistentKeyStore {
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let baseDirectory: URL?

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.baseDirectory = baseDirectory
    }

    func saveKey(
        _ data: Data,
        entityID: String,
        contentIdentifier: Data
    ) throws {
        let keyID = storageID(for: contentIdentifier)
        let url = try keyDirectory(create: true)
            .appendingPathComponent(keyFileName(entityID: entityID, keyID: keyID))
        try data.write(to: url, options: .atomic)

        var keyIDs = Set(storedKeyIDs(entityID: entityID))
        keyIDs.insert(keyID)
        defaults.set(Array(keyIDs), forKey: keyIDsKey(entityID: entityID))
    }

    func loadKey(entityID: String, contentIdentifier: Data) throws -> Data {
        let keyID = storageID(for: contentIdentifier)
        let url = try keyDirectory(create: false)
            .appendingPathComponent(keyFileName(entityID: entityID, keyID: keyID))
        return try Data(contentsOf: url)
    }

    func hasKey(entityID: String, contentIdentifier: Data) -> Bool {
        guard let directory = try? keyDirectory(create: false) else {
            return false
        }
        let keyID = storageID(for: contentIdentifier)
        return fileManager.fileExists(
            atPath: directory
                .appendingPathComponent(keyFileName(entityID: entityID, keyID: keyID))
                .path
        )
    }

    func hasAnyKey(entityID: String) -> Bool {
        guard let directory = try? keyDirectory(create: false) else {
            return false
        }

        return storedKeyIDs(entityID: entityID).contains {
            fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent(keyFileName(entityID: entityID, keyID: $0))
                    .path
            )
        }
    }

    func deleteKeys(entityID: String) throws {
        if let directory = try? keyDirectory(create: false) {
            for keyID in storedKeyIDs(entityID: entityID) {
                let url = directory.appendingPathComponent(
                    keyFileName(entityID: entityID, keyID: keyID)
                )
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
        defaults.removeObject(forKey: keyIDsKey(entityID: entityID))
    }

    private func keyDirectory(create: Bool) throws -> URL {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            root = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
        }

        var directory = root.appendingPathComponent("FairPlayKeys", isDirectory: true)
        if create {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try directory.setResourceValues(resourceValues)
        }
        return directory
    }

    private func storedKeyIDs(entityID: String) -> [String] {
        defaults.stringArray(forKey: keyIDsKey(entityID: entityID)) ?? []
    }

    private func keyFileName(entityID: String, keyID: String) -> String {
        "\(storageID(for: Data(entityID.utf8)))-\(keyID).persistableContentKey"
    }

    private func keyIDsKey(entityID: String) -> String {
        "fairPlayKeys.\(storageID(for: Data(entityID.utf8)))"
    }

    private func storageID(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
