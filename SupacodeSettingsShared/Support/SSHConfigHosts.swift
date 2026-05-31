import Foundation

/// A host entry parsed from `~/.ssh/config`. Wildcard patterns (`Host *`,
/// `Host foo?`) are skipped — they aren't concrete connectable aliases.
public nonisolated struct SSHConfigHost: Equatable, Sendable, Identifiable {
  public let alias: String
  public let hostName: String?
  public let user: String?
  public let port: Int?

  public var id: String { alias }

  public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil) {
    self.alias = alias
    self.hostName = hostName
    self.user = user
    self.port = port
  }
}

/// Pure parser + loader for `~/.ssh/config` host aliases, used to offer a
/// pick-list in the Add-Remote sheet so the user doesn't retype known hosts.
/// Read-only and best-effort: a missing/unreadable config yields `[]`.
public nonisolated enum SSHConfigHosts {
  public static func load(fileManager: FileManager = .default) -> [SSHConfigHost] {
    let url = fileManager.homeDirectoryForCurrentUser
      .appending(path: ".ssh", directoryHint: .isDirectory)
      .appending(path: "config", directoryHint: .notDirectory)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return parse(contents)
  }

  /// Parse the textual config. Handles multi-alias `Host a b`, the `key value`
  /// and `key=value` forms, comments, and case-insensitive keywords. A `Host`
  /// block's `HostName` / `User` / `Port` are attached to each of its aliases.
  /// Wildcard aliases are dropped, and aliases are de-duplicated preserving
  /// first-seen order.
  public static func parse(_ contents: String) -> [SSHConfigHost] {
    var hosts: [SSHConfigHost] = []
    var aliases: [String] = []
    var hostName: String?
    var user: String?
    var port: Int?

    func flush() {
      for alias in aliases where !alias.contains("*") && !alias.contains("?") {
        hosts.append(SSHConfigHost(alias: alias, hostName: hostName, user: user, port: port))
      }
    }

    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let (keyword, values) = Self.tokenize(line)
      switch keyword.lowercased() {
      case "host":
        flush()
        aliases = values
        hostName = nil
        user = nil
        port = nil
      case "hostname":
        hostName = values.first
      case "user":
        user = values.first
      case "port":
        port = values.first.flatMap(Int.init)
      default:
        break
      }
    }
    flush()

    var seen: Set<String> = []
    return hosts.filter { seen.insert($0.alias).inserted }
  }

  /// Split a config line into its keyword and value tokens, accepting both
  /// `key value` and `key=value` (and `key = value`) forms.
  private static func tokenize(_ line: String) -> (keyword: String, values: [String]) {
    let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
    let tokens = line
      .components(separatedBy: separators)
      .filter { !$0.isEmpty }
    guard let keyword = tokens.first else { return ("", []) }
    return (keyword, Array(tokens.dropFirst()))
  }
}
