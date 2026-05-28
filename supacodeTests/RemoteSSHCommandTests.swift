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

  @Test func invocationBuildsSSHArgvWithMultiplexingAndRemoteCommand() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "mbp"),
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "mbp",
        "cd -- '/tmp/repo' && exec '/usr/bin/env' 'git' '-C' '/tmp/repo' 'status'",
      ]
    )
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
        "'zmx' 'ls'",
      ]
    )
  }

  @Test func commandLineQuotesOnlyTheRemoteCommandForTheLocalShell() {
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "mbp"),
      remoteCommand: "zmx attach supa-x"
    )
    #expect(
      line
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt mbp "
        + "'zmx attach supa-x'"
    )
  }
}

struct ZmxAttachRemoteTests {
  @Test func remoteAttachCommandWithoutUserCommandIsAttachOnly() {
    #expect(ZmxAttach.remoteAttachCommand(sessionID: "supa-x", userCommand: nil) == "zmx attach supa-x")
  }

  @Test func remoteAttachCommandIgnoresWhitespaceUserCommand() {
    #expect(ZmxAttach.remoteAttachCommand(sessionID: "supa-x", userCommand: "  \n") == "zmx attach supa-x")
  }

  @Test func remoteAttachCommandWrapsUserCommandViaShellC() {
    #expect(
      ZmxAttach.remoteAttachCommand(sessionID: "supa-x", userCommand: "claude --resume")
        == "zmx attach supa-x /bin/sh -c 'claude --resume'"
    )
  }

  @Test func buildRemoteCommandWithoutUserCommandSSHsAndAttaches() {
    let command = ZmxAttach.buildRemoteCommand(
      host: RemoteHost(alias: "mbp"),
      sessionID: "supa-deadbeef",
      userCommand: nil
    )
    #expect(
      command
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt mbp "
        + "'zmx attach supa-deadbeef'"
    )
  }

  @Test func buildRemoteCommandDoubleQuotesUserCommandThroughBothShells() {
    let command = ZmxAttach.buildRemoteCommand(
      host: RemoteHost(alias: "mbp"),
      sessionID: "supa-x",
      userCommand: "claude"
    )
    // Local /bin/sh strips the outer quoting → ssh sends
    //   zmx attach supa-x /bin/sh -c 'claude'
    // to the remote shell, which runs `/bin/sh -c claude` under zmx.
    #expect(
      command
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt mbp "
        + "'zmx attach supa-x /bin/sh -c '\\''claude'\\'''"
    )
  }

  @Test func buildRemoteCommandForwardsUsernameAndPort() {
    let command = ZmxAttach.buildRemoteCommand(
      host: RemoteHost(alias: "box", username: "lmjiang", port: 2222),
      sessionID: "supa-x",
      userCommand: nil
    )
    #expect(
      command
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt "
        + "-p 2222 lmjiang@box 'zmx attach supa-x'"
    )
  }
}
