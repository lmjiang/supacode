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

struct RemoteRepositoryHelpersTests {
  @Test func remoteRepositoryIDIsHostKeyedAndPrefixed() {
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "mbp"), remotePath: "/tmp/repo", displayName: "repo")
    let id = RepositoriesFeature.remoteRepositoryID(for: config)
    #expect(id == "remote:mbp:/tmp/repo")
    // Never collides with a local repository id (an absolute filesystem path).
    #expect(id != "/tmp/repo")
  }

  @Test func remoteWorktreeIDIsHostKeyed() {
    let id = RepositoriesFeature.remoteWorktreeID(host: RemoteHost(alias: "mbp"), worktreePath: "/tmp/repo/wt")
    #expect(id == "mbp:/tmp/repo/wt")
  }

  @Test func remoteWorktreeInjectsHostAndHostKeyedID() {
    let host = RemoteHost(alias: "mbp", username: "lmjiang")
    let base = Worktree(
      id: "/home/lmjiang/proj/feature",
      name: "feature",
      detail: "feature",
      workingDirectory: URL(fileURLWithPath: "/home/lmjiang/proj/feature"),
      repositoryRootURL: URL(fileURLWithPath: "/home/lmjiang/proj")
    )
    let rekeyed = RepositoriesFeature.remoteWorktree(from: base, host: host)
    #expect(rekeyed.host?.sshDestination == "lmjiang@mbp")
    #expect(rekeyed.id == "lmjiang@mbp:/home/lmjiang/proj/feature")
    #expect(rekeyed.name == "feature")
    #expect(rekeyed.workingDirectory == base.workingDirectory)
  }

  @Test func remoteMainWorktreeIsGitMainWithHost() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let main = RepositoriesFeature.remoteMainWorktree(config: config)
    #expect(main.host?.sshDestination == "mbp")
    // workingDirectory == repositoryRootURL → classifies as the git main worktree.
    #expect(main.workingDirectory == main.repositoryRootURL)
    #expect(main.id == "mbp:/home/me/proj")
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

  private func remoteRepository(config: RemoteRepositoryConfig) -> Repository {
    Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: config),
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [RepositoriesFeature.remoteMainWorktree(config: config)]),
      isGitRepository: true,
      host: config.host
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
    let state = makeState(repositories: [localRepository(), remoteRepository(config: config)])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let ids = structure.sections.map(\.id)

    #expect(ids.contains(.partitionHeader(.local)))
    #expect(ids.contains(.partitionHeader(.remote)))
    // The remote repo renders as a git repository section under the remote partition.
    let remoteRepoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let hasRemoteRepoSection = structure.sections.contains { section in
      if case .repository(let repositoryID, _) = section { return repositoryID == remoteRepoID }
      return false
    }
    #expect(hasRemoteRepoSection)

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

@MainActor
struct RemoteWorktreeInfoTests {
  private func remoteRepository(config: RemoteRepositoryConfig) -> (Repository, Worktree) {
    let worktree = RepositoriesFeature.remoteMainWorktree(config: config)
    let repository = Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: config),
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: true,
      host: config.host
    )
    return (repository, worktree)
  }

  /// PR refresh runs `gh` against a local checkout, which a remote-only repo
  /// doesn't have, so the reducer must short-circuit to `.none`.
  @Test func pullRequestRefreshSkippedForRemoteRepository() async {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "mbp"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let (repository, worktree) = remoteRepository(config: config)
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // No state change and no effects: the host guard returns before any `gh`
    // work, so an exhaustive TestStore send with no trailing closure passes.
    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(repositoryRootURL: repository.rootURL, worktreeIDs: [worktree.id])
      )
    )
  }

  /// The remote-add sheet is now reducer-driven so the command palette and
  /// empty-state entry points can present it, not just the toolbar.
  @Test func setAddRemoteRepositoryPresentedTogglesState() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    await store.send(.setAddRemoteRepositoryPresented(true)) {
      $0.isAddRemoteRepositoryPresented = true
    }
    await store.send(.setAddRemoteRepositoryPresented(false)) {
      $0.isAddRemoteRepositoryPresented = false
    }
  }
}
