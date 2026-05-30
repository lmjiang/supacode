import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Repository.ID for a remote config. Host-keyed and prefixed so it can never
  /// collide with a local repository's id (an absolute filesystem path) nor
  /// with another host pointing at the same remote path. Because this is not a
  /// filesystem path, the local-only `buildRepositorySections` loop (which keys
  /// `repositories[id:]` off `rootURL.path`) never matches a remote repo, so
  /// remote repos are rendered solely by the dedicated remote partition.
  static func remoteRepositoryID(for config: RemoteRepositoryConfig) -> Repository.ID {
    "remote:" + config.host.sshDestination + ":" + config.normalizedRemotePath
  }

  /// Host-keyed worktree id `<sshDestination>:<remotePath>` so worktrees at the
  /// same path on different hosts (or matching a local path) never collide.
  static func remoteWorktreeID(host: RemoteHost, worktreePath: String) -> Worktree.ID {
    host.sshDestination + ":" + worktreePath
  }

  /// The persisted remote-repository configs. Read through `@Shared` so every
  /// load path (initial, reload, open, removal) sees the same source of truth.
  static func persistedRemoteRepositoryConfigs() -> [RemoteRepositoryConfig] {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.remoteRepositories
  }

  /// Load each remote config as a real git repository over SSH. Serial — the
  /// ssh ControlMaster keeps a burst to one connection, and the remote count is
  /// small. Worktrees come from `git worktree list --porcelain` on the host;
  /// `host` + host-keyed ids are injected here. On any failure (unreachable,
  /// not a git repo, git missing) we fall back to a single synthetic main
  /// worktree so the repo stays visible/selectable and the terminal attach
  /// surfaces the remote error.
  static func loadRemoteRepositories(_ configs: [RemoteRepositoryConfig]) async -> [Repository] {
    var result: [Repository] = []
    var seen: Set<Repository.ID> = []
    for config in configs {
      let repoID = remoteRepositoryID(for: config)
      guard seen.insert(repoID).inserted else { continue }
      result.append(await loadRemoteRepository(config, repoID: repoID))
    }
    return result
  }

  private static func loadRemoteRepository(
    _ config: RemoteRepositoryConfig,
    repoID: Repository.ID
  ) async -> Repository {
    let host = config.host
    let rootURL = URL(fileURLWithPath: config.normalizedRemotePath)
    let client = GitClient(shell: .ssh(host: host))
    let worktrees: [Worktree]
    if let loaded = try? await client.gitWorktrees(for: rootURL), !loaded.isEmpty {
      worktrees = loaded.map { remoteWorktree(from: $0, host: host) }
    } else {
      worktrees = [remoteMainWorktree(config: config)]
    }
    return Repository(
      id: repoID,
      rootURL: rootURL,
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: worktrees),
      isGitRepository: true,
      host: host
    )
  }

  /// Read the remote host's own Supacode config (`~/.supacode/settings.json`)
  /// over ssh and return the repo roots it already has open, so the Add-Remote
  /// sheet can offer them as a pick-list. Opportunistic and read-only: installs
  /// nothing on the remote, and returns `[]` when the remote has no Supacode
  /// config (never run / no repos) so the caller falls back to manual entry.
  static func loadRemoteOpenedRepoPaths(
    host: RemoteHost,
    shell: ShellClient? = nil
  ) async -> [String] {
    let shell = shell ?? .ssh(host: host)
    // `$HOME` is expanded by the remote shell; `|| true` keeps a missing file a
    // clean empty result instead of a non-zero exit that `run` would throw on.
    let script = #"cat "$HOME/.supacode/settings.json" 2>/dev/null || true"#
    guard
      let output = try? await shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], nil)
    else {
      return []
    }
    return parseOpenedRepoPaths(fromSettingsJSON: output.stdout)
  }

  /// Pure decode of a remote `settings.json` into its repo roots: trimmed,
  /// blanks dropped, de-duplicated preserving order. Returns `[]` for empty or
  /// undecodable input.
  static func parseOpenedRepoPaths(fromSettingsJSON json: String) -> [String] {
    guard let data = json.data(using: .utf8), !data.isEmpty,
      let settings = try? JSONDecoder().decode(SettingsFile.self, from: data)
    else {
      return []
    }
    var seen: Set<String> = []
    return settings.repositoryRoots
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// Re-key a worktree parsed from the remote `git worktree list` with the host
  /// and a host-keyed id, preserving everything else.
  static func remoteWorktree(from base: Worktree, host: RemoteHost) -> Worktree {
    Worktree(
      id: remoteWorktreeID(host: host, worktreePath: base.workingDirectory.path(percentEncoded: false)),
      name: base.name,
      detail: base.detail,
      workingDirectory: base.workingDirectory,
      repositoryRootURL: base.repositoryRootURL,
      createdAt: base.createdAt,
      isMissing: base.isMissing,
      isAttached: base.isAttached,
      host: host
    )
  }

  /// Synthetic main worktree used when the remote git listing is unavailable.
  /// `workingDirectory == repositoryRootURL` so it classifies as the git main.
  static func remoteMainWorktree(config: RemoteRepositoryConfig) -> Worktree {
    let rootURL = URL(fileURLWithPath: config.normalizedRemotePath)
    return Worktree(
      id: remoteWorktreeID(host: config.host, worktreePath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      detail: config.host.sshDestination,
      workingDirectory: rootURL,
      repositoryRootURL: rootURL,
      isAttached: false,
      host: config.host
    )
  }

  /// Remote worktree creation: pick a name (excluding remote branches), run
  /// `git worktree add` over ssh, then reload to re-list. Bypasses the local
  /// pending/stream flow but honors the prompt's name + base-ref choices. The
  /// base ref is resolved the same way as local (`baseRefSource` → explicit /
  /// repo setting, falling back to the remote's automatic base ref), and the
  /// new worktree lands beside the repo root (`<parent>/<name>`), so no parent
  /// dir needs to be created first.
  func remoteCreateWorktree(
    repository: Repository,
    host: RemoteHost,
    nameSource: WorktreeCreationNameSource,
    baseRefSource: WorktreeCreationBaseRefSource,
    selectedBaseRef: String?
  ) -> Effect<Action> {
    let repoRoot = repository.rootURL
    let existingNames = Set(repository.worktrees.map { $0.name.lowercased() })
    return .run { send in
      let client = GitClient(shell: .ssh(host: host))
      let remoteBranches = (try? await client.localBranchNames(for: repoRoot)) ?? []
      let existing = existingNames.union(remoteBranches)
      let name: String
      switch nameSource {
      case .random:
        let generated = await MainActor.run { WorktreeNameGenerator.nextName(excluding: existing) }
        guard let generated else {
          await send(
            .presentAlert(
              title: "No available worktree names",
              message: "All default adjective-animal names are already in use. "
                + "Delete a worktree or rename a branch, then try again."
            )
          )
          return
        }
        name = generated
      case .explicit(let explicit):
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
          await send(
            .presentAlert(
              title: "Branch name invalid",
              message: "Enter a branch name without spaces to create a worktree."
            )
          )
          return
        }
        name = trimmed
      }
      let worktreePath = repoRoot.deletingLastPathComponent()
        .appending(path: name, directoryHint: .isDirectory)
      let baseRef = await Self.resolveRemoteBaseRef(
        baseRefSource: baseRefSource, selectedBaseRef: selectedBaseRef, client: client, repoRoot: repoRoot)
      do {
        try await client.createGitWorktree(in: repoRoot, name: name, baseRef: baseRef, worktreePath: worktreePath)
        await send(.loadPersistedRepositories)
      } catch {
        await send(.presentAlert(title: "Unable to create worktree", message: error.localizedDescription))
      }
    }
  }

  /// Resolve the base ref for a remote worktree the same way the local path does
  /// (`baseRefSource` → explicit / repo setting, falling back to the remote's
  /// automatic base ref), defaulting to `HEAD` when nothing resolves so
  /// `git worktree add` always has a concrete committish.
  static func resolveRemoteBaseRef(
    baseRefSource: WorktreeCreationBaseRefSource,
    selectedBaseRef: String?,
    client: GitClient,
    repoRoot: URL
  ) async -> String {
    let resolved: String
    switch baseRefSource {
    case .repositorySetting:
      if let selectedBaseRef, !selectedBaseRef.isEmpty {
        resolved = selectedBaseRef
      } else {
        resolved = await client.automaticWorktreeBaseRef(for: repoRoot) ?? ""
      }
    case .explicit(let explicit):
      if let explicit, !explicit.isEmpty {
        resolved = explicit
      } else {
        resolved = await client.automaticWorktreeBaseRef(for: repoRoot) ?? ""
      }
    }
    return resolved.isEmpty ? "HEAD" : resolved
  }
}
