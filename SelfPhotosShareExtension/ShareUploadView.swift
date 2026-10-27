import SwiftUI

struct ShareUploadView: View {
    @ObservedObject var model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .loading {
                    ProgressView("Preparing images…")
                } else {
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: model.cancel) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Upload to SelfPhotos (\(model.selectedCount))")
                            .font(.headline)
                        Text(model.serverLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: model.primaryAction) {
                        if model.isBusy {
                            ProgressView()
                        } else if case .queued = model.phase {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.selectedCount == 0)
                    .accessibilityLabel(toolbarActionAccessibilityLabel)
                }
            }
        }
        .task { await model.load() }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if case .failed(let message) = model.phase {
                    ContentUnavailableView(
                        "Unable to Upload",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message))
                        .padding(.top, 60)
                } else {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }

                    if case .queued(let count) = model.phase, count > 0 {
                        Label(
                            "\(count) item(s) will retry when SelfPhotos opens.",
                            systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(16)
        }
    }

    private var toolbarActionAccessibilityLabel: String {
        if model.phase == .loading {
            return String(localized: "Preparing images")
        }
        if case .uploading(let current, let total) = model.phase {
            return String(localized: "Uploading \(current) of \(total)")
        }
        if case .queued = model.phase {
            return String(localized: "Done")
        }
        return String(localized: "Upload")
    }

    private func itemRow(_ item: SharePreviewItem) -> some View {
        Button { model.toggle(item.id) } label: {
            HStack(spacing: 14) {
                Group {
                    if let thumbnail = item.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: item.uploadItem.contentType.hasPrefix("video/")
                              ? "video" : "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 72)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.uploadItem.filename)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(ByteCountFormatter.string(
                        fromByteCount: item.uploadItem.byteCount,
                        countStyle: .file))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditSelection)
    }
}
