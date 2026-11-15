# dotfile-sync

**Repo:** [https://github.com/JamalLyons/dotfile-sync](https://github.com/JamalLyons/dotfile-sync)

This repository holds two things:

1. **dotfilesync**: a macOS app, background agent and CLI written in Swift. It compares
   [`dotfilesync.toml`](dotfilesync.toml) with the machine and applies a reviewed plan, with
   Touch ID approval and backups. **To try it, follow [docs/testing.md](docs/testing.md).**
   Details are in [dotfilesync](#dotfilesync-macos-environment-manager) below.
2. **`setup.sh`**: the original shell bootstrap (Homebrew, Fish, Tide, fnm, Xcode, Zed settings).
   It still works and stays until dotfilesync covers the same ground.

## Shell bootstrap (`setup.sh`)

Brewfile-driven macOS coding environment bootstrap: Fish shell, Tide prompt, fnm (Node), and the CLI/GUI tools you declare in a Brewfile.

### Quick start

```bash
bash ./setup.sh
```

Useful flags:

```bash
bash ./setup.sh --dry-run       # preview only
bash ./setup.sh --skip-casks    # formulas only (no GUI apps)
bash ./setup.sh --skip-shell    # keep your current login shell
bash ./setup.sh --skip-xcode    # skip latest Xcode download/install
bash ./setup.sh --skip-fonts    # skip 0xProto font cask
bash ./setup.sh --skip-zed      # skip Zed settings sync
bash ./setup.sh --skip-models   # skip LM Studio model downloads
```

### What it does

1. Installs Homebrew if missing
2. Applies [`Brewfile`](Brewfile) (CLI formulas + casks)
3. Installs **0xProto** via Homebrew `font-0xproto` (prefer [2.502](https://github.com/0xType/0xProto/releases/tag/2.502); still runs after `--skip-casks` unless `--skip-fonts`)
4. Syncs checked-in [`fish/`](fish/) templates into `~/.config/fish` (backs up changed files)
5. Installs Fisher + plugins (Tide, done, bass)
6. Syncs checked-in [`zed/settings.json`](zed/settings.json) into `~/.config/zed/settings.json` (prompts before overwrite if a different file already exists)
7. Installs **Node.js LTS** via [fnm](https://github.com/Schniz/fnm) and enables **pnpm** via Corepack
8. Installs the **latest Xcode** via [xcodes](https://github.com/XcodesOrg/xcodes) (Apple ID may be required; large download)
9. Downloads preferred local models via **LM Studio CLI** (`lms get`)
10. Optionally sets Fish as your login shell

### Layout

```
dotfile-sync/
├── setup.sh              # Thin orchestrator
├── Brewfile              # Declarative packages + casks
├── lib/
│   ├── log.sh
│   ├── brew.sh
│   ├── fonts.sh
│   ├── fish.sh
│   ├── node.sh
│   ├── xcode.sh
│   ├── zed.sh
│   └── models.sh
├── fish/
│   ├── config.fish
│   ├── fish_plugins
│   ├── conf.d/fnm.fish
│   └── functions/
├── zed/
│   └── settings.json     # Global Zed editor settings
├── dotfilesync.toml      # dotfilesync manifest (see below)
├── Packages/DotfileSyncKit/  # dotfilesync: SwiftPM package (agent, CLI, core)
├── App/                  # dotfilesync: SwiftUI app (Xcode project, LaunchAgents plist)
├── fixtures/             # Golden test inputs shared by the Swift tests
├── docs/
└── README.md
```

### Adding software

- **CLI / Homebrew apps:** edit `Brewfile`, then re-run `bash ./setup.sh` (or `brew bundle --file=Brewfile`).
- **Fish plugins:** edit `fish/fish_plugins`, then re-run setup (or `fisher update` in Fish).
- **Fish config / functions:** edit files under `fish/`, then re-run setup to sync.
- **Zed settings:** edit [`zed/settings.json`](zed/settings.json), then re-run setup to sync to `~/.config/zed/settings.json`.

#### Local environment variables

Shared config must not contain secrets. Setup creates (once):

```text
~/.config/fish/conf.d/local.fish
```

from the documented empty template [`fish/conf.d/local.fish`](fish/conf.d/local.fish). Later `setup.sh` runs **never overwrite** that file. Put project IDs, tokens, and machine-only paths there (`editenv`), then `reload`.

#### GUI apps (casks)

Included today (matched to `/Applications` where a cask exists):

- Ghostty, Zed, Raycast, LLM-Studio, Rectangle, JetBrains Toolbox
- Discord, Lark, Docker Desktop, Brave, Chrome, Spotify, OBS
- GitHub Desktop, Cursor, Claude, DBeaver, Inkscape, MEGAsync
- Steam, Audacity, Cloudflare WARP, eqMac, pgAdmin 4
- Antigravity, Google Gemini, Juicy, Epic Games, Minecraft, Roblox
- Windows App, melonDS

**No Homebrew cask** (install/update manually or via Mac App Store):

- Blackmagic Proxy Generator Lite, Blackmagic RAW, DaVinci Resolve
- VMware Fusion, LockDown Browser, Magic Garden, Developer (WWDC)
- Keynote, Numbers, Pages, Safari, Xcode
- Python 3.13.app (python.org; CLI Python is covered by Brewfile `python`)

Full **Xcode** is installed by `setup.sh` via `xcodes` (not a Homebrew cask). Use `--skip-xcode` to skip.

#### Fonts

**0xProto** is installed with Homebrew cask `font-0xproto` (user fonts under `~/Library/Fonts`). Preferred release: **2.502** (see `OXPROTO_PREFERRED_VERSION` in [`lib/fonts.sh`](lib/fonts.sh)). Setup still installs it when you pass `--skip-casks`; use `--skip-fonts` to skip. Ghostty, Zed, and other apps need the font selected in their settings after install.

#### Zed settings

Global Zed config lives in [`zed/settings.json`](zed/settings.json) and installs to `~/.config/zed/settings.json`.

- Missing destination → copies the template quietly
- Identical to template → skips
- Different existing file → warns and asks `Overwrite? [y/N]` (default **N**); only overwrites on `y`/`Y`
- Use `--skip-zed` to skip; `DRY_RUN=1` / `--dry-run` prints intent without writing or prompting to overwrite

#### Updating packages

Homebrew formulae and casks are updated through [Vorssaint](https://github.com/vorssaint/vorssaint-utils) (App updates / Homebrew manager). In Fish, run `fisherup` to update Fisher plugins.

### Node via fnm

This setup uses **fnm**, not nvm / nvm.fish.

- Default: latest **LTS** (`fnm install --lts`)
- Per-project: `.node-version` or `.nvmrc` with `fnm env --use-on-cd`

```fish
fnm list
fnm install lts
fnm use 22
```

If you previously used nvm, `~/.nvm` is left alone. After confirming fnm works you can remove it and `brew uninstall nvm` if present.

### Prompt

Uses [Tide](https://github.com/IlanCosman/tide) (`ilancosman/tide@v6`). Configure with `tide configure`.

### Custom Fish commands

In Fish, run `helpme` for the full list. Highlights:

| Command | Description |
|---------|-------------|
| `helpme` | List custom commands (links to this repo) |
| `fisherup` | Update Fisher plugins |
| `reload` | Reload Fish config |
| `editfish` | Open config in `$EDITOR` |
| `editenv` | Open `~/.config/fish/conf.d/local.fish` in `$EDITOR` |
| `mkcd <dir>` | mkdir + cd |
| `extract <file>` | Unpack common archives |
| `ff` / `fdir` | Find files / directories |
| `ql <file>` | Quick Look |
| `cdf` | cd to frontmost Finder window |
| `flushdns` | Flush macOS DNS cache |
| `path` | Print `$PATH` one entry per line |
| `serve [port]` | Python HTTP server |
| `note [text]` | Quick notes |

Git abbreviations: `gst`, `gco`, `gaa`, `gcm`, `gps`, `gpl`, …

### Requirements

- macOS
- Network access (Homebrew, Fisher, fnm)
- Git (usually via Xcode CLT / Homebrew)


## dotfilesync (macOS environment manager)

`dotfilesync` is a macOS-native developer environment manager written in Swift. It compares `dotfilesync.toml` with the machine and, after you review and approve a plan, brings the machine in line. `scan` and `status` stay read-only. `plan` and `apply` change the machine only after you review a plan. `import-brewfile` creates a new manifest and refuses to overwrite an existing file.

Manifest profiles and the plan/apply workflow are documented in [docs/manifest.md](docs/manifest.md) and [docs/plan-apply.md](docs/plan-apply.md). `setup.sh` remains until that workflow covers the same ground.

### Architecture

The install unit is `DotfileSync.app`. It embeds the per-user agent `dotfilesyncd`, the `dotfilesync` CLI, and the agent's launchd definition.

- **`dotfilesyncd`**: per-user launch agent, registered with `SMAppService.agent` (it shows in System Settings › General › Login Items) and started on demand by launchd. It serves XPC on the Mach service `com.jamallyons.dotfilesync.agent`, accepts only the app and CLI (same team, pinned signing identifiers) running as the same user, asks for Touch ID before it approves an apply, and owns jobs, locks, single-use approvals, run history, backups and logs. Nothing listens on the network.
- **`dotfilesync`**: CLI with human and `--json` output. An XPC client of the agent, with a standalone fallback for `scan`, `status` and `plan`. `apply` always goes through the agent.
- **DotfileSync.app**: SwiftUI front end for scan, status, plan and apply.

| Path | Contents |
|---|---|
| `Packages/DotfileSyncKit/Sources/Core` | Manifest, profiles, Brewfile parser, brew discovery, scan, status, plan, apply, journal, `clonefile` backups |
| `Packages/DotfileSyncKit/Sources/IPC` | Codable request/response types, data-dir layout |
| `Packages/DotfileSyncKit/Sources/Agent` | Jobs, locks, approvals, run history, logs |
| `Packages/DotfileSyncKit/Sources/XPCTransport` | XPC listener and client |
| `Packages/DotfileSyncKit/Sources/AgentRegistration` | SMAppService registration |
| `Packages/DotfileSyncKit/Sources/CLI` | `dotfilesync` commands (swift-argument-parser) |
| `App/` | Xcode project, SwiftUI app, `LaunchAgents/com.jamallyons.dotfilesync.agent.plist` |

See [docs/daemon-architecture.md](docs/daemon-architecture.md) for the process, XPC, security and state model.

### Building

Requires **macOS 26** and Xcode with Swift 6.2.

```bash
# Package: build and run the tests (fixture-isolated; never touches your HOME or launchd)
cd Packages/DotfileSyncKit
swift build --build-tests
swift test

# App (unsigned build, as in CI)
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test
```

The agent's peer check needs a signed app with a team ID; see [docs/daemon-manual-qa.md](docs/daemon-manual-qa.md) for building and testing a signed app. Step-by-step instructions for trying the CLI, the app, the agent and apply are in
[docs/testing.md](docs/testing.md).

### CLI commands

`scan` and `status` are strictly **read-only**. They never install software, uninstall packages, modify shell or environment files, or change system settings. `import-brewfile --output <path>` creates a **new** file and refuses to replace an existing one. `plan` and `apply` are the commands that change the machine.

```bash
dotfilesync scan [--manifest dotfilesync.toml] [--json]
dotfilesync status --manifest dotfilesync.toml [--json]
dotfilesync import-brewfile --brewfile Brewfile --output dotfilesync.new.toml
dotfilesync plan [--manifest] [--profile NAME] [--json]
dotfilesync apply [--manifest] [--profile NAME] [--yes] [--allow-sudo] [--dry-run]
dotfilesync apply --resume <run_id>
dotfilesync runs [list|show <id>]
dotfilesync jobs list|show|watch|result|cancel   # `jobs follow` = `jobs watch`
dotfilesync service install|uninstall|start|stop|status|open-settings
```

`status` classifies each difference:

- **`matching`**: verified equivalence between repository source and machine target.
- **`missing`**: declared in the manifest but absent from the machine. An absent machine-local override is shown separately from an ordinary missing config.
- **`changed`**: config drift (the content hash differs).
- **`unmanaged`**: present on the machine but not declared in the manifest (not the same as unwanted).
- **`unknown`**: Homebrew is unavailable or enumeration failed (so an unavailable tool never claims every package is missing), or a config file is unreadable.
- **`skipped`**: excluded paths and machine-local overrides. They are preserved and never counted as matching.

`import-brewfile` parses a Brewfile statically, without running Ruby. Plain `brew` and `cask` lines are captured; options and dynamic constructs (`if`, `unless`, `def`, `system`, `ENV`, interpolation, `mas`, `tap`, trailing expressions) are reported with line numbers.

`scan`, `status` and `plan` take `--mode auto|daemon|standalone` (`agent` is a synonym for `daemon`):

| Mode | Behavior |
|---|---|
| `auto` | Runs in the agent when it answers. Otherwise runs in-process and prints a one-line note on stderr. |
| `daemon` | Requires the agent. Add `--detach` to print the job ID and return. |
| `standalone` | Never contacts the agent. |

Agent jobs keep running when the CLI exits (Ctrl-C only detaches). Reconnect from any terminal with `dotfilesync jobs watch <job-id>`.

### Agent setup

```bash
dotfilesync service install        # register with SMAppService; starts nothing
dotfilesync service open-settings  # allow DotfileSync in Login Items if status says so
dotfilesync service status         # registration state + whether the agent answers
dotfilesync service stop           # shut down now; launchd restarts it on the next request
dotfilesync service uninstall      # unregister; keeps state, logs, configs and repos
```

Run these with the `dotfilesync` inside the installed app (`DotfileSync.app/Contents/MacOS/dotfilesync`); outside the app bundle the status is `not_found`.

The agent keeps its state in `~/Library/Application Support/dotfilesync` (mode 0700; override with `--data-dir` or `DOTFILESYNC_DATA_DIR`):

| Path | Contents |
|---|---|
| `state/jobs.jsonl` | Job metadata only |
| `state/runs/<run_id>/` | Apply journal and plan copy |
| `backups/<run_id>/` | Files replaced by that run (APFS clones) |
| `logs/` | Rotated, redacted logs |

### Manifest (`dotfilesync.toml`)

The repository includes a versioned `dotfilesync.toml` (schema version 1) modeling the current `Brewfile`, `fish/` configuration and `zed/settings.json`, plus `personal` and `work` profiles. Reference: [docs/manifest.md](docs/manifest.md).

- **Explicit tracking**: separate repository `source` and machine `target` paths.
- **Exclusions**: explicit paths and glob patterns (`*.backup.*`, `*.key`, `*secret*`, `*credential*`) are left out of drift checks.
- **Machine-local overrides**: files like `~/.config/fish/conf.d/local.fish` are preserved and never overwritten.
- **Credential protection**: validation refuses to track sensitive paths like `~/.ssh/id_*`, `~/.aws/credentials` or `~/.gnupg`.

### Safety

- `scan` and `status` are read-only and never print file contents. `import-brewfile` writes only with `--output`, and only a new file.
- `apply` runs only a reviewed, approved plan. Approvals are single-use tokens bound to the plan digest and observed state, with a 10-minute lifetime. It backs up every file it replaces, refuses to overwrite local overrides, and never runs `sudo` unless `--allow-sudo` is set.
- Tests run against temp directories, fake `brew` and a fake SMAppService backend; they never touch your HOME, your data directory or launchd.

### Current limitations

- **Still on `setup.sh`**: installing Homebrew itself, Node via fnm and pnpm, the latest Xcode and LM Studio models are not plan actions yet (issue #5).
- **Out of scope for now**: toolchains beyond Homebrew, config editing, state sync, the FSEvents watcher, a privileged helper for `sudo` steps, and crash auto-restart (no `KeepAlive`).
- **macOS only**: XPC and SMAppService exist only on macOS; there is no Linux build.

## License

Apache-2.0
