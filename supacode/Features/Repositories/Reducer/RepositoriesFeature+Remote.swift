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

  /// Worktree.ID for a remote config's synthetic worktree. Host-keyed for the
  /// same collision-avoidance reason as `remoteRepositoryID`.
  static func remoteWorktreeID(for config: RemoteRepositoryConfig) -> Worktree.ID {
    "remote-wt:" + config.host.sshDestination + ":" + config.normalizedRemotePath
  }

  /// The persisted remote-repository configs. Read through `@Shared` so every
  /// load path (initial, reload, open, removal) sees the same source of truth.
  static func persistedRemoteRepositoryConfigs() -> [RemoteRepositoryConfig] {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.remoteRepositories
  }

  /// Materialize each remote config into a folder-kind `Repository` whose single
  /// synthetic worktree carries `host`. Folder-kind means no git shell-outs run
  /// against the (unreachable-locally) remote path; selection + terminal binding
  /// reuse the standard folder machinery, and the terminal launches over SSH
  /// because `Worktree.host` is non-nil (Phase A). De-dupes by repository id so
  /// a duplicated config can't trap `IdentifiedArray(uniqueElements:)`.
  static func synthesizeRemoteRepositories(_ configs: [RemoteRepositoryConfig]) -> [Repository] {
    var seen: Set<Repository.ID> = []
    var result: [Repository] = []
    for config in configs {
      let repoID = remoteRepositoryID(for: config)
      guard seen.insert(repoID).inserted else { continue }
      let path = config.normalizedRemotePath
      // `workingDirectory` holds the real remote path (used to `cd` on attach
      // and for the row subtitle); it is never opened locally.
      let rootURL = URL(fileURLWithPath: path)
      let worktree = Worktree(
        id: remoteWorktreeID(for: config),
        name: config.resolvedDisplayName,
        detail: config.host.sshDestination,
        workingDirectory: rootURL,
        repositoryRootURL: rootURL,
        isAttached: false,
        host: config.host
      )
      result.append(
        Repository(
          id: repoID,
          rootURL: rootURL,
          name: config.resolvedDisplayName,
          worktrees: IdentifiedArray(uniqueElements: [worktree]),
          isGitRepository: false,
          host: config.host
        )
      )
    }
    return result
  }
}
