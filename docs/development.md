# Building and developing dotfilesync

## Requirements

- macOS 26 and Xcode 26 or newer.
- For an installable app: an Apple ID added under Xcode → Settings → Accounts. A free account
  works. Then open `App/DotfileSync.xcodeproj` and pick your team under the DotfileSync target's
  **Signing & Capabilities**. Xcode writes the team into the project file; keep that change local.

## Build and install the signed app

With [just](https://just.systems) (`brew install just`), run `just` to list recipes:

| Recipe | Does |
|---|---|
| `just local-install` | Signed Release build, replaces `/Applications/DotfileSync.app`, links the CLI to `~/.local/bin/dotfilesync`, registers the agent, opens the app |
| `just uninstall-local` | Removes the app, CLI link, agent registration, preferences, TCC grants and `~/Library/Application Support/dotfilesync` (`--yes` skips the prompt). Dotfiles and manifest are kept |
| `just status` / `just logs` | What is installed; tail the agent log |
| `just ci` | Package and app build + tests, as CI runs them |

The signing team comes from `DEVELOPMENT_TEAM` or your Apple Development certificate.
`DOTFILESYNC_INSTALL_DIR`, `DOTFILESYNC_BIN_DIR`, `DOTFILESYNC_NO_OPEN=1` and
`DOTFILESYNC_SKIP_REGISTER=1` adjust `local-install`.

By hand:

```sh
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates build
rm -rf /Applications/DotfileSync.app
ditto build/DerivedData/Build/Products/Release/DotfileSync.app /Applications/DotfileSync.app
```

The app bundle contains the CLI (`Contents/MacOS/dotfilesync`), the background agent
(`dotfilesyncd`) and its launchd definition. The agent only talks to the app and CLI signed by
the same team, so an unsigned build cannot apply changes.

## Run the tests

```sh
cd Packages/DotfileSyncKit
swift build --build-tests -Xswiftc -warnings-as-errors
swift test

cd ../..
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test
```

The tests use temporary folders, a fake `brew` and a fake launchd registration. They never touch
your home folder, Homebrew or launchd.

## Code layout

| Path | Contents |
|---|---|
| `Packages/DotfileSyncKit/Sources/Core` | Manifest, profiles, Brewfile parser, Homebrew discovery, scan, status, plan, apply, journal, backups |
| `Packages/DotfileSyncKit/Sources/IPC` | Request and response types, data folder layout |
| `Packages/DotfileSyncKit/Sources/Agent` | Jobs, locks, approvals, Touch ID, run history, logs |
| `Packages/DotfileSyncKit/Sources/XPCTransport` | XPC listener and client |
| `Packages/DotfileSyncKit/Sources/AgentRegistration` | Registering the agent with launchd (SMAppService) |
| `Packages/DotfileSyncKit/Sources/CLI` | The `dotfilesync` commands |
| `App/` | Xcode project, SwiftUI app, the agent's launchd plist |
| `fixtures/` | Test inputs shared by the Swift tests |

More detail: [architecture](daemon-architecture.md), [plan and apply](plan-apply.md), and the
[manual QA checklist](daemon-manual-qa.md) for a signed build.
