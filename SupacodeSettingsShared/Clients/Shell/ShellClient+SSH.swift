import Foundation

extension ShellClient {
  /// Host-aware transport: returns a `ShellClient` that runs every command on
  /// `host` over SSH instead of locally. Each call's
  /// `(executableURL, arguments, currentDirectoryURL)` is rewritten into an
  /// `ssh <host> <remoteCommand>` invocation (the working directory becomes a
  /// remote `cd`), then delegated to `base` — which actually spawns the local
  /// `ssh` process. `base` defaults to `.live`; tests inject a recorder to
  /// assert the wire command.
  ///
  /// This is the single chokepoint that makes the rest of the stack remote:
  /// `GitClient(shell: .ssh(host:))` routes every `git` / `wt` shell-out
  /// through SSH without any other change.
  ///
  /// The login-vs-plain distinction collapses here: ssh already runs the remote
  /// command through the user's remote login shell, so the local login-shell
  /// wrapping (`zsh -l -c …`) that `runLogin` applies must NOT be layered on top
  /// — the `runLogin*` entries route to the plain `base.run*`.
  public static func ssh(host: RemoteHost, base: ShellClient = .live) -> ShellClient {
    ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL
        )
        return try await base.run(invocation.executableURL, invocation.arguments, nil)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL
        )
        return try await base.run(invocation.executableURL, invocation.arguments, nil)
      },
      runStream: { executableURL, arguments, currentDirectoryURL in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL
        )
        return base.runStream(invocation.executableURL, invocation.arguments, nil)
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL
        )
        return base.runStream(invocation.executableURL, invocation.arguments, nil)
      }
    )
  }
}
