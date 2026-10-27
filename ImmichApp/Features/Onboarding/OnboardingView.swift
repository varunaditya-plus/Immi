import SwiftUI

/// Login dua tahap: server dibuktikan lebih dulu, kredensial baru diminta
/// setelah endpoint publik, versi, dan capability-nya lolos pemeriksaan.
struct OnboardingView: View {
    @Environment(SessionManager.self) private var session
    @State private var vm: OnboardingViewModel?
    @State private var showsCredentials = false
    @State private var errorEvent: ErrorEvent?

    var body: some View {
        Group {
            if let vm {
                flow(vm)
            } else {
                Color.clear.onAppear { vm = OnboardingViewModel(session: session) }
            }
        }
    }

    private func flow(_ vm: OnboardingViewModel) -> some View {
        NavigationStack {
            serverPage(vm)
                .navigationDestination(isPresented: $showsCredentials) {
                    credentialsPage(vm)
                }
        }
        .errorToast($errorEvent)
        .onChange(of: showsCredentials) { _, isPresented in
            if !isPresented { vm.prepareToEditServer() }
        }
    }

    // MARK: - Tahap server

    private func serverPage(_ vm: OnboardingViewModel) -> some View {
        @Bindable var vm = vm

        return loginScroll {
            masthead(
                title: "SelfPhotos",
                subtitle: "Connect to your Immich server.")

            if let message = vm.sessionErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("sessionErrorMessage")
            }

            field("Server") {
                TextField("http://your-server-ip:port", text: $vm.serverText)
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { connect(vm) }
            }

            Button { connect(vm) } label: {
                buttonLabel("Continue", isLoading: vm.phase.isLoading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!vm.canConnect || vm.phase.isLoading)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect(_ vm: OnboardingViewModel) {
        Task {
            guard await vm.connectToServer() else {
                presentCurrentError(from: vm)
                return
            }
            showsCredentials = true
        }
    }

    // MARK: - Tahap kredensial

    private func credentialsPage(_ vm: OnboardingViewModel) -> some View {
        @Bindable var vm = vm

        return loginScroll {
            masthead(
                title: "Sign In",
                subtitle: "Sign in with your Immich account.",
                logoSize: 48)

            if vm.features?.passwordLogin == true {
                field("Email") {
                    TextField("you@example.com", text: $vm.email)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                }

                field("Password") {
                    SecureField("Required", text: $vm.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { signIn(vm) }
                }

                if vm.features?.oauth == true {
                    Button { signIn(vm) } label: {
                        buttonLabel("Sign In", isLoading: vm.phase.isLoading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!vm.canSubmit || vm.phase.isLoading)
                } else {
                    Button { signIn(vm) } label: {
                        buttonLabel("Sign In", isLoading: vm.phase.isLoading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!vm.canSubmit || vm.phase.isLoading)
                }
            }

            if vm.features?.oauth == true {
                Button { signInWithOIDC(vm) } label: {
                    serverButtonLabel(vm.oauthButtonText, isLoading: vm.phase.isLoading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!vm.canSignInWithOIDC || vm.phase.isLoading)
            }
        }
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn(_ vm: OnboardingViewModel) {
        Task {
            guard await vm.signIn() else {
                presentCurrentError(from: vm)
                return
            }
        }
    }

    private func signInWithOIDC(_ vm: OnboardingViewModel) {
        Task {
            guard await vm.signInWithOIDC() else {
                presentCurrentError(from: vm)
                return
            }
        }
    }

    // MARK: - Komponen

    private func loginScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func masthead(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        logoSize: CGFloat = 58
    ) -> some View {
        VStack(spacing: 10) {
            SelfPhotosTortoiseLogo(size: logoSize)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 8)
    }

    private func field<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        }
    }

    private func buttonLabel(
        _ title: LocalizedStringKey,
        isLoading: Bool
    ) -> some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }

    private func serverButtonLabel(_ title: String, isLoading: Bool) -> some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }

    private func presentCurrentError(from vm: OnboardingViewModel) {
        guard let message = vm.phase.errorMessage else { return }
        // ErrorEvent beridentitas baru membuat kegagalan berulang tetap
        // memunculkan toast dan haptic baru walaupun teksnya sama.
        errorEvent = ErrorEvent(message)
    }
}

#Preview {
    OnboardingView()
        .environment(SessionManager())
}
