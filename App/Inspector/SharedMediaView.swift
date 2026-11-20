import AppKit
import SwiftUI

/// The newest pictures and files of the chat: pictures as a grid, other files by name. A click
/// shows the message in the transcript.
struct SharedMediaView: View {
    let items: [SharedMediaItem]
    let onOpen: (SharedMediaItem) -> Void

    var body: some View {
        let pictures = items.filter(\.isImage)
        let files = items.filter { !$0.isImage }
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text(Copy.noSharedMedia)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
            }
            if !pictures.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: ControlHeight.Inspector.thumbnail), spacing: 6)
                    ], spacing: 6
                ) {
                    ForEach(pictures) { item in
                        Button {
                            onOpen(item)
                        } label: {
                            Thumbnail(item: item)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(item.fileName)
                        .accessibilityLabel(item.fileName)
                    }
                }
            }
            ForEach(files) { item in
                Button {
                    onOpen(item)
                } label: {
                    Label(item.fileName, systemImage: "doc")
                        .font(.appBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shared-media")
    }
}

/// A picture's thumbnail, decoded off the main thread; a symbol until then, or when the file
/// is not here.
private struct Thumbnail: View {
    let item: SharedMediaItem
    @State private var image: CGImage?

    var body: some View {
        let size = ControlHeight.Inspector.thumbnail
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.appTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: item.id) {
            guard let file = item.file else { return }
            image = await SharedMedia.thumbnail(of: file, pixels: Int(size * 2))
        }
    }
}
