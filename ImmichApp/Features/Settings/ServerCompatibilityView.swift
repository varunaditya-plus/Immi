import SwiftUI

/// Diagnostics kontrak server yang bisa dibaca pengguna tanpa menebak dari
/// error endpoint lain. Data yang sama dipakai oleh gate sebelum login.
struct ServerCompatibilityView: View {
    @Environment(SessionManager.self) private var session
    @State private var phase: LoadingPhase<Void> = .idle

    var body: some View {
        List {
            statusSection
            capabilitiesSection
            if let error = phase.errorMessage {
                errorSection(error)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Server Compatibility")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(phase.isLoading)
                .accessibilityLabel("Refresh Compatibility")
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if let report = session.serverCompatibility {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.status.title)
                            .font(.body.weight(.medium))
                        Text(statusDetail(report))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: statusSymbol(report.status))
                        .foregroundStyle(statusTint(report.status))
                }

                LabeledContent("Server Version", value: report.version.displayName)
                LabeledContent(
                    "Supported Server Majors",
                    value: ServerCompatibilityPolicy.supportedRangeDescription)
                LabeledContent(
                    "App API Contract",
                    value: "v\(ServerCompatibilityPolicy.apiMajor)")
            } else if phase.isLoading {
                HStack {
                    ProgressView()
                    Text("Checking server…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("API Contract")
        } footer: {
            Text("Authentication is allowed only after the server version and capabilities pass this check.")
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        if let features = session.serverCompatibility?.features {
            Section("Server Capabilities") {
                ForEach(capabilities(features)) { capability in
                    HStack {
                        Label(capability.title, systemImage: capability.symbol)
                        Spacer()
                        Image(systemName: capability.enabled ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(capability.enabled ? Color.green : Color.secondary)
                            .accessibilityLabel(capability.enabled ? "Available" : "Unavailable")
                    }
                }
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label {
                Text(message)
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private func refresh() async {
        guard !phase.isLoading else { return }
        phase = .loading
        do {
            try await session.checkServerCompatibility()
            phase = .loaded(())
        } catch {
            phase = .failed(
                (error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func statusDetail(_ report: ServerCompatibilityReport) -> String {
        switch report.status {
        case .compatible:
            return String(localized: "This server uses the current supported API major.")
        case .compatibleLegacy:
            return String(localized: "This is the oldest supported server major. Updating the server is recommended.")
        case .serverUpgradeRequired:
            return String(localized: "Update Immich Server before signing in.")
        case .appUpgradeRequired:
            return String(localized: "Update this app before using this server.")
        }
    }

    private func statusSymbol(_ status: ServerCompatibilityStatus) -> String {
        switch status {
        case .compatible: "checkmark.shield.fill"
        case .compatibleLegacy: "exclamationmark.shield.fill"
        case .serverUpgradeRequired, .appUpgradeRequired: "xmark.shield.fill"
        }
    }

    private func statusTint(_ status: ServerCompatibilityStatus) -> Color {
        switch status {
        case .compatible: .green
        case .compatibleLegacy: .orange
        case .serverUpgradeRequired, .appUpgradeRequired: .red
        }
    }

    private struct Capability: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        let enabled: Bool
    }

    private func capabilities(_ value: ServerFeaturesDTO) -> [Capability] {
        [
            .init(id: "search", title: "Search", symbol: "magnifyingglass", enabled: value.search),
            .init(id: "smartSearch", title: "Smart Search", symbol: "sparkle.magnifyingglass", enabled: value.smartSearch),
            .init(id: "faces", title: "Facial Recognition", symbol: "person.crop.rectangle.stack", enabled: value.facialRecognition),
            .init(id: "oauth", title: "OAuth", symbol: "person.badge.key", enabled: value.oauth),
            .init(id: "password", title: "Password Login", symbol: "key", enabled: value.passwordLogin),
            .init(id: "map", title: "Map", symbol: "map", enabled: value.map),
            .init(id: "ocr", title: "OCR", symbol: "text.viewfinder", enabled: value.ocr),
            .init(id: "transcoding", title: "Realtime Transcoding", symbol: "play.rectangle", enabled: value.realtimeTranscoding),
            .init(id: "trash", title: "Trash", symbol: "trash", enabled: value.trash),
            .init(id: "duplicates", title: "Duplicate Detection", symbol: "square.on.square", enabled: value.duplicateDetection),
            .init(id: "email", title: "Email", symbol: "envelope", enabled: value.email),
            .init(id: "importFaces", title: "Face Import", symbol: "person.crop.circle.badge.plus", enabled: value.importFaces),
            .init(id: "geocoding", title: "Reverse Geocoding", symbol: "mappin.and.ellipse", enabled: value.reverseGeocoding),
            .init(id: "sidecar", title: "Sidecar Files", symbol: "doc.on.doc", enabled: value.sidecar),
            .init(id: "config", title: "Config File", symbol: "gearshape.2", enabled: value.configFile),
            .init(id: "oauthAuto", title: "OAuth Auto Launch", symbol: "arrow.up.forward.app", enabled: value.oauthAutoLaunch)
        ]
    }
}
