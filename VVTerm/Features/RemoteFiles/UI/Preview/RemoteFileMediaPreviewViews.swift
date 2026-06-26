import AVKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PresentedMediaPreview: Identifiable {
    let title: String
    let kind: RemoteFilePreviewKind
    let url: URL

    var id: String { url.absoluteString }
}

struct RemoteFileImagePreview: View {
    let url: URL
    let backgroundColor: Color

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
                    .padding(12)
                    .background(previewBackground)
            } else {
                RemoteFileEmptyState(
                    icon: "photo",
                    title: String(localized: "Preview Unavailable"),
                    message: String(localized: "The image data could not be rendered.")
                )
            }
        }
    }

    #if os(macOS)
    private var image: Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }
    #else
    private var image: Image? {
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }
    #endif

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(backgroundColor)
    }
}

struct RemoteFileVideoPreview: View {
    let url: URL
    let backgroundColor: Color

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .task(id: url) {
                player?.pause()
                player = AVPlayer(url: url)
            }
            .onDisappear {
                player?.pause()
            }
    }
}

struct RemoteFileExpandedMediaPreview: View {
    let item: PresentedMediaPreview

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        #if os(iOS)
        NavigationStack {
            mediaContent
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            dismiss()
                        }
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(String(localized: "Close")) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            mediaContent
        }
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var mediaContent: some View {
        ZStack {
            Color.black.opacity(0.96)
                .ignoresSafeArea()

            switch item.kind {
            case .image:
                imageContent
            case .video:
                videoContent
            case .text, .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: item.url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #else
        if let image = UIImage(contentsOfFile: item.url.path) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #endif
    }

    private var videoContent: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.url) {
                player?.pause()
                player = AVPlayer(url: item.url)
            }
            .onDisappear {
                player?.pause()
            }
    }
}
