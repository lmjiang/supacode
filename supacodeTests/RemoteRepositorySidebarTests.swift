import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteRepositoryConfigTests {
  @Test func normalizedRemotePathTrimsTrailingSlashesAndWhitespace() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "  /home/me/proj//  ",
      displayName: ""
    )
    #expect(config.normalizedRemotePath == "/home/me/proj")
  }

  @Test func normalizedRemotePathKeepsRootSlash() {
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "mbp"), remotePath: "/", displayName: "")
    #expect(config.normalizedRemotePath == "/")
  }

  @Test func resolvedDisplayNameFallsBackToRemoteLeaf() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "/home/me/proj",
      displayName: "  "
    )
    #expect(config.resolvedDisplayName == "proj")
  }

  @Test func resolvedDisplayNamePrefersExplicitName() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "/home/me/proj",
      displayName: "My Proj"
    )
    #expect(config.resolvedDisplayName == "My Proj")
  }
}

struct SynthesizeRemoteRepositoriesTests {
  @Test func synthesizesFolderKindRepositoryWithHostInjected() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp", username: "lmjiang"),
      remotePath: "/home/lmjiang/proj",
      displayName: "proj"
    )
    let repos = RepositoriesFeature.synthesizeRemoteRepositories([config])
    #expect(repos.count == 1)
    let repo = repos[0]
    #expect(repo.isGitRepository == false)
    #expect(repo.host?.sshDestination == "lmjiang@mbp")
    #expect(repo.id == RepositoriesFeature.remoteRepositoryID(for: config))
    // The single synthetic worktree carries the host so the terminal goes SSH.
    #expect(repo.worktrees.count == 1)
    let worktree = repo.worktrees.elements[0]
    #expect(worktree.host?.sshDestination == "lmjiang@mbp")
    #expect(worktree.id == RepositoriesFeature.remoteWorktreeID(for: config))
    #expect(worktree.workingDirectory.path(percentEncoded: false) == "/home/lmjiang/proj")
  }

  @Test func hostKeyedIDsAvoidCollisionWithLocalPath() {
    // A remote repo at the same path as a local one must not share an id.
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "mbp"), remotePath: "/tmp/repo", displayName: "repo")
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    #expect(repoID != "/tmp/repo")
    #expect(repoID.hasPrefix("remote:"))
  }

  @Test func deDupesByRepositoryID() {
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "mbp"), remotePath: "/home/me/proj", displayName: "a")
    // Same (host, path), different display name / id → one synthesized repo.
    let dup = RemoteRepositoryConfig(host: RemoteHost(alias: "mbp"), remotePath: "/home/me/proj/", displayName: "b")
    let repos = RepositoriesFeature.synthesizeRemoteRepositories([config, dup])
    #expect(repos.count == 1)
  }
}

@MainActor
struct RemoteSidebarPartitionTests {
  private func localRepository() -> Repository {
    let root = URL(fileURLWithPath: "/tmp/localrepo")
    let main = Worktree(
      id: root.path(percentEncoded: false),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(
      id: root.path(percentEncoded: false),
      rootURL: root,
      name: "localrepo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(reconciledRepositories: repositories)
    state.isInitialLoadComplete = true
    return state
  }

  @Test func remotePresentEmitsLocalAndRemotePartitionHeaders() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let remote = RepositoriesFeature.synthesizeRemoteRepositories([config])
    let state = makeState(repositories: [localRepository()] + remote)

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let ids = structure.sections.map(\.id)

    #expect(ids.contains(.partitionHeader(.local)))
    #expect(ids.contains(.partitionHeader(.remote)))
    // The remote repo renders as a folder section under the remote partition.
    let remoteRepoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let hasRemoteFolder = structure.sections.contains { section in
      if case .folder(let repositoryID, _) = section { return repositoryID == remoteRepoID }
      return false
    }
    #expect(hasRemoteFolder)

    // Local header precedes the remote header.
    let localIndex = ids.firstIndex(of: .partitionHeader(.local))
    let remoteIndex = ids.firstIndex(of: .partitionHeader(.remote))
    #expect(localIndex != nil && remoteIndex != nil && localIndex! < remoteIndex!)
  }

  @Test func localOnlySidebarHasNoPartitionHeaders() {
    let state = makeState(repositories: [localRepository()])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let ids = structure.sections.map(\.id)

    #expect(!ids.contains(.partitionHeader(.local)))
    #expect(!ids.contains(.partitionHeader(.remote)))
  }
}

@MainActor
struct RemoteDefaultShellCommandTests {
  @Test func buildsCdIntoRemotePathThenExecLoginShell() {
    #expect(
      WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/home/me/proj")
        == "cd '/home/me/proj' 2>/dev/null; exec \"$SHELL\" -l"
    )
  }

  @Test func escapesSingleQuotesInRemotePath() {
    #expect(
      WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/home/o'brien/proj")
        == "cd '/home/o'\\''brien/proj' 2>/dev/null; exec \"$SHELL\" -l"
    )
  }

  @Test func nilForRootOrEmptyPath() {
    #expect(WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/") == nil)
    #expect(WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "   ") == nil)
  }
}
