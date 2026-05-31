import Foundation

/// Describes an SSH destination a worktree can live on. A `nil` `RemoteHost`
/// everywhere means "local" — the unchanged Process-on-this-machine path.
///
/// `alias` is whatever `ssh` itself accepts as a host: a `~/.ssh/config` alias
/// or a bare hostname. `username` / `port` are optional overrides for callers
/// that don't want to encode them in ssh config. `worktreeBasePath` is the
/// remote directory new worktrees are created under (expanded by the remote
/// shell, so a leading `~` is fine); `nil` lets the caller fall back to a
/// remote default.
public nonisolated struct RemoteHost: Codable, Hashable, Sendable {
  public var alias: String
  public var username: String?
  public var port: Int?
  public var worktreeBasePath: String?

  public init(
    alias: String,
    username: String? = nil,
    port: Int? = nil,
    worktreeBasePath: String? = nil
  ) {
    self.alias = alias
    self.username = username
    self.port = port
    self.worktreeBasePath = worktreeBasePath
  }

  /// The `user@host` (or bare `host`) token passed to `ssh`.
  public var sshDestination: String {
    if let username, !username.isEmpty {
      return "\(username)@\(alias)"
    }
    return alias
  }

  /// Extra `ssh` option arguments derived from the host (currently just the
  /// port). Always shell-safe tokens, so callers can splice them into a
  /// command line without quoting.
  public var sshOptionArguments: [String] {
    guard let port else { return [] }
    return ["-p", String(port)]
  }
}
