# DotfileSync.app

SwiftUI shell around the `DotfileSyncKit` package (`../Packages/DotfileSyncKit`). Hand-written
Xcode project using file-system-synchronized groups: new files under `DotfileSync/`, `Shared/` or
`DotfileSyncTests/` are picked up without editing `project.pbxproj`.

```sh
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Layout

| Path | Contents |
| --- | --- |
| `DotfileSync/` | `@main` entry point only (app target). |
| `Shared/` | Views, `AppModel`, `LiveAgentClient` (XPC), `UserPresenceGate` (Touch ID). Compiled into both targets. |
| `DotfileSyncTests/` | swift-testing tests with fake registration, agent and gate. |
| `Scripts/embed-agent-binaries.sh` | Run Script phase that builds and embeds the agent and CLI. |
| `LaunchAgents/` | The agent's launchd plist, copied to `Contents/Library/LaunchAgents/`. |

## Bundle

```
DotfileSync.app/Contents/
  MacOS/DotfileSyncApp                      app executable
  MacOS/dotfilesyncd                        agent (plist BundleProgram)
  MacOS/dotfilesync                         CLI
  Library/LaunchAgents/com.jamallyons.dotfilesync.agent.plist
```

- The app executable is `DotfileSyncApp`, not `DotfileSync`: on the default case-insensitive APFS
  volume `MacOS/DotfileSync` and `MacOS/dotfilesync` would be the same file.
- `dotfilesyncd`/`dotfilesync` are package *executable* products. Xcode can link package library
  products into a target but cannot build a package executable as a dependency of an app target
  or copy it into the bundle, so the Run Script phase runs `swift build --product …` (scrubbed
  environment, scratch dir under DerivedData, the target's `ARCHS`, debug/release matching the
  configuration) and copies the results with `ditto`.
- With signing enabled, the script re-signs both binaries with the app's identity and the
  hardened runtime: the agent's XPC listener only accepts peers signed by the same team.

## Tests

`DotfileSyncTests` is an unhosted unit-test bundle (no `TEST_HOST`): it compiles `Shared/` itself,
so `xcodebuild test` never launches the app, never touches SMAppService/launchd and never shows a
Touch ID prompt. Everything with side effects sits behind a protocol: `AgentRegistering`
(package), `AgentClient`, `UserPresenceGate`.

## Needs a human

- A signed build (set a team in Xcode; signing is `Automatic` with no team checked in).
- Register from the app, approve the agent under System Settings → General → Login Items, then
  confirm the status view shows the agent version.
- The Touch ID / password prompt before Apply, and an apply against a throwaway home.
