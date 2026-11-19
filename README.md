# dotfile-sync

Set up a Mac for coding from one repo: Homebrew apps and tools, Fish shell, and editor settings.

This repo gives you two ways to do it:

| | What it is | Use it when |
|---|---|---|
| **dotfilesync** | A Mac app and command-line tool | You want to see what will change before anything happens, with backups. |
| **`setup.sh`** | A shell script | You are on a brand-new Mac, or you want Node, Xcode or Homebrew itself installed. |

## dotfilesync

dotfilesync compares your Mac with the list in [`dotfilesync.toml`](dotfilesync.toml) and fixes
the differences, but only after you say yes.

1. **`status`** shows what is missing or different. It changes nothing.
2. **`plan`** lists exactly what it would do.
3. **`apply`** does it, after you confirm and approve with Touch ID. Every file it replaces is
   backed up first.

### Install

You need macOS 26, Xcode and a free Apple ID. Follow [Building](docs/development.md) to build
and install `DotfileSync.app`, then:

```sh
alias dotfilesync=/Applications/DotfileSync.app/Contents/MacOS/dotfilesync

dotfilesync service install         # one time: register the background helper
dotfilesync service open-settings   # if asked: switch DotfileSync on under Login Items
```

### Use

From this folder:

```sh
dotfilesync status --manifest dotfilesync.toml   # what is different?
dotfilesync plan                                  # what would change?
dotfilesync apply                                 # make the changes
```

Prefer clicking? Open **DotfileSync** from Applications. It does the same thing.

## setup.sh

```sh
bash ./setup.sh             # install everything
bash ./setup.sh --dry-run   # only show what it would do
```

It installs Homebrew, the apps in [`Brewfile`](Brewfile), Fish with the Tide prompt, Node, Xcode
and the Zed settings. Flags, custom Fish commands and details: [setup.sh guide](docs/setup-sh.md).

## Documentation

| Guide | For |
|---|---|
| [CLI manual](docs/cli.md) | Every dotfilesync command, where backups go, troubleshooting |
| [Manifest reference](docs/manifest.md) | Editing `dotfilesync.toml`: apps, files, profiles |
| [setup.sh guide](docs/setup-sh.md) | Script flags, Fish commands, fonts, Node, Zed |
| [Building and developing](docs/development.md) | Building the app, running tests, code layout |
| [Plan and apply](docs/plan-apply.md) | How approvals, backups and resuming work |
| [Config editor](docs/config-editor.md) | Config discovery, safe in-app editing, working-tree status and diff, promote/demote, highlighting coverage |
| [Architecture](docs/daemon-architecture.md) | How the app, helper and CLI fit together; security |

## License

Apache-2.0
