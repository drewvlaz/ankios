import AnkiKit
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var endpoint = ""
    @State private var isWorking = false
    @State private var error: String?
    /// When set, offers to continue without an account (first-run only).
    var onSkip: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("AnkiWeb account")
                } footer: {
                    Text("On first login your collection is downloaded from the server. Your password is only used to obtain a sync key and is not stored.")
                }

                Section {
                    TextField("https://example.com/", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Self-hosted sync server (optional)")
                } footer: {
                    Text("Leave empty to use AnkiWeb.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Log In")
                            if isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isWorking)
                }

                if let onSkip {
                    Section {
                        Button("Continue Without Syncing", action: onSkip)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sync")
            .onAppear { endpoint = model.customEndpoint }
        }
    }

    private func submit() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        model.customEndpoint = endpoint
        do {
            try await model.login(username: username, password: password)
            password = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
