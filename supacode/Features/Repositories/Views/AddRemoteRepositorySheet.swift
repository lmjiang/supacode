import SupacodeSettingsShared
import SwiftUI

/// Form for adding a remote (SSH) repository to the sidebar. Local view state
/// only; on submit it hands a `RemoteRepositoryConfig` to `onAdd` (the caller
/// dispatches `.addRemoteRepository`). Keeps the terminal-only "simpler than
/// VS Code Remote" model: just an ssh host + a remote path.
struct AddRemoteRepositorySheet: View {
  let onAdd: (RemoteRepositoryConfig) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var alias = ""
  @State private var username = ""
  @State private var port = ""
  @State private var remotePath = ""
  @State private var displayName = ""

  private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var trimmedPath: String { remotePath.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSubmit: Bool { !trimmedAlias.isEmpty && !trimmedPath.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section {
          TextField("SSH host", text: $alias, prompt: Text("ssh alias or hostname, e.g. mbp"))
            .help("An ~/.ssh/config alias or a hostname Supacode will pass to ssh")
          TextField("User (optional)", text: $username, prompt: Text("defaults to ssh config"))
          TextField("Port (optional)", text: $port, prompt: Text("22"))
        } header: {
          Text("Host")
        }
        Section {
          TextField("Remote path", text: $remotePath, prompt: Text("/home/you/project or ~/project"))
            .help("Absolute path on the remote host; a leading ~ is expanded by the remote shell")
          TextField("Display name (optional)", text: $displayName, prompt: Text("defaults to the folder name"))
        } header: {
          Text("Repository")
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          onAdd(makeConfig())
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .help("Add this remote repository to the sidebar")
      }
      .padding(12)
    }
    .frame(minWidth: 420, minHeight: 320)
  }

  private func makeConfig() -> RemoteRepositoryConfig {
    let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = RemoteHost(
      alias: trimmedAlias,
      username: trimmedUser.isEmpty ? nil : trimmedUser,
      port: Int(trimmedPort)
    )
    return RemoteRepositoryConfig(
      host: host,
      remotePath: trimmedPath,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
