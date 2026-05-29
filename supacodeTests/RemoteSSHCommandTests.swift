import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteHostTests {
  @Test func bareAliasHasNoUserOrPortOptions() {
    let host = RemoteHost(alias: "mbp")
    #expect(host.sshDestination == "mbp")
    #expect(host.sshOptionArguments.isEmpty)
  }

  @Test func usernameAndPortProjectIntoDestinationAndOptions() {
    let host = RemoteHost(alias: "box", username: "lmjiang", port: 2222)
    #expect(host.sshDestination == "lmjiang@box")
    #expect(host.sshOptionArguments == ["-p", "2222"])
  }

  @Test func emptyUsernameFallsBackToBareAlias() {
    let host = RemoteHost(alias: "box", username: "")
    #expect(host.sshDestination == "box")
  }
}

struct SSHCommandTests {
  @Test func shellQuoteWrapsAndEscapesSingleQuotes() {
    #expect(SSHCommand.shellQuote("echo hi") == "'echo hi'")
    #expect(SSHCommand.shellQuote("echo 'hi'") == "'echo '\\''hi'\\'''")
  }

  @Test func remoteCommandWithoutWorkingDirectoryQuotesEachToken() {
    let command = SSHCommand.remoteCommand(
      executable: "git",
      arguments: ["status", "--short"],
      workingDirectory: nil
    )
    #expect(command == "'git' 'status' '--short'")
  }

  @Test func remoteCommandWithWorkingDirectoryPrependsCdAndExec() {
    let command = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(command == "cd -- '/tmp/repo' && exec '/usr/bin/env' 'git' 'status'")
  }

  @Test func loginShellWrappedExecsLoginShellWithQuotedScript() {
    #expect(SSHCommand.loginShellWrapped("zmx attach s") == "exec \"$SHELL\" -l -c 'zmx attach s'")
    #expect(SSHCommand.loginShellWrapped("echo 'hi'") == "exec \"$SHELL\" -l -c 'echo '\\''hi'\\'''")
  }

  @Test func invocationWrapsRemoteCommandInLoginShellAfterMultiplexingOptions() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "mbp"),
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let expectedScript = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "mbp",
        SSHCommand.loginShellWrapped(expectedScript),
      ]
    )
    // The wrapped arg actually carries the git invocation under a login shell.
    #expect(result.arguments.last?.hasPrefix("exec \"$SHELL\" -l -c ") == true)
    #expect(result.arguments.last?.contains("git") == true)
  }

  @Test func invocationAllocatesTTYAndForwardsPortWhenRequested() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "box", username: "lmjiang", port: 2222),
      executable: "zmx",
      arguments: ["ls"],
      workingDirectory: nil,
      allocateTTY: true
    )
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "-tt",
        "-p", "2222",
        "lmjiang@box",
        SSHCommand.loginShellWrapped("'zmx' 'ls'"),
      ]
    )
  }

  @Test func commandLineWrapsRemoteCommandInLoginShellQuotedForLocalShell() {
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "mbp"),
      remoteCommand: "zmx attach supa-x"
    )
    let expectedTail = SSHCommand.shellQuote(SSHCommand.loginShellWrapped("zmx attach supa-x"))
    #expect(
      line
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt mbp "
        + expectedTail
    )
  }
}

struct ZmxAttachRemoteTests {
  private let surfaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
  private var surfacePrelude: String { "export SUPACODE_SURFACE_ID='\(surfaceID.uuidString)'; " }

  @Test func remoteAttachCommandWithoutUserCommandExportsSurfaceThenAttaches() {
    #expect(
      ZmxAttach.remoteAttachCommand(sessionID: "supa-x", userCommand: nil, surfaceID: surfaceID, remoteSocketPath: nil)
        == surfacePrelude + "zmx attach supa-x"
    )
  }

  @Test func remoteAttachCommandExportsSocketPathWhenForwarded() {
    #expect(
      ZmxAttach.remoteAttachCommand(
        sessionID: "supa-x",
        userCommand: nil,
        surfaceID: surfaceID,
        remoteSocketPath: "/tmp/hook.sock"
      ) == surfacePrelude + "export SUPACODE_SOCKET_PATH='/tmp/hook.sock'; zmx attach supa-x"
    )
  }

  @Test func remoteAttachCommandIgnoresWhitespaceUserCommand() {
    #expect(
      ZmxAttach.remoteAttachCommand(
        sessionID: "supa-x",
        userCommand: "  \n",
        surfaceID: surfaceID,
        remoteSocketPath: nil
      ) == surfacePrelude + "zmx attach supa-x"
    )
  }

  @Test func remoteAttachCommandWrapsUserCommandViaShellC() {
    #expect(
      ZmxAttach.remoteAttachCommand(
        sessionID: "supa-x",
        userCommand: "claude --resume",
        surfaceID: surfaceID,
        remoteSocketPath: nil
      ) == surfacePrelude + "zmx attach supa-x /bin/sh -c 'claude --resume'"
    )
  }

  @Test func buildRemoteCommandWithoutSocketHasNoReverseForward() {
    let host = RemoteHost(alias: "mbp")
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      sessionID: "supa-deadbeef",
      userCommand: nil,
      surfaceID: surfaceID,
      localSocketPath: nil
    )
    #expect(
      command
        == SSHCommand.commandLine(
          host: host,
          remoteCommand: ZmxAttach.remoteAttachCommand(
            sessionID: "supa-deadbeef",
            userCommand: nil,
            surfaceID: surfaceID,
            remoteSocketPath: nil
          )
        )
    )
    #expect(command.contains("exec "))
    #expect(command.contains("zmx attach supa-deadbeef"))
    #expect(!command.contains("-R "))
  }

  @Test func buildRemoteCommandWithSocketAddsReverseForwardAndExportsSocket() {
    let host = RemoteHost(alias: "mbp")
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      sessionID: "supa-x",
      userCommand: "claude",
      surfaceID: surfaceID,
      localSocketPath: "/var/folders/local-hook.sock"
    )
    let remoteSocket = ZmxAttach.remoteAgentHookSocketPath(surfaceID: surfaceID)
    // Reverse-forwards the remote per-surface socket to the local hook socket.
    #expect(command.contains("-o StreamLocalBindUnlink=yes"))
    #expect(command.contains("-R '\(remoteSocket):/var/folders/local-hook.sock'"))
    // The remote shell learns the forwarded socket path.
    #expect(command.contains("SUPACODE_SOCKET_PATH="))
    #expect(command.contains(remoteSocket))
  }

  @Test func buildRemoteCommandForwardsUsernameAndPort() {
    let host = RemoteHost(alias: "box", username: "lmjiang", port: 2222)
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      sessionID: "supa-x",
      userCommand: nil,
      surfaceID: surfaceID,
      localSocketPath: nil
    )
    #expect(command.contains("-p 2222 lmjiang@box "))
  }
}
