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
}
