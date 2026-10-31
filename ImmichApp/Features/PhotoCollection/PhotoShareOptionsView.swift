import SwiftUI

struct PhotoShareOptionsView: View {
    @State var options: PhotoExportOptions
    let onDone: (PhotoExportOptions) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Include") {
                    Toggle("Location", isOn: $options.includeLocation)
                }
                Section {
                    ForEach(PhotoExportOptions.Format.allCases, id: \.self) { format in
                        Button {
                            options.format = format
                        } label: {
                            HStack {
                                Text(Self.title(for: format)).foregroundStyle(Color.primary)
                                Spacer()
                                if options.format == format {
                                    Image(systemName: "checkmark").fontWeight(.semibold)
                                }
                            }
                        }
                        .accessibilityAddTraits(options.format == format ? .isSelected : [])
                    }
                } header: {
                    Text("Format")
                } footer: {
                    Text("Automatic lets the destination choose a format. Current keeps the file format. Most Compatible uses JPEG, PNG, or H.264.")
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { onDone(options) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    static func title(for format: PhotoExportOptions.Format) -> String {
        switch format {
        case .automatic: String(localized: "Automatic")
        case .current: String(localized: "Current")
        case .mostCompatible: String(localized: "Most Compatible")
        }
    }
}
