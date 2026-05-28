import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Asserts that a `GitClient` built on `ShellClient.ssh(host:)` rewrites a
/// worktree-create shell-out into the expected `ssh <host> <remoteCommand>`
/// wire invocation. The recorder stands in for the local `ssh` process so the
/// concatenation is checked without a real connection.
struct GitClientRemoteSSHTests {
  @Test func createWorktreeStreamOverSSHWrapsTheWtInvocation() async throws {
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { executableURL, arguments, currentDirectoryURL in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/repo/swift-otter")))
          continuation.yield(.finished(ShellOutput(stdout: "/tmp/repo/swift-otter", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: .ssh(host: RemoteHost(alias: "mbp"), base: base))

    for try await _ in client.createWorktreeStream(
      named: "swift-otter",
      in: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: "origin/main"
    ) {}

    let snapshot = recorder.snapshot()
    // The transport spawns `ssh`, not the local tool, and drops the cwd (the
    // working directory becomes a remote `cd` inside the remote command).
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    #expect(snapshot.currentDirectoryURL == nil)

    // Fixed multiplexing options + destination precede the single remote-command arg.
    #expect(
      Array(snapshot.arguments.prefix(7)) == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "mbp",
      ]
    )
    #expect(snapshot.arguments.count == 8)

    let remoteCommand = snapshot.arguments[7]
    // `cd -- <repoRoot> && exec /usr/bin/env LANG=C … <wt> …` — every token
    // single-quoted for the remote shell. The bundled `wt` path is volatile, so
    // assert around it.
    #expect(remoteCommand.hasPrefix("cd -- '/tmp/repo' && exec '/usr/bin/env' 'LANG=C' 'LC_ALL=C' 'LC_MESSAGES=C' "))
    #expect(remoteCommand.contains("'--base-dir' '/tmp/repo/.worktrees' 'sw'"))
    #expect(remoteCommand.contains("'--from' 'origin/main'"))
    #expect(remoteCommand.hasSuffix("'swift-otter'"))
  }
}
