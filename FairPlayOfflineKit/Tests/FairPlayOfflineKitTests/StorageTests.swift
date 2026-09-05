import AVFoundation
import Foundation
import XCTest
@testable import FairPlayOfflineKit

@MainActor
final class StorageTests: XCTestCase {
    func testPersistentKeysAreStoredByContentIdentifier() throws {
        let context = try makeContext()
        defer { context.cleanUp() }

        let store = PersistentKeyStore(
            defaults: context.defaults,
            baseDirectory: context.directory
        )
        let firstID = Data("skd://first-key".utf8)
        let secondID = Data("skd://second-key".utf8)
        let firstKey = Data("first-persistable-key".utf8)
        let secondKey = Data("second-persistable-key".utf8)

        try store.saveKey(firstKey, entityID: "entity", contentIdentifier: firstID)
        try store.saveKey(secondKey, entityID: "entity", contentIdentifier: secondID)

        XCTAssertEqual(
            try store.loadKey(entityID: "entity", contentIdentifier: firstID),
            firstKey
        )
        XCTAssertEqual(
            try store.loadKey(entityID: "entity", contentIdentifier: secondID),
            secondKey
        )
        XCTAssertTrue(store.hasAnyKey(entityID: "entity"))

        try store.deleteKeys(entityID: "entity")
        XCTAssertFalse(store.hasAnyKey(entityID: "entity"))
    }

    func testDownloadMetadataTransitionsFromPendingToCompleted() throws {
        let context = try makeContext()
        defer { context.cleanUp() }

        let assetURL = context.directory.appendingPathComponent("asset.movpkg")
        try FileManager.default.createDirectory(
            at: assetURL,
            withIntermediateDirectories: true
        )
        let store = DownloadStore(defaults: context.defaults)

        store.savePendingAssetLocation(assetURL, for: "entity")
        store.markStarted(entityID: "entity")
        XCTAssertFalse(store.isCompleted(entityID: "entity"))

        try store.finalizeAssetLocation(for: "entity")
        store.markCompleted(entityID: "entity")
        XCTAssertEqual(
            store.assetURL(for: "entity")?.lastPathComponent,
            assetURL.lastPathComponent
        )
        XCTAssertTrue(store.isCompleted(entityID: "entity"))

        store.removeMetadata(entityID: "entity")
        XCTAssertNil(store.assetURL(for: "entity"))
        XCTAssertFalse(store.isCompleted(entityID: "entity"))
    }

    func testStartingSecondPlaybackPausesExistingPlayer() throws {
        let context = try makeContext()
        defer { context.cleanUp() }

        let assetURL = context.directory.appendingPathComponent("asset.movpkg")
        try FileManager.default.createDirectory(
            at: assetURL,
            withIntermediateDirectories: true
        )
        let downloadStore = DownloadStore(defaults: context.defaults)
        downloadStore.savePendingAssetLocation(assetURL, for: "entity")
        try downloadStore.finalizeAssetLocation(for: "entity")
        downloadStore.markCompleted(entityID: "entity")

        let keyStore = PersistentKeyStore(
            defaults: context.defaults,
            baseDirectory: context.directory
        )
        try keyStore.saveKey(
            Data("persistable-key".utf8),
            entityID: "entity",
            contentIdentifier: Data("content-id".utf8)
        )

        var pausedPlayers: [AVPlayer] = []
        let offlinePlayer = OfflinePlayer(
            downloadStore: downloadStore,
            keyStore: keyStore,
            makePlayer: { _ in AVPlayer() },
            pausePlayer: { pausedPlayers.append($0) },
            makeKeySession: { _, _, _ in NSObject() }
        )

        try offlinePlayer.play(entityID: "entity")
        let firstPlayer = try XCTUnwrap(offlinePlayer.player)
        try offlinePlayer.play(entityID: "entity")

        XCTAssertEqual(pausedPlayers.count, 1)
        XCTAssertTrue(pausedPlayers[0] === firstPlayer)
    }

    private func makeContext() throws -> TestContext {
        let identifier = "StorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TestContext(
            identifier: identifier,
            defaults: defaults,
            directory: directory
        )
    }
}

private struct TestContext {
    let identifier: String
    let defaults: UserDefaults
    let directory: URL

    func cleanUp() {
        defaults.removePersistentDomain(forName: identifier)
        try? FileManager.default.removeItem(at: directory)
    }
}
