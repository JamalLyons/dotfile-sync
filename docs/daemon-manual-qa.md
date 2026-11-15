# dotfilesyncd manual QA (macOS)

The automated tests use temp data directories, a fake `brew`, a fake SMAppService backend and
anonymous XPC listeners. This checklist covers what they cannot: a signed app registered with the
real launchd through SMAppService, the code-signing peer check, and the Touch ID gate. Run it as
a normal user, never with `sudo`.

## 0. Build a signed app

The same-team peer requirement needs a Developer ID (or Apple Development) signature with a team
ID. An ad-hoc build (`CODE_SIGNING_ALLOWED=NO`) is fine for CI but cannot pass §3.

```bash
xcodebuild -project App/DotfileSync.xcodeproj -scheme DotfileSync \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/DotfileSync.app /Applications/
alias dotfilesync=/Applications/DotfileSync.app/Contents/MacOS/dotfilesync
```

| Step | Command | Expected |
|---|---|---|
| 0.1 | `codesign -dv --verbose=2 /Applications/DotfileSync.app 2>&1 \| grep TeamIdentifier` | A real team ID, not `not set`. |
| 0.2 | `codesign -dv /Applications/DotfileSync.app/Contents/MacOS/dotfilesyncd 2>&1 \| grep TeamIdentifier` | The same team ID. Same for `Contents/MacOS/dotfilesync`. |
| 0.3 | `plutil -lint /Applications/DotfileSync.app/Contents/Library/LaunchAgents/com.jamallyons.dotfilesync.agent.plist` | `OK`. No `RunAtLoad`, no `KeepAlive`. |

## 1. Not registered

| Step | Command | Expected |
|---|---|---|
| 1.1 | `dotfilesync service status` | `Agent registration (SMAppService com.jamallyons.dotfilesync.agent.plist): not registered`, then `Agent: not running (...)`. |
| 1.2 | `dotfilesync scan` | Succeeds. stderr has a one-line note that the scan ran standalone. |
| 1.3 | `dotfilesync scan --mode agent` | Fails and explains how to register the agent. |
| 1.4 | `dotfilesync apply --dry-run` | Prints the plan and does not apply. `apply` without `--dry-run` fails: it needs the agent. |

## 2. Register and approve in Login Items

| Step | Command | Expected |
|---|---|---|
| 2.1 | `dotfilesync service install` | `Registered: com.jamallyons.dotfilesync.agent.plist`, and says the agent was not started. If macOS asks for approval: `Approval needed: allow it in System Settings → General → Login Items`. |
| 2.2 | `dotfilesync service status` | `registered, waiting for approval` or `registered and enabled`. |
| 2.3 | `dotfilesync service open-settings` | System Settings opens on General › Login Items. DotfileSync is listed under background items. Turn it on. |
| 2.4 | `dotfilesync service status --json` | `"registration": "enabled"`. |
| 2.5 | `dotfilesync service install` | `Already registered (unchanged)`. |

## 3. Start on demand, peer checks

| Step | Command | Expected |
|---|---|---|
| 3.1 | `dotfilesync service start` | `dotfilesyncd 0.1.0 is running (pid N).` |
| 3.2 | `dotfilesync service status` | `Agent: running (dotfilesyncd 0.1.0, pid N, data ~/Library/Application Support/dotfilesync)`. |
| 3.3 | `stat -f '%Sp %Su' ~/Library/Application\ Support/dotfilesync{,/state,/backups,/logs}` | `drwx------`, owned by you. |
| 3.4 | `lsof -nP -a -p <pid> -i` | No output: no TCP or UDP sockets. |
| 3.5 | Copy `Contents/MacOS/dotfilesync` elsewhere, `codesign --force -s - <copy>`, run `<copy> scan --mode agent` | Rejected (the peer is not from the same team). `logs/xpc.log` has a `rejected peer` warning. |
| 3.6 | `dotfilesync status --manifest dotfilesync.toml --detach` | Prints a job ID. |
| 3.7 | Close the terminal, open a new one, run `dotfilesync jobs watch <id>` | Shows the job's progress and ends with `succeeded`. |
| 3.8 | `dotfilesync jobs result <id>` | The status report. |

## 4. Apply with Touch ID

Use a throwaway profile or manifest whose plan only touches files you can lose; the agent backs
up anything it replaces, but do not test on files you care about.

| Step | Action | Expected |
|---|---|---|
| 4.1 | Open DotfileSync.app, review the plan, press Apply | Touch ID prompt. Cancel it: nothing is applied and no run appears in `dotfilesync runs list`. |
| 4.2 | Press Apply again and authenticate | The apply job runs. `dotfilesync runs list` shows the run `succeeded`. |
| 4.3 | `ls ~/Library/Application\ Support/dotfilesync/backups/<run_id>` | Every replaced file is there as `<name>.backup.YYYYmmdd_HHMMSS`. |
| 4.4 | `dotfilesync plan` | Empty plan (converged). |
| 4.5 | From the CLI: `dotfilesync apply` on a TTY | Prints the plan and asks `Apply N actions? [y/N]`. `n` applies nothing. |

## 5. Stop, crash, relaunch

| Step | Command | Expected |
|---|---|---|
| 5.1 | `dotfilesync service stop` | The agent shuts down. |
| 5.2 | `dotfilesync scan` | launchd starts the agent again on demand (it is still registered). The scan runs as an agent job. |
| 5.3 | `kill -9 <pid>`, then `dotfilesync service start` | Starts again. Any job that was running shows as `interrupted` in `dotfilesync jobs list` and is not replayed. |

## 6. Unregister keeps data

| Step | Command | Expected |
|---|---|---|
| 6.1 | `dotfilesync service uninstall` | `Unregistered com.jamallyons.dotfilesync.agent.plist; launchd stopped the agent.` and says state and logs were kept. |
| 6.2 | `dotfilesync service status` | `not registered`. DotfileSync is gone from Login Items. |
| 6.3 | `ls ~/Library/Application\ Support/dotfilesync` | Still present. Your dotfiles and repositories are untouched. |
| 6.4 | `grep -ri -e ghp_ -e password ~/Library/Application\ Support/dotfilesync` | No secrets. Logs hold only event metadata. |

Clean up afterwards with `rm -rf ~/Library/Application\ Support/dotfilesync` once you no longer
need the state.
