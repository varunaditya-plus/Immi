import SwiftUI
import UIKit

/// Status PIN sesi, dari `GET /auth/status`.
struct AuthStatusDTO: Decodable {
    /// Apakah pengguna SUDAH punya PIN. Kalau belum, ia harus membuatnya dulu.
    let pinCode: Bool
    /// Apakah sesi ini sudah dibuka dan boleh melihat isi Locked Folder.
    let isElevated: Bool
}

/// Aksi PIN untuk Locked Folder.
@MainActor
class PinRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func status() async throws -> AuthStatusDTO {
        try await api.send(.init(path: "/auth/status"))
    }

    /// Membuka sesi supaya isi Locked Folder bisa diambil.
    ///
    /// Elevasinya melekat pada SESI, bukan pada permintaan — karena itu tidak
    /// ada yang perlu disimpan di sisi klien setelah ini berhasil.
    func unlock(pin: String) async throws {
        do {
            try await api.sendVoid(
                .json("/auth/session/unlock", method: .post, body: ["pinCode": pin]))
        } catch APIError.server(status: 403, message: _) {
            throw PinUnlockError.incorrectPIN
        }
    }

    func lock() async throws {
        try await api.sendVoid(.init(path: "/auth/session/lock", method: .post))
    }

    /// Membuat PIN pertama kali.
    func createPin(_ pin: String) async throws {
        try await api.sendVoid(
            .json("/auth/pin-code", method: .post, body: ["pinCode": pin]))
    }
}

enum PinUnlockError: LocalizedError {
    case incorrectPIN

    var errorDescription: String? {
        String(localized: "Incorrect PIN. Try again.")
    }
}

/// Local access is revoked before waiting for any server request. PIN and lock
/// requests run in order so a late unlock cannot undo the background relock.
@MainActor
@Observable
final class LockedFolderAccess {
    private let repo: PinRepository
    private(set) var visitID = UUID()
    private var pendingOperation: Task<AuthStatusDTO?, Error>?
    private var pendingOperationID: UUID?
    private var ignoresSheetDismissal = false

    private(set) var status: AuthStatusDTO?
    private(set) var isChecking = true
    private(set) var isVerifying = false
    private(set) var isActive = true
    private(set) var errorMessage: String?
    var showPinSheet = false

    var isUnlocked: Bool { isActive && status?.isElevated == true }

    init(repo: PinRepository) {
        self.repo = repo
    }

    func enter() async {
        guard isActive else { return }
        visitID = UUID()
        let expectedVisit = visitID
        status = nil
        isChecking = true
        errorMessage = nil
        let repo = repo
        let operation = enqueue {
            try await repo.lock()
            let status = try await repo.status()
            // Every visit requires a new PIN, even if the server still reports
            // elevation from another request using the same session.
            return AuthStatusDTO(pinCode: status.pinCode, isElevated: false)
        }
        do {
            let fresh = try await operation.value
            guard isActive, visitID == expectedVisit else { return }
            status = fresh
            isChecking = false
            showPinSheet = true
        } catch {
            guard isActive, visitID == expectedVisit else { return }
            isChecking = false
            errorMessage = error.localizedDescription
        }
    }

    func presentPIN() async {
        guard isActive else { return }
        if status != nil {
            showPinSheet = true
        } else {
            await enter()
        }
    }

    func unlock(pin: String, visit: UUID) async throws {
        guard isActive, visitID == visit, !isChecking, !isVerifying, let status else {
            throw CancellationError()
        }
        let expectedVisit = visitID
        isVerifying = true
        defer {
            if visitID == expectedVisit { isVerifying = false }
        }
        let repo = repo
        let operation = enqueue { [weak self] in
            if !status.pinCode {
                try await repo.createPin(pin)
                guard let self, self.isActive, self.visitID == expectedVisit else {
                    throw CancellationError()
                }
                // A failed unlock must not make Retry create an already-confirmed PIN again.
                self.status = AuthStatusDTO(pinCode: true, isElevated: false)
            }
            try await repo.unlock(pin: pin)
            return nil
        }
        _ = try await operation.value
        guard isActive, visitID == expectedVisit else { throw CancellationError() }
        self.status = AuthStatusDTO(pinCode: true, isElevated: true)
        showPinSheet = false
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        visitID = UUID()
        status = nil
        isChecking = false
        isVerifying = false
        errorMessage = nil
        ignoresSheetDismissal = showPinSheet
        showPinSheet = false
        let repo = repo
        // This runs after an outstanding unlock, including one which completes
        // after the app is already in the background.
        _ = enqueue {
            try await repo.lock()
            return nil
        }
    }

    func activate() async {
        guard !isActive else { return }
        isActive = true
        await enter()
    }

    func shouldLeaveAfterSheetDismissal() -> Bool {
        if ignoresSheetDismissal {
            ignoresSheetDismissal = false
            return false
        }
        return isActive && !isUnlocked && !isVerifying && !isChecking
    }

    private func enqueue(
        _ operation: @escaping @MainActor () async throws -> AuthStatusDTO?
    ) -> Task<AuthStatusDTO?, Error> {
        let previous = pendingOperation
        let id = UUID()
        pendingOperationID = id
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            defer {
                if self?.pendingOperationID == id { self?.pendingOperation = nil }
            }
            return try await operation()
        }
        pendingOperation = task
        return task
    }
}

/// The collection is removed when access is revoked, including its loaded data.
struct LockedFolderView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: LockedFolderAccess?

    var body: some View {
        content
            .navigationTitle("Locked Folder")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(
                get: { access?.showPinSheet == true },
                set: { access?.showPinSheet = $0 }), onDismiss: leaveIfStillLocked) {
                    pinSheet
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await access?.activate() }
                } else {
                    access?.deactivate()
                }
            }
            .task {
                guard access == nil else { return }
                let access = LockedFolderAccess(repo: PinRepository(api: APIClient(session: session)))
                self.access = access
                if scenePhase == .active {
                    await access.enter()
                } else {
                    access.deactivate()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if access == nil || access?.isChecking == true {
            ProgressView()
        } else if access?.isUnlocked == true {
            AssetCollectionView(
                title: "Locked Folder",
                request: SearchRequestDTO(size: 200, visibility: "locked"),
                layout: .monthly)
                .background {
                    LockedContentPrivacyGuard(onDeactivate: { access?.deactivate() })
                        .frame(width: 0, height: 0)
                }
        } else {
            lockedPlaceholder
        }
    }

    private var lockedPlaceholder: some View {
        ContentUnavailableView {
            Label("Locked", systemImage: "lock.fill")
        } description: {
            if let message = access?.errorMessage {
                Text(message)
            } else {
                Text("Enter your PIN to see the photos in this folder.")
            }
        } actions: {
            Button("Enter PIN") { Task { await access?.presentPIN() } }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var pinSheet: some View {
        if let access {
            let visit = access.visitID
            PinPromptSheet(
                needsSetup: access.status?.pinCode == false,
                model: PinPromptModel(unlock: { try await access.unlock(pin: $0, visit: visit) }))
                .id(visit)
                .interactiveDismissDisabled(access.isVerifying)
                .presentationDetents([.height(420), .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func leaveIfStillLocked() {
        if access?.shouldLeaveAfterSheetDismissal() == true { dismiss() }
    }
}

enum PinCodeContract {
    static let minimumLength = 4
    static let maximumLength = 6

    static func sanitized(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(maximumLength))
    }

    static func isValid(_ value: String) -> Bool {
        (minimumLength...maximumLength).contains(value.count)
            && value.allSatisfy(\.isNumber)
    }
}

@MainActor
@Observable
final class PinPromptModel {
    private let unlock: (String) async throws -> Void
    private var operationID: UUID?
    private var isActive = true
    private(set) var pin = ""
    private(set) var isWorking = false
    private(set) var failureCount = 0
    private(set) var errorMessage: String?

    init(unlock: @escaping (String) async throws -> Void) {
        self.unlock = unlock
    }

    func updatePIN(_ value: String) {
        guard !isWorking else { return }
        let sanitized = PinCodeContract.sanitized(value)
        guard pin != sanitized else { return }
        pin = sanitized
        errorMessage = nil
    }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        operationID = nil
        isWorking = false
        pin = ""
        errorMessage = nil
    }

    func submit() async {
        guard isActive, !isWorking, PinCodeContract.isValid(pin) else { return }
        let operation = UUID()
        operationID = operation
        isWorking = true
        errorMessage = nil
        defer {
            if operationID == operation {
                isWorking = false
                operationID = nil
            }
        }
        do {
            try await unlock(pin)
            guard isActive, operationID == operation, !Task.isCancelled else { return }
            pin = ""
        } catch {
            guard isActive, operationID == operation, !Task.isCancelled else { return }
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            errorMessage = error.localizedDescription
            pin = ""
            withAnimation(.linear(duration: shakeDuration)) { failureCount += 1 }
        }
    }
}

/// Sheet masukan PIN sesuai kontrak Immich: empat sampai enam digit.
///
/// Enam digit tetap terkirim otomatis seperti perilaku lama. Untuk PIN empat
/// atau lima digit tersedia tombol Continue karena panjang akhirnya tidak bisa
/// diketahui hanya dari ketikan.
struct PinPromptSheet: View {
    /// true kalau pengguna belum pernah membuat PIN sama sekali.
    let needsSetup: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: PinPromptModel
    @FocusState private var isFocused: Bool

    init(needsSetup: Bool, model: PinPromptModel) {
        self.needsSetup = needsSetup
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)

                Text(needsSetup ? "Create a PIN" : "Enter your PIN")
                    .font(.title3.bold())

                Text(needsSetup
                     ? "This PIN protects the photos in your locked folder."
                     : "Your locked folder is protected by a PIN.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Text("Use 4 to 6 digits.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                pinField

                if let message = model.errorMessage {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .accessibilityIdentifier("pinFailureMessage")
                }

                Button {
                    Task { await model.submit() }
                } label: {
                    Group {
                        if model.isWorking {
                            ProgressView()
                        } else {
                            Text("Continue")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .disabled(!PinCodeContract.isValid(model.pin) || model.isWorking)

            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sensoryFeedback(.error, trigger: model.failureCount)
        .onAppear {
            model.activate()
            isFocused = true
        }
        .onDisappear { model.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.activate() }
            else { model.deactivate() }
        }
        .onChange(of: model.errorMessage) { _, message in
            if let message, scenePhase == .active {
                isFocused = true
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    /// Lingkaran-lingkaran di atas satu `TextField` tak terlihat.
    ///
    /// Lebih sederhana daripada papan angka sendiri, dan tetap mendapat papan
    /// ketik angka serta autofill dari sistem.
    private var pinField: some View {
        ZStack {
            TextField("", text: Binding(get: { model.pin }, set: { model.updatePIN($0) }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.01)
                .disabled(model.isWorking)
                .accessibilityLabel(needsSetup ? "Create a PIN" : "Enter your PIN")
                .onChange(of: model.pin) { _, value in
                    if value.count == PinCodeContract.maximumLength {
                        Task { await model.submit() }
                    }
                }

            HStack(spacing: 16) {
                ForEach(0..<PinCodeContract.maximumLength, id: \.self) { index in
                    dot(filled: index < model.pin.count)
                }
            }
            .allowsHitTesting(false)
            .modifier(ShakeEffect(animatableData: CGFloat(model.failureCount)))
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private func dot(filled: Bool) -> some View {
        Circle()
            .strokeBorder(.secondary, lineWidth: 1.5)
            .background(Circle().fill(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
            .frame(width: 16, height: 16)
            .animation(.easeOut(duration: 0.12), value: filled)
    }
}

private let shakeDuration: Double = 0.4

/// Goyangan mendatar untuk PIN yang ditolak.
///
/// `GeometryEffect`, bukan `offset` yang dianimasikan: nilainya bisa dijalankan
/// sebagai satu animasi utuh dari 0 ke 1 sehingga bolak-baliknya mulus, alih-alih
/// serangkaian animasi pendek yang saling menyusul.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 8
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * shakes * 2),
            y: 0))
    }
}
