# dotfilesync CLI manual

`dotfilesync` keeps a Mac in line with a manifest, `dotfilesync.toml`: which Homebrew packages
should be installed and which config files should be in place. It shows you what is different,
plans the changes, and applies them only after you approve.

- [Install](#install)
- [Concepts](#concepts)
- [Everyday workflow](#everyday-workflow)
- [Command reference](#command-reference)
- [Files and data](#files-and-data)
- [Troubleshooting](#troubleshooting)

## Install

The CLI ships inside `DotfileSync.app`. Build and install the signed app (see the
[README quick start](../README.md#quick-start)), then put the CLI on your path:

```sh
# zsh / bash
alias dotfilesync=/Applications/DotfileSync.app/Contents/MacOS/dotfilesync
# fish
alias --save dotfilesync=/Applications/DotfileSync.app/Contents/MacOS/dotfilesync
```

Register the background agent once. It is needed for `apply` and runs only when something asks
for it:

```sh
dotfilesync service install        # register with launchd
dotfilesync service open-settings  # if asked: turn DotfileSync on under Login Items
dotfilesync service start          # check it answers
```

## Concepts

**Manifest.** `dotfilesync.toml` declares Homebrew formulae and casks, tracked files (a `source`
in the repo and a `target` on the machine), exclusions, machine-local overrides and optional
profiles such as `personal` and `work`. Full schema: [manifest.md](manifest.md).

**Agent.** `dotfilesyncd` is a per-user background process that launchd starts on demand. It
runs jobs, holds locks, keeps run history and backups, and asks for Touch ID before any change.
It only talks to the signed app and CLI from the same developer team, running as you. Nothing
listens on the network.

**Plan and apply.** `plan` lists the actions that would bring the machine in line, each with a
risk level (`low`, `medium`, `high`) and whether it can be undone (`rev`). `apply` re-plans,
shows you the plan, asks `[y/N]`, then asks for Touch ID. The approval is tied to that exact
plan and to the machine's current state, so if anything changes in between, nothing runs.

**Jobs and runs.** Every agent operation is a *job* (`j-…`). Each apply also records a *run*
(`r-…`) with its journal and backups.

**Read-only commands.** `scan` and `status` never change anything and never print file contents.

## Everyday workflow

```sh
cd ~/path/to/your/dotfiles               # the folder with dotfilesync.toml
dotfilesync status --manifest dotfilesync.toml   # what differs?
dotfilesync plan                         # what would change?
dotfilesync apply                        # review, y, Touch ID
dotfilesync runs list                    # history
```

Start a new manifest from an existing Brewfile:

```sh
dotfilesync import-brewfile --brewfile Brewfile --output dotfilesync.toml
```

Try a change against a throwaway home before touching your real one:

```sh
dotfilesync plan  --home ~/dfs-test/home
dotfilesync apply --home ~/dfs-test/home
```

## Command reference

Global option, accepted before or after the subcommand:

| Option | Meaning |
|---|---|
| `--data-dir <dir>` | Agent data directory. Default: `$DOTFILESYNC_DATA_DIR`, else `~/Library/Application Support/dotfilesync`. |
| `--version` | Print the version. |
| `-h`, `--help` | Help for any command, e.g. `dotfilesync apply --help`. |

Options shared by `scan`, `status`, `plan` and `apply`:

| Option | Meaning |
|---|---|
| `--manifest <path>` | The manifest. Defaults to `./dotfilesync.toml` for `plan` and `apply`. Required for `status`, optional for `scan`. |
| `--home <dir>` | Use another folder as the home directory. Handy for dry runs against a test folder. |
| `--repo-root <dir>` | Where tracked `source` paths are resolved. Defaults to the manifest's folder. |
| `--profile <name>` | `plan` and `apply` only. Omit it to use `[select]` in the manifest, or the base layer. |
| `--json` | Machine-readable output (not on `apply`). |

`scan`, `status` and `plan` also take `--mode`:

| `--mode` | Behaviour |
|---|---|
| `auto` (default) | Use the agent if it answers, otherwise run in this process and say so on stderr. |
| `daemon` (or `agent`) | Require the agent. With `--detach` (`scan`, `status`), print the job ID and return. |
| `standalone` | Never contact the agent. Works with an unsigned debug build. |

### `scan`

```sh
dotfilesync scan [--manifest dotfilesync.toml] [--json]
```

Lists installed Homebrew formulae and casks and inspects the files the manifest tracks.
Read-only.

### `status`

```sh
dotfilesync status --manifest dotfilesync.toml [--json]
```

Compares the manifest with the machine. Each package and file gets one state:

| State | Meaning |
|---|---|
| `matching` | Same on the machine as in the repo. |
| `missing` | Declared but not on the machine. A missing machine-local override is listed separately. |
| `changed` | The file's content differs from the repo. |
| `unmanaged` | On the machine but not in the manifest. Not necessarily unwanted. |
| `unknown` | Could not tell: Homebrew unavailable, or the file is unreadable. |
| `skipped` | Excluded or machine-local. Left alone, never counted as matching. |

### `plan`

```sh
dotfilesync plan [--manifest dotfilesync.toml] [--profile NAME] [--json]
```

Prints the actions an apply would take, for example:

```text
Plan p-9af679612b1b8174 (profile base)
[medium] [rev] [copy] copy ~/dotfiles/test.conf -> ~/.config/test/test.conf

1 action: low 0, medium 1, high 0; reversible 1, irreversible 0
```

Changes nothing. `No changes. The system matches the manifest.` means you are in sync.

### `apply`

```sh
dotfilesync apply [--manifest dotfilesync.toml] [--profile NAME] [--yes] [--allow-sudo] [--dry-run]
dotfilesync apply --resume <run_id>
```

Plans, shows the plan, asks `Apply N actions? [y/N]`, then asks for Touch ID (or your password)
and runs the plan in the agent. Requires the agent.

| Option | Meaning |
|---|---|
| `--yes` | Skip the `[y/N]` question. Touch ID is still required. |
| `--dry-run` | Print the plan and exit. Never applies. |
| `--allow-sudo` | Allow the login-shell step to run `chsh`. Never implied. |
| `--resume <run_id>` | Continue a run that stopped before every step finished. |

Every file that is replaced is backed up first. Machine-local overrides are never overwritten.
Ctrl-C detaches from the output; the apply keeps running in the agent. Reconnect with
`dotfilesync jobs watch <job_id>`.

### `import-brewfile`

```sh
dotfilesync import-brewfile --brewfile Brewfile [--output dotfilesync.toml] [--json]
```

Reads a Brewfile without running it and reports the `brew` and `cask` entries it found, plus any
lines it could not import (options, `tap`, `mas`, conditionals, Ruby code) with line numbers.
With `--output`, writes a new manifest; it refuses to overwrite an existing file.

### `runs`

```sh
dotfilesync runs [list] [--json]   # every apply, oldest first
dotfilesync runs show <run_id> [--json]
```

`show` prints the run's journal: each action's steps and outcome.

### `jobs`

```sh
dotfilesync jobs list [--json]              # all jobs, including interrupted ones
dotfilesync jobs show <job_id> [--json]     # status of one job
dotfilesync jobs watch <job_id> [--since N] # follow progress until it finishes (alias: follow)
dotfilesync jobs result <job_id> [--json]   # the report of a finished job
dotfilesync jobs cancel <job_id>            # stop a job and its subprocesses
```

### `service`

```sh
dotfilesync service install        # register the agent with launchd; starts nothing
dotfilesync service open-settings  # open System Settings → General → Login Items
dotfilesync service start          # start it now and check it answers
dotfilesync service status [--json] # registration state and whether it answers
dotfilesync service stop           # shut it down; launchd restarts it on the next request
dotfilesync service uninstall      # unregister; keeps your data, configs and repos
```

Run these with the CLI inside the installed app. A copy outside the app bundle reports the agent
as not found.

## Files and data

The agent keeps everything in `~/Library/Application Support/dotfilesync` (private to you,
mode 0700):

| Path | Contents |
|---|---|
| `state/jobs.jsonl` | Job history (metadata only). |
| `state/runs/<run_id>/` | Each apply's journal and a copy of its plan. |
| `backups/<run_id>/` | Files that run replaced, e.g. `.config/app/app.conf.backup.20261115_201532`. |
| `logs/dotfilesyncd.log`, `logs/xpc.log` | Agent and connection logs, rotated and redacted. |

To restore a file, copy it back from `backups/<run_id>/`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | The command failed. The reason is on stderr. |
| `2` | Bad usage (unknown flag, missing argument). |

## Troubleshooting

| Message | What to do |
|---|---|
| `dotfilesync agent is not running (...)` | Run `dotfilesync service status`, then `service install` and `service start`. |
| `registered, waiting for approval` | Turn DotfileSync on in System Settings → General → Login Items (`service open-settings`). |
| `user presence was not confirmed` | Touch ID was cancelled or unavailable. Nothing was changed; run `apply` again. |
| Calls fail and `logs/xpc.log` says `rejected peer` | You are using an unsigned or foreign build. Use `/Applications/DotfileSync.app/Contents/MacOS/dotfilesync`, or pass `--mode standalone` for read-only commands. |
| The plan changed between review and approval | Something on the machine changed. Run `apply` again to review the new plan. |

How the agent works inside: [daemon-architecture.md](daemon-architecture.md). How plans and
approvals work: [plan-apply.md](plan-apply.md).
