import SwiftUI

struct AuthenticationFlowView: View {
    @ObservedObject private var appServices: AppServices
    @StateObject private var viewModel: AuthViewModel

    init(appServices: AppServices) {
        _appServices = ObservedObject(initialValue: appServices)
        _viewModel = StateObject(wrappedValue: AuthViewModel(appServices: appServices))
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pingrrr")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("International messaging without friction")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Mode", selection: $viewModel.mode) {
                ForEach(AuthViewModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 16) {
                TextField("Email", text: $viewModel.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .tint(.blue)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if viewModel.mode == .signUp {
                    TextField("Display name", text: $viewModel.displayName)
                        .textContentType(.name)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    Text(viewModel.mode.actionTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(viewModel.isLoading)

            Spacer()

            Button(action: viewModel.toggleMode) {
                Text(viewModel.mode == .signIn ? "Need an account? Sign up" : "Have an account? Log in")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }

    private func submit() {
        Task {
            await viewModel.submit()
        }
    }
}

