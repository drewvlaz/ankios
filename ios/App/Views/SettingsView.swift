import AnkiKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogin = false
    @State private var checkResult: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync") {
                    if let creds = model.credentials {
                        LabeledContent("Account", value: creds.username)
                        LabeledContent("Server", value: creds.endpoint ?? "AnkiWeb")
                        if let last = model.lastSync {
                            LabeledContent("Last sync") {
                                Text(last, style: .relative) + Text(" ago")
                            }
                        }
                        Button("Sync Now") { Task { await model.sync() } }
                            .disabled(model.isSyncing)
                        Button("Log Out", role: .destructive) { model.logout() }
                    } else {
                        Button("Log In…") { showingLogin = true }
                    }
                }

                Section {
                    Button {
                        Task { await checkDatabase() }
                    } label: {
                        HStack {
                            Text("Check Database")
                            if isChecking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isChecking || model.isSyncing)
                    if let checkResult {
                        Text(checkResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Maintenance")
                }

                Section("About") {
                    LabeledContent("Anki backend", value: AnkiBackend.buildHash)
                    LabeledContent("Collection") {
                        Text(model.paths.folder.path).font(.caption2).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLogin) { LoginView() }
        }
    }

    private func checkDatabase() async {
        guard let backend = model.backend else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let problems = try await backend.checkDatabase().problems
            checkResult = problems.isEmpty ? "No problems found." : problems.joined(separator: "\n")
            await model.refreshDecks()
        } catch {
            checkResult = error.localizedDescription
        }
    }
}
