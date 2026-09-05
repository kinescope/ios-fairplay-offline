import AVKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "Commercial-DRM video ID",
                        text: Binding(
                            get: { model.videoID },
                            set: { model.updateVideoID($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!model.canEditVideoID)
                }

                playerView

                Text(model.state.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let progress = model.state.progress {
                    ProgressView(value: progress) {
                        Text("Downloading")
                    } currentValueLabel: {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                    }
                }

                Button {
                    Task { await model.startDownload() }
                } label: {
                    Label("Download for Offline", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canDownload)

                Button {
                    model.playOffline()
                } label: {
                    Label("Play Offline", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canPlay)

                Button(role: .destructive) {
                    Task { await model.deleteDownload() }
                } label: {
                    Label("Delete Download and Key", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canDelete)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("FairPlay Offline")
        }
    }

    @ViewBuilder
    private var playerView: some View {
        if let player = model.player {
            VideoPlayer(player: player)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            ContentUnavailableView(
                "Video Is Not Playing",
                systemImage: "play.rectangle",
                description: Text("After downloading, enable Airplane Mode and tap “Play Offline”.")
            )
            .frame(height: 230)
        }
    }
}
