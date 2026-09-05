# FairPlay Offline for iOS

A minimal SwiftUI + AVFoundation example that:

1. reads `hls_link` and `drm.fairplay` from `https://kinescope.io/{video_id}.json?sdk`;
2. downloads HLS with `AVAssetDownloadURLSession`;
3. obtains and stores a persistent FairPlay key;
4. plays the local `.movpkg` without an internet connection.

The example targets iOS 17 to keep the code concise with SwiftUI and `async/await`. The core persistent FairPlay APIs are available starting with iOS 11.2.

## Quick Start

Requirements:

- Xcode 15 or newer;
- a physical iPhone or iPad, because FairPlay Streaming cannot be tested in the simulator;
- a `video_id` whose database DRM type is `commercial`.

1. Generate and open the project:

   ```bash
   xcodegen generate
   open FairPlayOffline.xcodeproj
   ```

   `FairPlayOffline.xcodeproj` is already included. XcodeGen is only required after changing `project.yml`.

2. Select a development team and a unique bundle identifier, then run the app on a physical device.

3. Enter a commercial-DRM video ID in the app. The most recently entered value is restored on the next launch.

4. Tap **Download for Offline** and wait for the **Ready** status.

5. Enable Airplane Mode, keep Wi-Fi disabled, and tap **Play Offline**.

## File Responsibilities

- `FairPlayOfflineKit/` — a local Swift Package containing all AVFoundation, license, download, key-storage, and offline-player logic.
- `FairPlayAsset.swift` — the package input model; it is independent of Kinescope JSON.
- `FairPlayOfflineClient.swift` — the package's public download/play/delete API.
- `FairPlayOfflineKit/Sources/` — internal license, key-session, storage, download, and player implementations.
- `FairPlayOfflineKit/Tests/` — package storage and multi-key tests.
- `FairPlayOffline/KinescopeAPI.swift` — decodes `.json?sdk` and maps it to `FairPlayAsset`.
- `FairPlayOffline/KinescopeVideoStore.swift` — maps the public Kinescope `video_id` to its internal `entityID`.
- `FairPlayOffline/AppModel.swift` — connects the API, package client, and UI state.
- `FairPlayOffline/ContentView.swift` — provides the demonstration UI.
- `FairPlayOfflineTests/` — verifies Kinescope DRM decoding and package-model mapping.

## Persistent FairPlay Flow

```text
AVFoundation -> application: FairPlay certificate request
application -> license server: SPC (base64)
license server -> application: CKC (base64)
application: CKC -> persistableContentKey -> file

offline:
AVFoundation -> application: key request
application -> AVFoundation: saved persistableContentKey
```

During download, `ContentKeyManager` converts a regular `AVContentKeyRequest` into an `AVPersistableContentKeyRequest`:

1. the DER certificate is downloaded;
2. `makeStreamingContentKeyRequestData` creates the SPC;
3. the SPC is sent as JSON to `licenseUrl`;
4. the CKC is converted with `persistableContentKey(fromKeyVendorResponse:)`;
5. the key is written atomically to `Library/Application Support/FairPlayKeys`.

Each key filename is derived from SHA-256 hashes of `entityID` and the FairPlay content identifier. This prevents API data from becoming an arbitrary filesystem path and supports assets that use multiple or rotated content keys.

Offline playback does not use the certificate or license server. AVFoundation receives the previously stored key from disk.

## License API

Certificate:

```http
GET /v2/vod/{entity_id}/certificate/fairplay
```

The response is a binary DER-encoded X.509 certificate.

License:

```http
POST /v2/vod/{entity_id}/acquire/fairplay
Content-Type: application/json

{"spc":"BASE64"}
```

Response:

```json
{"ckc":"BASE64"}
```

## Why `drm: {}` Is Empty

This is the expected current behavior for non-commercial videos.

The `play` service creates the `drm` object when the media has an `EncryptKey`, but it only provides FairPlay and Widevine fields for `media.CommercialDrm` (`"commercial"`). For `"free"` and `"aes-128"`, the public JSON therefore contains:

```json
{"drm": {}}
```

Having an `EncryptKey` does not by itself mean that FairPlay URLs will be returned. A commercial-DRM video should return:

```json
{
  "drm": {
    "fairplay": {
      "licenseUrl": "https://license.kinescope.io/v2/vod/{entity_id}/acquire/fairplay",
      "certificateUrl": "https://license.kinescope.io/v2/vod/{entity_id}/certificate/fairplay"
    },
    "widevine": {
      "licenseUrl": "https://license.kinescope.io/v2/vod/{entity_id}/acquire/widevine"
    }
  }
}
```

The example handles `{}` without crashing and displays an actionable commercial-DRM error.

## Integrating into an Existing App

1. Add the local `FairPlayOfflineKit` package to the application target.
2. Convert provider-specific metadata to `FairPlayAsset`.
3. Keep one long-lived `FairPlayOfflineClient`.
4. Observe `onDownloadEvent` for progress, key, completion, and error events.
5. Use `download(_:)`, `play(entityID:)`, and `deleteDownload(entityID:)`; the package retains all required AVFoundation objects internally.
6. Store the Kinescope `entityID` separately because the public `video_id` and internal ID may differ.

```swift
let client = FairPlayOfflineClient()
client.onDownloadEvent = { event in
    // Update application state.
}

try await client.download(asset)
try client.play(entityID: asset.entityID)
```

## Download Lifecycle and State

- `AVContentKeySession` is created and receives its key recipient before `AVAssetDownloadURLSession`. Reversing this order may cause `AVErrorOperationNotAllowed` (`-11862`).
- `willDownloadTo` initially stores a URL string because the `.movpkg` does not exist yet. After successful completion, the URL is replaced with a persistent bookmark.
- A separate completion marker is stored only after successful `didCompleteWithError`.
- Before marking the download complete, the manager verifies that both the `.movpkg` and persistent key exist.
- Downloading an already complete video is rejected. Delete the existing download first.
- Deleting an active download cancels its task before removing the `.movpkg`, key, and metadata.
- This educational app supports one active download. A background `URLSession` lets it continue while the process remains managed by iOS, but the sample deliberately omits relaunch restoration. A production app must recreate every `AVContentKeySession` before reconnecting its background download session.

## FAQ

### What happens when a subscription expires?

An already issued indefinite persistent key continues to work offline. The app cannot learn that the subscription expired without a network connection. Enforcing this business rule requires a rental/expiration policy in the license or an online check before playback.

### How can a stored key be revoked?

An indefinite key cannot be reliably revoked while the device remains offline. The server can reject new licenses, and the app can delete its local key after an online synchronization. Use a time-limited offline license when guaranteed expiration is required.

### Where should device limits be enforced?

The license server should enforce them while issuing CKC by identifying clients or devices, tracking active licenses, and rejecting additional activations. This example does not generate its own device identifier.

### What does `contentKeyPersisted = 0x3df2d9fb` mean?

It identifies a persistent content key that may be stored across playback sessions. The current server implementation stores it indefinitely.

### How can offline playback be time-limited?

The `ContentKeyDuration` TLLV is included in CKC when the SPC contains `tagMediaPlaybackState`. AVFoundation provides the required state when using `AVContentKeySession`. `FetchContentKeyDuration` currently returns `0`, so no rental limit is applied. Supporting expiration requires server changes and testing of renewal and expired-lease scenarios.

## Demo Limitations

- The sample supports one active download and does not restore an unfinished task after process termination.
- The persistent key is stored as a file protected by the application container. Production apps should define their own iOS Data Protection, backup, and deletion policies.
- End-to-end DRM testing requires a real commercial-DRM video and a physical device.
