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

struct SSHConfigHostsTests {
  @Test func parsesAliasWithHostNameUserPort() {
    let config = """
      Host mbp
        HostName 192.168.1.10
        User lmjiang
        Port 2222

      Host box
        User dev
      """
    let hosts = SSHConfigHosts.parse(config)
    #expect(hosts == [
      SSHConfigHost(alias: "mbp", hostName: "192.168.1.10", user: "lmjiang", port: 2222),
      SSHConfigHost(alias: "box", hostName: nil, user: "dev", port: nil),
    ])
  }

  @Test func skipsWildcardHosts() {
    #expect(SSHConfigHosts.parse("Host *\n  User x\nHost prod\n  HostName p").map(\.alias) == ["prod"])
  }

  @Test func handlesMultipleAliasesAndEqualsForm() {
    let hosts = SSHConfigHosts.parse("Host a b\n  HostName=h\n  Port = 22")
    #expect(hosts.map(\.alias) == ["a", "b"])
    #expect(hosts[0].hostName == "h")
    #expect(hosts[0].port == 22)
  }

  @Test func dedupesAliasesPreservingOrderAndIgnoresComments() {
    #expect(SSHConfigHosts.parse("# c\n\nHost a\nHost b\nHost a").map(\.alias) == ["a", "b"])
  }
}

@MainActor
struct RemoteOpenedReposTests {
  @Test func parseOpenedRepoPathsTrimsBlanksAndDedupes() throws {
    let settings = SettingsFile(repositoryRoots: ["/a", "/b", "  /a  ", ""])
    let json = try #require(String(data: JSONEncoder().encode(settings), encoding: .utf8))
    #expect(RepositoriesFeature.parseOpenedRepoPaths(fromSettingsJSON: json) == ["/a", "/b"])
  }

  @Test func parseOpenedRepoPathsReturnsEmptyForUnusableInput() {
    #expect(RepositoriesFeature.parseOpenedRepoPaths(fromSettingsJSON: "") == [])
    #expect(RepositoriesFeature.parseOpenedRepoPaths(fromSettingsJSON: "not json") == [])
  }

  @Test func loadRemoteOpenedRepoPathsCatsRemoteSettingsAndParses() async throws {
    let settings = SettingsFile(repositoryRoots: ["/home/me/proj"])
    let json = try #require(String(data: JSONEncoder().encode(settings), encoding: .utf8))
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { exe, args, cwd in
        recorder.record(executableURL: exe, arguments: args, currentDirectoryURL: cwd)
        return ShellOutput(stdout: json, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let host = RemoteHost(alias: "mbp")
    let paths = await RepositoriesFeature.loadRemoteOpenedRepoPaths(
      host: host, shell: .ssh(host: host, base: base))

    #expect(paths == ["/home/me/proj"])
    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let wrapped = snapshot.arguments.last ?? ""
    #expect(wrapped.contains(".supacode/settings.json"))
  }

  @Test func remoteOpenedRepositoriesLoadedStoresPathsForMatchingHost() async {
    var initial = RepositoriesFeature.State()
    initial.remoteOpenedReposHostDestination = "mbp"
    initial.isLoadingRemoteOpenedRepos = true
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }
    await store.send(.remoteOpenedRepositoriesLoaded(hostDestination: "mbp", paths: ["/a", "/b"])) {
      $0.isLoadingRemoteOpenedRepos = false
      $0.remoteOpenedRepoPaths = ["/a", "/b"]
    }
  }

  @Test func remoteOpenedRepositoriesLoadedIgnoresStaleHost() async {
    var initial = RepositoriesFeature.State()
    initial.remoteOpenedReposHostDestination = "box"
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }
    // No state change: the result is for a host the user already switched away from.
    await store.send(.remoteOpenedRepositoriesLoaded(hostDestination: "mbp", paths: ["/a"]))
  }
}

@MainActor
struct RemoteWorktreeBaseRefTests {
  private func emptyRemoteClient() -> GitClient {
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    return GitClient(shell: .ssh(host: RemoteHost(alias: "mbp"), base: base))
  }

  @Test func explicitBaseRefIsUsedVerbatim() async {
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .explicit("origin/dev"),
      selectedBaseRef: nil,
      client: emptyRemoteClient(),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(ref == "origin/dev")
  }

  @Test func repositorySettingBaseRefIsUsed() async {
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .repositorySetting,
      selectedBaseRef: "main",
      client: emptyRemoteClient(),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(ref == "main")
  }

  @Test func delegatesToRemoteAutomaticBaseRefWhenNoExplicitSelection() async {
    // No explicit ref / repo setting → delegate to the remote's automatic base
    // ref (mirrors local), not a hardcoded HEAD.
    let repoRoot = URL(fileURLWithPath: "/repo")
    let client = emptyRemoteClient()
    let expected = await client.automaticWorktreeBaseRef(for: repoRoot) ?? "HEAD"
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .repositorySetting,
      selectedBaseRef: "",
      client: client,
      repoRoot: repoRoot
    )
    #expect(ref == expected)
    #expect(!ref.isEmpty)
  }
}
