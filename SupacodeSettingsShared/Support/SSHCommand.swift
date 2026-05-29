import Foundation

/// Pure, stateless builders for the `ssh` command lines Supacode issues against
/// a `RemoteHost`. Two consumers, two shapes:
///
///   - `invocation(...)` returns an argv for `Process` / `ShellClient` — ssh
///     receives the remote command as a single argument, so only the *remote*
///     shell re-parses it (one quoting level, applied in `remoteCommand`).
///   - `commandLine(...)` returns a single string for a parent `/bin/sh -c`
///     (Ghostty's surface command), so the remote command must additionally be
///     quoted for the *local* shell (two quoting levels).
///
/// Every invocation shares `controlOptions` so N git calls plus the terminal
/// reuse one multiplexed SSH connection: one auth / FIDO touch, and no
/// per-call TCP+handshake round trip that would otherwise make a many-worktree
/// sidebar crawl.
public nonisolated enum SSHCommand {
  public static let sshExecutablePath = "/usr/bin/ssh"

  /// `%C` is ssh's hash of (local host, remote host, port, user): stable per
  /// connection and short, keeping the control socket well under the
  /// `sockaddr_un.sun_path` limit. ssh expands both `~` and `%C` itself.
  public static let defaultControlPath = "~/.ssh/supacode-%C"

  /// SSH connection-multiplexing options. `auto` opens a master if none exists
  /// and reuses it otherwise; `ControlPersist` keeps it warm briefly after the
  /// last client so a burst of git calls shares one connection.
  public static func controlOptions(controlPath: String = defaultControlPath) -> [String] {
    [
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=\(controlPath)",
      "-o", "ControlPersist=10m",
    ]
  }

  /// POSIX single-quote a token so a parent shell passes it through literally.
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\\''") + "'"
  }

  /// The command string the *remote* shell runs for a local
  /// `(executable, arguments, workingDirectory)` invocation. A working
  /// directory becomes `cd -- <dir> && exec ...` so the remote process starts
  /// in the worktree and replaces the shell (signals / exit status map
  /// straight through).
  public static func remoteCommand(
    executable: String,
    arguments: [String],
    workingDirectory: URL?
  ) -> String {
    let invocation = ([executable] + arguments).map(shellQuote).joined(separator: " ")
    guard let workingDirectory else {
      return invocation
    }
    let directory = shellQuote(workingDirectory.path(percentEncoded: false))
    return "cd -- \(directory) && exec \(invocation)"
  }

  /// Wrap a remote command so it runs under a **login** shell. ssh's default
  /// `$SHELL -c <cmd>` is non-interactive *and* non-login, so on macOS it only
  /// inherits `~/.zshenv`'s bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) —
  /// Homebrew's `/opt/homebrew/bin` (where remote `zmx` / `git` / the `wt` shim
  /// live) is NOT on it, so the remote command fails with `command not found`.
  /// A login shell reads `/etc/zprofile` (path_helper) + `~/.zprofile`
  /// (`brew shellenv`), restoring the full PATH. `$SHELL` is expanded by ssh's
  /// own outer shell; `exec` replaces it so signals / exit status pass through.
  public static func loginShellWrapped(_ remoteScript: String) -> String {
    "exec \"$SHELL\" -l -c " + shellQuote(remoteScript)
  }

  /// Full local `ssh` argv for `Process` / `ShellClient`. The remote command is
  /// a single argument; ssh hands it to the remote login shell verbatim.
  public static func invocation(
    host: RemoteHost,
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    allocateTTY: Bool = false,
    controlPath: String = defaultControlPath
  ) -> (executableURL: URL, arguments: [String]) {
    var sshArguments = controlOptions(controlPath: controlPath)
    if allocateTTY {
      sshArguments.append("-tt")
    }
    sshArguments += host.sshOptionArguments
    sshArguments.append(host.sshDestination)
    sshArguments.append(
      loginShellWrapped(
        remoteCommand(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
      )
    )
    return (URL(fileURLWithPath: sshExecutablePath), sshArguments)
  }

  /// Full `ssh` line as a single string for a parent `/bin/sh -c` (Ghostty's
  /// surface command). The fixed option tokens are shell-safe and stay
  /// unquoted (so ssh still expands `~` / `%C` in `ControlPath`); the
  /// login-shell-wrapped remote command is quoted for the local shell.
  public static func commandLine(
    host: RemoteHost,
    remoteCommand: String,
    allocateTTY: Bool = true,
    controlPath: String = defaultControlPath,
    reverseSocketForward: (remote: String, local: String)? = nil
  ) -> String {
    var tokens = [sshExecutablePath]
    tokens += controlOptions(controlPath: controlPath)
    if allocateTTY {
      tokens.append("-tt")
    }
    if let forward = reverseSocketForward {
      // Reverse-forward a remote Unix socket to the local agent-hook socket so a
      // coding agent's hook on the host can reach `SUPACODE_SOCKET_PATH` and
      // light the local awaiting-input badge. `StreamLocalBindUnlink=yes` clears
      // a stale bind left by a crashed session so the rebind succeeds. NOTE:
      // forwards bind to the connection that opens the master — if a `-R`-less
      // git connection already established the shared master, this is dropped
      // until the master is re-established. Requires OpenSSH >= 6.7.
      tokens += ["-o", "StreamLocalBindUnlink=yes"]
      tokens += ["-R", shellQuote("\(forward.remote):\(forward.local)")]
    }
    tokens += host.sshOptionArguments
    tokens.append(host.sshDestination)
    tokens.append(shellQuote(loginShellWrapped(remoteCommand)))
    return tokens.joined(separator: " ")
  }
}
