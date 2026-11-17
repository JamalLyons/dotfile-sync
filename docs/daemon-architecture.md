# dotfilesync agent architecture

Status: describes the Swift implementation in `Packages/DotfileSyncKit` and the app in `App/`
(issue #18). Parts reserved for later issues are marked.

## 1. Process model

```
 DotfileSync.app (SwiftUI) ─┐                     ┌─ Core (scan/status/plan/apply, brew, configs)
 dotfilesync (CLI)         ─┼── XPC (Mach service) ──► dotfilesyncd ─┤
                            │   com.jamallyons.dotfilesync.agent      └─ Agent: jobs, locks, approvals,
                            │                                            run history, journal, logs
                            └── standalone fallback for scan, status and plan (same Core.Ops code)
```

| SwiftPM module | Role |
|---|---|
| `Core` | Business logic: manifest model and validation, profiles, Brewfile parser, brew discovery, command runner with deadlines, config inspection, comparison, planner, apply, journal, backups. `Core.Ops` holds the scan/status orchestration that the agent and the standalone CLI both call. |
| `IPC` | `Codable` request/response/notification types (JSON), error codes, data-dir layout (`DataLayout`) and owner-only directory checks. |
| `Agent` | `AgentService`: job manager, resource locks, plan cache, approval store, run history, job journal, rotated and redacted logs. Transport-neutral: a transport authenticates the peer, then calls `handle(json:callerUid:)` or `watch(...)`. |
| `XPCTransport` | `AgentXPCServer` (an `XPCListener` on the Mach service) and `AgentXPCClient` (an `XPCSession`). |
| `AgentRegistration` | `SMAppService.agent(plistName:)` behind the `AgentRegistering` protocol, so tests use a fake backend. |
| `CLI` | `dotfilesync`, built on swift-argument-parser. An XPC client of the agent, with standalone fallback. |
| `dotfilesyncd`, `dotfilesync` | The two executables. Both are embedded in `DotfileSync.app`. |

- One agent per user. launchd starts at most one instance per Mach service, so there is no
  lock file.
- When a client uses the agent, the agent runs the job. With no agent running, the standalone
  fallback runs the same `Core.Ops` code in-process for `scan`, `status` and `plan`, and the CLI
  says which mode it used. `apply` has no standalone path: the journal, backups, locks and
  approvals live in the agent.
- The agent owns its jobs. When a client disconnects, its jobs keep running.
- Nothing listens on TCP or UDP, nothing runs as root, and no request carries an executable path
  or caller-supplied command.
- Minimum macOS is 26. There is no Linux or Windows build.

## 2. Registration (SMAppService)

The launchd definition ships inside the signed app bundle at
`DotfileSync.app/Contents/Library/LaunchAgents/com.jamallyons.dotfilesync.agent.plist`
(source: `App/LaunchAgents/`). Nothing is written to `~/Library/LaunchAgents`.

| Key | Value |
|---|---|
| `Label` | `com.jamallyons.dotfilesync.agent` |
| `BundleProgram` | `Contents/MacOS/dotfilesyncd` |
| `MachServices` | `com.jamallyons.dotfilesync.agent` |
| `AssociatedBundleIdentifiers` | `com.jamallyons.dotfilesync` (System Settings shows the app's name) |
| `ProcessType` | `Background` |

There is no `RunAtLoad` and no `KeepAlive`. launchd starts the agent on demand when a client looks
up its Mach service.

Registration states, as reported by `dotfilesync service status`:

| State | Meaning |
|---|---|
| `not_registered` | launchd does not know the agent. |
| `enabled` | Registered and allowed to run. |
| `requires_approval` | Registered, but the user must allow it in System Settings › General › Login Items. |
| `not_found` | The plist is not in the app bundle (for example, the CLI is running outside the installed app). |

`register()` is a no-op when the agent is already `enabled` or `requires_approval`.
`unregister()` is a no-op when nothing is registered. Unregistering removes only the launchd
registration: the data directory, the user's dotfiles and any repositories are left alone.

## 3. Authentication

Every message is authenticated twice:

1. **Code signing.** The listener and every accepted session carry a lightweight code
   requirement: the peer must be signed by the same Developer ID team as the agent
   (`TeamIdentifierMatchesCurrentProcess`) **and** carry one of the signing identifiers
   `com.jamallyons.dotfilesync` (the app) or `com.jamallyons.dotfilesync.dotfilesync` (the
   embedded CLI). Another program signed by the same team is refused. Rejected peers are logged
   to `xpc.log`. `dotfilesyncd --insecure-any-signer` turns this check off for ad-hoc-signed local
   builds only, and prints a warning when it does.
2. **Effective UID.** For each message, the agent reads the sender's effective UID from the XPC
   peer connection (`xpc_connection_get_euid`, which comes from the kernel audit token). No UID
   field exists in any request. `AgentService` refuses requests whose UID differs from its own
   `ownerUid` (`geteuid()` at startup). The client checks the reverse: if the agent's reply comes
   from a different UID, or its sender UID cannot be read, the client fails with `impostorAgent`.

The client also authenticates the agent before sending it anything that matters. Its XPC session
requires the peer to be signed by the same team and carry the signing identifier
`com.jamallyons.dotfilesync.dotfilesyncd`, so a same-user launchd job that takes the Mach name
cannot receive requests or approval tokens (`untrustedAgent`). On a new connection the client
first sends `ping` and checks the reply's UID; only then does it send the real request. Debug
builds of the CLI and app accept any agent signature when `DOTFILESYNC_INSECURE_ANY_AGENT=1` is
set (to talk to an ad-hoc agent started with `--insecure-any-signer`); release builds ignore it.

Before connecting, the client also checks (without creating or repairing) that any existing
data directories are private (§4). A missing data dir is not an error: looking up the Mach
service is what makes launchd start the agent, and the agent creates the directory on its
first run.

## 4. Data layout

The data root is `~/Library/Application Support/dotfilesync`. `--data-dir` or
`DOTFILESYNC_DATA_DIR` overrides it, and tests always use the override.

```
<data>/            0700  owned by the agent's user
  state/           0700
    jobs.jsonl          job journal (metadata only; no tokens, paths or plan bodies)
    runs/          0700
      <run_id>/         one apply attempt
        journal.jsonl     append-only step journal
        plan.json         copy of the plan that was applied
        meta.json         run id, plan id, job id, status (never an approval token)
  backups/         0700
    <run_id>/           files replaced by that run, relative to home
  logs/            0700
    dotfilesyncd.log    agent log, rotated: .1 .. .3, 1 MiB each
    xpc.log             transport log, same rotation
```

The agent creates these directories with mode 0700 and checks each with `lstat`, so symlinks are
not followed. It refuses a directory that is:

- a symlink or not a directory,
- not owned by the effective UID, or
- accessible to group or others (`mode & 0o077 != 0`).

It never loosens or silently repairs the permissions of a directory that already exists; the
error says which `chmod` to run. `scan` and `status` never create the data directory.

## 5. Wire format

Each XPC message is a dictionary that carries the IPC JSON as a UTF-8 string:

| Direction | Dictionary |
|---|---|
| client → agent | `{ "request": <Request JSON>, "watch_id": <uint64, only for streamed watches> }` |
| agent → client (reply) | `{ "outcome": <Outcome JSON> }` or `{ "watch_stopped": true }` |
| agent → client (during a watch) | `{ "watch_id": N, "notification": <Notification JSON> }`, answered by `{ "continue": <bool> }` |

Each request is answered on a worker queue, so a long `watch_job` does not block other requests
on the same session. A watch holds its worker for as long as it runs, so at most 16 watches
(`JobLimits.maxWatches`) run at once; more are refused with `busy`. Watch notifications are sent synchronously, one ack each. That keeps them in
order, applies back-pressure, and lets the agent notice a client that went away: the send fails,
the watch stops, and the job keeps running.

Requests are `{"op":"<name>","params":{...}}`, at most 64 KiB.

| op | Effect |
|---|---|
| `ping` | Liveness check |
| `daemon_info` | Version, pid, uptime, data dir, job counts |
| `start_job` | Start a typed job: `scan` or `status`, with absolute paths. Returns the job snapshot. |
| `job_status` | One job's snapshot |
| `list_jobs` | All jobs, including `interrupted` ones from the previous agent process |
| `job_progress` | Progress events with `seq > since_seq` (catch up after reconnecting) |
| `watch_job` | Stream progress notifications until the job finishes, then a final response |
| `job_result` | Typed result of a successful job (scan report, status report, plan, or apply run journal) |
| `cancel_job` | Request cancellation (idempotent) |
| `shutdown` | Graceful stop: cancel jobs, wait, exit |
| `plan.create` | Start a `plan` job. The result carries the plan and its `plan_id`. |
| `plan.approve` | Bind a single-use token to a stored plan. Params: `plan_id`, `digest` (the digest the client reviewed). Returns `{token, expires_at_ms}`. |
| `plan.apply` | Re-observe state, redeem `token`, start an `apply` job. Params: `plan_id`, `token`, `allow_sudo`. |
| `plan.resume` | Redeem a new token and continue a run. Params: `run_id`, `token`, `allow_sudo`. |
| `plan.runs` | List runs, including `interrupted` ones. |
| `plan.run_status` | One run's journal and status. |

Errors are `{code, message, details?}`. `approval_rejected` carries `details.reason`: one of
`unknown_token`, `expired`, `already_used`, `plan_mismatch`, `state_changed`, `wrong_owner`,
`entropy`. Clients decode unknown codes as `unknown`, so a newer agent can add codes.

The Homebrew binary comes from the agent's own configuration, never from a request:
`dotfilesyncd --brew-bin`, `DOTFILESYNC_BREW_BIN`, then PATH, `/opt/homebrew/bin/brew` and
`/usr/local/bin/brew`. The CLI's hidden `--brew-bin` test flag therefore forces standalone mode.

## 6. Jobs and locks

- **States:** `queued → running → succeeded | failed | cancelled`. A job journaled as started by a
  previous agent process, with no terminal record, is shown as `interrupted`.
- **Limits:** at most 16 active jobs (more returns `busy`), 64 finished jobs kept in memory, 256
  progress events per job, and a 120 s default command timeout.
- **Disconnect:** a closed session ends only that client's watch. Jobs stop through `cancel_job`
  or agent shutdown.
- **Cancellation:** sets the job's cancel flag. The command runner kills the brew process group it
  owns and the job never reports a partial result as success.
- **Locks:** scan, status and plan take shared locks on `homebrew` and `manifest:<path>`. Apply and
  resume take exclusive locks on `homebrew` and `home:<path>`. Locks are acquired in sorted order,
  which prevents deadlock, and waiting gives up when the job is cancelled.

## 7. Approvals

- **Binding:** plan id, resource (`home:<path>`), plan digest, the state fingerprint the plan was
  computed from, and the owner UID. The agent keeps the newest 32 plans in memory, plus plans
  reloaded from `state/runs/*/plan.json` so an interrupted run can be approved again.
- **Issuing:** `plan.approve` checks the client's digest against the stored plan, then returns a
  random 256-bit token with a 10-minute TTL. The store keeps only `sha256(token)`. Approving a new
  plan for the same home revokes older tokens for that home.
- **Redeeming:** `plan.apply` re-observes the machine and redeems against that fingerprint. A
  mismatch is `state_changed`. `plan.resume` checks against the fingerprint stored with the plan,
  because a partial apply has already changed the machine, but it still needs a new approval. Any
  failed redemption burns the token, so it cannot be retried with corrected inputs.
- **Storage:** tokens exist only in agent memory and in the caller's hands. They are never
  journaled or logged. An agent restart invalidates every approval.

### Touch ID gate (agent)

Before `plan.approve` issues a token, the agent itself asks for Touch ID, with the login password
as fallback (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`). The system shows the prompt
on the agent's behalf ("dotfilesyncd is trying to apply N dotfilesync changes to …"). Because the
check runs in the agent, it applies to every client: the app, and the CLI even with `--yes`
(the CLI's `[y/N]` prompt comes first). Resume needs a new approval, so it is gated too.

- A cancelled, failed or unavailable check refuses with `approval_rejected`,
  `details.reason = "user_presence"`, and no token is issued.
- The digest is checked first, so a stale or tampered plan never prompts.
- One prompt at a time: a second `plan.approve` while a prompt is open gets `busy`.

## 8. Apply, journal and backups

- Each step transition is fsynced to `<data>/state/runs/<run_id>/journal.jsonl`. A run whose steps
  were unfinished when the agent stopped is `interrupted` and can be continued with `plan.resume`.
- Before a copy or link replaces a target, the original goes to
  `<data>/backups/<run_id>/<path relative to home>.backup.YYYYmmdd_HHMMSS`. The agent first tries an
  APFS `clonefile(2)` (`CLONE_NOFOLLOW`, copy-on-write, keeps mode and ownership) and then removes
  the original. If cloning fails (`ENOTSUP` off APFS, `EXDEV` across volumes, a name collision),
  it falls back to `rename(2)`, and on `EXDEV` to a byte copy plus remove. Only files and symlinks
  are cloned.
- Details of planning and apply: [plan-apply.md](plan-apply.md).

## 9. Job journal and logs

- `jobs.jsonl` is append-only. Each record holds the job id, kind, event, status and time; no
  params, paths, results, tokens or subprocess output. At startup the agent marks unfinished jobs
  `interrupted` (they are never replayed) and compacts the journal to the newest 200 jobs.
- Every log line passes through `redact()`, which masks GitHub tokens (`ghp_`, `gho_`, `ghs_`,
  `ghu_`, `ghr_`, `github_pat_`), `Bearer` / `Basic` credentials, `key=value` pairs whose key looks
  like a password, secret, token or API key, and URL userinfo. The agent logs only event metadata.

## 10. `dotfilesyncd` options

| Option | Meaning |
|---|---|
| `--data-dir <DIR>` | Data directory |
| `--brew-bin <PATH>` | Homebrew executable |
| `--mach-service <NAME>` | Mach service to serve (default `com.jamallyons.dotfilesync.agent`) |
| `--insecure-any-signer` | Development only: skip the code-signing requirement. The UID check still applies. |
| `--dev-stdio` | Development and tests only: serve one IPC JSON request per stdin line instead of launchd |

SIGTERM and SIGINT request a graceful shutdown.

## 11. CLI

`scan`, `status` and `plan` take `--mode auto|daemon|standalone` (`agent` is a synonym for
`daemon`), default `auto`. `apply` always uses the agent.

| Mode | Behavior |
|---|---|
| `auto` | Uses the agent if it answers. Otherwise runs in-process and prints a one-line note on stderr. Permission and impostor failures are errors, never a silent fallback. |
| `daemon` | Requires the agent. `--detach` prints the job ID and returns. Ctrl-C detaches without cancelling. |
| `standalone` | Never contacts the agent. |

`dotfilesync service`:

| Command | Behavior |
|---|---|
| `install` | Registers the agent with SMAppService. Starts nothing. Prints a hint when approval is needed. |
| `start` | Looks up the Mach service, which makes launchd start the agent, and reports its pid. Requires `enabled`. |
| `stop` | Sends `shutdown` to a running agent. While registered, launchd starts it again on the next request. |
| `status [--json]` | Registration state, and whether the agent answers (version, pid, data dir). |
| `uninstall` | Unregisters. Keeps the data directory, configs and repositories. |
| `open-settings` | Opens System Settings › General › Login Items. |

`dotfilesync jobs list|show|watch|result|cancel` (`jobs follow` is an alias of `jobs watch`) and
`dotfilesync runs [list|show <id>]` reconnect to agent state.

## 12. Out of scope (later issues)

- Toolchains (#5), config editor (#11), sync (#6) and the FSEvents watcher (#7).
- A privileged helper via `SMAppService.daemon` for `sudo` steps.
- Crash auto-restart (`KeepAlive`).
