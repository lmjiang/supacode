import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Form for adding a remote (SSH) repository to the sidebar. On submit it hands
/// a `RemoteRepositoryConfig` to `onAdd` (the caller dispatches
/// `.addRemoteRepository`). Keeps the terminal-only "simpler than VS Code
/// Remote" model — just an ssh host + a remote path — but leans on two
/// opportunistic, read-only conveniences: a host pick-list from `~/.ssh/config`,
/// and the repos the host's own Supacode already has open (read over ssh). Both
/// degrade gracefully to manual entry; nothing is installed on the remote.
struct AddRemoteRepositorySheet: View {
  let store: StoreOf<RepositoriesFeature>
  let onAdd: (RemoteRepositoryConfig) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var alias = ""
  @State private var username = ""
  @State private var port = ""
  @State private var remotePath = ""
  @State private var displayName = ""
  @State private var sshConfigHosts: [SSHConfigHost] = []

  private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var trimmedPath: String { remotePath.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSubmit: Bool { !trimmedAlias.isEmpty && !trimmedPath.isEmpty }

  /// A load has run for the current host and came back empty (vs never asked).
  private var loadedEmptyForCurrentHost: Bool {
    !store.isLoadingRemoteOpenedRepos
      && store.remoteOpenedReposHostDestination == makeHost().sshDestination
      && store.remoteOpenedRepoPaths.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section {
          if !sshConfigHosts.isEmpty {
            Menu {
              ForEach(sshConfigHosts) { host in
                Button(host.alias) { applyConfigHost(host) }
              }
            } label: {
              Label("Choose from ~/.ssh/config", systemImage: "list.bullet")
            }
            .help("Fill in a host from your SSH config")
          }
          TextField("SSH host", text: $alias, prompt: Text("ssh alias or hostname, e.g. devbox"))
            .help("An ~/.ssh/config alias or a hostname Supacode will pass to ssh")
          TextField("User (optional)", text: $username, prompt: Text("defaults to ssh config"))
          TextField("Port (optional)", text: $port, prompt: Text("22"))
        } header: {
          Text("Host")
        }
        Section {
          remoteRepoPicker
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
    .frame(minWidth: 420, minHeight: 360)
    .onAppear { sshConfigHosts = SSHConfigHosts.load() }
  }

  /// Lists the repos the host's own Supacode already has open (read over ssh),
  /// so the user can pick instead of typing a path. Falls back to the path field
  /// below when the remote has no Supacode config.
  @ViewBuilder private var remoteRepoPicker: some View {
    Button {
      store.send(.loadRemoteOpenedRepositories(makeHost()))
    } label: {
      Label("List repositories on host", systemImage: "arrow.clockwise")
    }
    .disabled(trimmedAlias.isEmpty || store.isLoadingRemoteOpenedRepos)
    .help("Read the host's Supacode config and list its open repositories")

    if store.isLoadingRemoteOpenedRepos {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Reading repositories on \(trimmedAlias)…").foregroundStyle(.secondary)
      }
    } else {
      ForEach(store.remoteOpenedRepoPaths, id: \.self) { path in
        Button {
          remotePath = path
        } label: {
          HStack {
            Image(systemName: trimmedPath == path ? "checkmark.circle.fill" : "folder")
              .foregroundStyle(trimmedPath == path ? Color.accentColor : .secondary)
              .accessibilityHidden(true)
            Text(path).lineLimit(1).truncationMode(.middle)
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      if loadedEmptyForCurrentHost {
        Text("No open repositories found on this host — enter a path below.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func applyConfigHost(_ host: SSHConfigHost) {
    alias = host.alias
    username = host.user ?? ""
    port = host.port.map(String.init) ?? ""
    store.send(.loadRemoteOpenedRepositories(makeHost()))
  }

  private func makeHost() -> RemoteHost {
    let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    return RemoteHost(
      alias: trimmedAlias,
      username: trimmedUser.isEmpty ? nil : trimmedUser,
      port: Int(trimmedPort)
    )
  }

  private func makeConfig() -> RemoteRepositoryConfig {
    RemoteRepositoryConfig(
      host: makeHost(),
      remotePath: trimmedPath,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
