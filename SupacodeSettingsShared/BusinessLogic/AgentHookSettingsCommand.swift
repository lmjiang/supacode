import Foundation

/// Hook events emitted via the JSON envelope path. Activity events
/// (`busy`, `awaitingInput`, `idle`) are atomic state-set. Each fires
/// the corresponding (surface, agent) activity directly; repeated events
/// are idempotent. The notification leg is composed in alongside an
/// envelope by `compositeCommand(forwardStdinAsNotification:)`.
nonisolated enum HookEvent: String {
  case sessionStart = "session_start"
  case sessionEnd = "session_end"
  case busy
  case awaitingInput = "awaiting_input"
  case idle
}

nonisolated enum AgentHookSettingsCommand {
  /// Sentinel comment appended to every Supacode-installed hook command.
  /// `AgentHookCommandOwnership` uses this — and ONLY this — to identify
  /// managed commands. `SUPACODE_SOCKET_PATH` is documented public API
  /// (CLI skill env table, Pi extension example, deeplink reference), so
  /// matching on the env-var name alone would silently strip user-authored
  /// hooks that legitimately reference it.
  static let ownershipMarker = "# supacode-managed-hook"

  /// Documented public env var. Used as ONE half of the legacy CLI-shim
  /// fingerprint (paired with `supacode integration event`); never matched
  /// alone — user-authored hooks reference it legitimately.
  static let socketPathEnvVar = "SUPACODE_SOCKET_PATH"

  /// Markers present in legacy Supacode hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "SUPACODE_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  /// Verbatim 4-var presence-guard at the head of every Supacode-installed
  /// hook. Carried forward unchanged across every command-shape revision,
  /// so it doubles as the pre-sentinel legacy fingerprint. A user-authored
  /// hook following the documented `SUPACODE_SOCKET_PATH`-only pattern
  /// (single-var check) does not match. A user who copied this guard
  /// verbatim AND removed the trailing sentinel intentionally would be
  /// treated as legacy. That's the deliberate trade for catching every
  /// pre-envelope shape of older Supacode hook.
  static let envCheck =
    #"[ -n "${SUPACODE_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${SUPACODE_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_TAB_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_SURFACE_ID:-}" ]"#

  private static let ids =
    "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"

  /// Both stdout AND stderr go to /dev/null — Codex parses hook stdout as
  /// structured JSON and would reject the socket ack otherwise.
  private static func managed(_ pipeline: String) -> String {
    "\(envCheck) && \(pipeline) >/dev/null 2>&1 || true \(ownershipMarker)"
  }

  /// Builds a single shell command that fires every `event` envelope and
  /// optionally forwards stdin as a notification, all under one envCheck
  /// guard with one sentinel. Stdin is consumed once via `payload=$(cat)`
  /// so the same payload can be relayed after the fixed envelopes. The
  /// precondition rejects a no-op invocation because the empty-empty
  /// fallthrough would otherwise emit `{ ; }` (shell syntax error masked
  /// by `|| true`).
  static func compositeCommand(
    events: [HookEvent],
    forwardStdinAsNotification: Bool,
    agent: SkillAgent
  ) -> String {
    precondition(
      !events.isEmpty || forwardStdinAsNotification,
      "compositeCommand needs at least one side-effect (events or stdin forward).",
    )
    // In-band OSC steps run BEFORE the socket command so the ownership sentinel
    // (appended by `managed`) stays at the very end for `AgentHookCommandOwnership`.
    // Presence OSC mirrors every event; when forwarding a notification, stash the
    // stdin payload once and emit a remote-only notify OSC so the bell rings over
    // zmx+ssh — skipped locally (socket delivers it) so it never double-rings.
    var prefix = events.map { presenceOSC(event: $0, agent: agent) }
    if forwardStdinAsNotification {
      prefix.append("payload=$(cat)")
      prefix.append(notifyOSC(agent: agent))
    }
    let socket = socketCommand(
      events: events, forwardStdinAsNotification: forwardStdinAsNotification, agent: agent)
    return (prefix + [socket]).joined(separator: "; ")
  }

  /// The out-of-band Unix-socket leg (unchanged behavior): one envelope per
  /// event plus an optional stdin-forwarded notification, under the socket
  /// `envCheck` guard with the trailing ownership sentinel.
  private static func socketCommand(
    events: [HookEvent],
    forwardStdinAsNotification: Bool,
    agent: SkillAgent
  ) -> String {
    if events.count == 1, !forwardStdinAsNotification {
      return managed(envelopePipeline(event: events[0], agent: agent))
    }
    if events.isEmpty, forwardStdinAsNotification {
      return managed(notifyPipeline(agent: agent))
    }
    var steps = events.map { envelopePipeline(event: $0, agent: agent) }
    if forwardStdinAsNotification {
      steps.append(notifyPipeline(agent: agent))
    }
    return managed("{ \(steps.joined(separator: "; ")); }")
  }

  /// In-band presence signal: an OSC 9 sequence carrying a Supacode sentinel,
  /// written to the controlling tty so it rides the terminal data stream and
  /// survives zmx + ssh (where the Unix socket is unreachable). Guarded by
  /// `SUPACODE_SURFACE_ID` alone — independent of the socket `envCheck` so it
  /// still fires on a remote host (no `SUPACODE_SOCKET_PATH` there), yet never
  /// in a user's plain terminal outside a Supacode surface. A missing
  /// controlling tty fails the `printf` harmlessly (`|| true`).
  static func presenceOSC(event: HookEvent, agent: SkillAgent) -> String {
    let osc =
      #"printf '\033]9;\#(AgentPresenceOSC.sentinel);\#(AgentPresenceOSC.version);"#
      + #"\#(agent.rawValue);\#(event.rawValue)\a'"#
    return #"{ [ -n "${SUPACODE_SURFACE_ID:-}" ] && \#(osc) >/dev/tty 2>/dev/null; } || true"#
  }

  /// Remote-only in-band notification: when there's no reachable local socket
  /// (`SUPACODE_SOCKET_PATH` unset → a remote host), carry the stashed
  /// notification payload as a base64 OSC 9 so the bell still rings on the local
  /// app over zmx+ssh. Skipped locally (the socket delivers it) so it never
  /// double-rings; base64 sidesteps escaping, and the bridge reuses the socket's
  /// notification parser to decode it. Reads `$payload` (stashed by the caller).
  static func notifyOSC(agent: SkillAgent) -> String {
    let osc =
      #"printf '\033]9;\#(AgentPresenceOSC.notifySentinel);\#(AgentPresenceOSC.version);\#(agent.rawValue);%s\a' "#
      + #""$(printf '%s' "$payload" | base64 | tr -d '\n')""#
    return
      #"{ [ -n "${SUPACODE_SURFACE_ID:-}" ] && [ -z "${SUPACODE_SOCKET_PATH:-}" ] && "#
      + #"\#(osc) >/dev/tty 2>/dev/null; } || true"#
  }

  private static func envelopePipeline(event: HookEvent, agent: SkillAgent) -> String {
    let envelope =
      #"{\"event\":\"\#(event.rawValue)\","#
      + #"\"v\":1,\"agent\":\"\#(agent.rawValue)\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}"#
    return #"printf '%s' "\#(envelope)" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
  }

  /// Relays the stashed `$payload` (the agent's notification JSON, captured once
  /// at the top of the composite command) to the socket server.
  private static func notifyPipeline(agent: SkillAgent) -> String {
    #"{ printf '%s \#(agent.rawValue)\n' "\#(ids)"; printf '%s' "$payload"; }"#
    + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
  }
}

/// Shared definition of the in-band agent-presence OSC, used by the hook
/// command builder (to emit) and the app's terminal bridge (to parse), so the
/// two ends share one sentinel and can't drift. The signal rides OSC 9 on the
/// terminal data stream, surfacing app-side as a desktop notification that the
/// bridge intercepts (see `GhosttySurfaceBridge`).
public nonisolated enum AgentPresenceOSC {
  /// Discriminator (first payload field) marking a Supacode presence signal,
  /// vs a genuine desktop notification.
  public static let sentinel = "supacode-presence"
  /// Discriminator for a remote-forwarded notification (vs presence / a genuine
  /// desktop notification). Its payload field is base64-encoded hook JSON.
  public static let notifySentinel = "supacode-notify"
  public static let version = "v1"

  /// Parse the OSC 9 payload `supacode-presence;v1;<agent>;<event>`. Returns the
  /// agent and the raw event name (validated against the app's event enum by the
  /// caller). Nil on sentinel/version mismatch or unknown agent.
  public static func parse(payload: String) -> (agent: SkillAgent, event: String)? {
    let fields = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 4, fields[0] == sentinel, fields[1] == version,
      let agent = SkillAgent(rawValue: fields[2])
    else { return nil }
    return (agent, fields[3])
  }

  /// Parse the OSC 9 payload `supacode-notify;v1;<agent>;<base64-json>`. Returns
  /// the agent and the decoded notification payload bytes (the agent's hook
  /// JSON). Nil on sentinel/version mismatch, unknown agent, or bad base64.
  public static func parseNotify(payload: String) -> (agent: SkillAgent, data: Data)? {
    let fields = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 4, fields[0] == notifySentinel, fields[1] == version,
      let agent = SkillAgent(rawValue: fields[2]),
      let data = Data(base64Encoded: fields[3])
    else { return nil }
    return (agent, data)
  }
}
