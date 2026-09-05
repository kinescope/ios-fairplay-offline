import Foundation
import XCTest
@testable import FairPlayOffline

@MainActor
final class KinescopeAPITests: XCTestCase {
    func testEmptyDRMObjectDecodesWithoutOfflineAsset() throws {
        let data = Data(
            """
            {
              "id": "entity",
              "hls_link": "https://example.com/master.m3u8",
              "drm": {}
            }
            """.utf8
        )

        let video = try KinescopeAPI().decodeVideo(from: data)

        XCTAssertEqual(video.entityID, "entity")
        XCTAssertNil(video.offlineAsset)
    }

    func testCommercialDRMMapsToPackageAsset() throws {
        let data = Data(
            """
            {
              "id": "entity",
              "hls_link": "https://example.com/master.m3u8",
              "drm": {
                "fairplay": {
                  "licenseUrl": "https://license.example.com/acquire",
                  "certificateUrl": "https://license.example.com/certificate"
                }
              }
            }
            """.utf8
        )

        let asset = try XCTUnwrap(
            KinescopeAPI().decodeVideo(from: data).offlineAsset
        )

        XCTAssertEqual(asset.entityID, "entity")
        XCTAssertEqual(asset.playlistURL.absoluteString, "https://example.com/master.m3u8")
        XCTAssertEqual(asset.licenseURL.absoluteString, "https://license.example.com/acquire")
        XCTAssertEqual(
            asset.certificateURL.absoluteString,
            "https://license.example.com/certificate"
        )
    }

    func testSelectedVideoIDAndEntityMappingsArePersisted() throws {
        let suiteName = "KinescopeAPITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KinescopeVideoStore(defaults: defaults)

        XCTAssertEqual(store.selectedVideoID(defaultValue: "default"), "default")

        store.saveSelectedVideoID("video-a")
        store.saveEntityID("entity-a", forVideoID: "video-a")
        store.saveEntityID("entity-b", forVideoID: "video-b")

        XCTAssertEqual(store.selectedVideoID(defaultValue: "default"), "video-a")
        XCTAssertEqual(store.entityID(forVideoID: "video-a"), "entity-a")
        XCTAssertEqual(store.entityID(forVideoID: "video-b"), "entity-b")

        store.clearEntityID(forVideoID: "video-a")
        XCTAssertNil(store.entityID(forVideoID: "video-a"))
        XCTAssertEqual(store.entityID(forVideoID: "video-b"), "entity-b")
    }
}
