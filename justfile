# dotfilesync task runner. `just` lists every recipe; `just <recipe>` runs one.
# Requires: Xcode 26+, `brew install just`.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

project     := "App/DotfileSync.xcodeproj"
scheme      := "DotfileSync"
pkg         := "Packages/DotfileSyncKit"
derived     := justfile_directory() / "build/DerivedData"
bundle_id   := "com.jamallyons.dotfilesync"
agent_label := "com.jamallyons.dotfilesync.agent"
app_name    := "DotfileSync.app"
install_dir := env_var_or_default("DOTFILESYNC_INSTALL_DIR", "/Applications")
installed   := install_dir / app_name
bin_dir     := env_var_or_default("DOTFILESYNC_BIN_DIR", env_var("HOME") / ".local/bin")
cli_shim    := bin_dir / "dotfilesync"

# List recipes.
default:
    @just --list --unsorted

# ---------------------------------------------------------------------------
# Build and test
# ---------------------------------------------------------------------------

# Build the Swift package (warnings are errors, same as CI).
build-pkg:
    cd {{pkg}} && swift build --build-tests -Xswiftc -warnings-as-errors

# Run the Swift package tests. Extra args go to `swift test` (e.g. `just test-pkg --filter Planner`).
test-pkg *args:
    cd {{pkg}} && swift test -Xswiftc -warnings-as-errors "$@"

# Build the app unsigned (CI build; the agent will refuse to talk to it).
build-app config="Debug":
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" CODE_SIGNING_ALLOWED=NO build

# Build and test the app unsigned (what CI runs).
test-app:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination 'platform=macOS' \
      -derivedDataPath "{{derived}}" CODE_SIGNING_ALLOWED=NO build test

# Everything CI checks: package build + tests, then app build + tests.
ci: build-pkg test-pkg test-app

# Alias for `ci`.
test: ci

# Build a signed app. Team comes from $DEVELOPMENT_TEAM or your Apple Development certificate.
build-signed config="Release":
    #!/usr/bin/env bash
    set -euo pipefail
    team="${DEVELOPMENT_TEAM:-}"
    if [[ -z "$team" ]]; then
        team="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
            | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')"
    fi
    if [[ -z "$team" ]]; then
        echo "error: no signing team. Add an Apple ID in Xcode → Settings → Accounts, or set DEVELOPMENT_TEAM=<team id>." >&2
        exit 1
    fi
    echo "==> Building {{app_name}} ({{config}}, team $team)"
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" \
      -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" build

# Run the dev CLI from the package (no agent signing; read-only commands work best).
cli *args:
    cd {{pkg}} && swift run -q dotfilesync "$@"

# Open the most recent signed Release build from build/ without installing it.
run-build: (build-signed "Release")
    open "{{derived}}/Build/Products/Release/{{app_name}}"

# Delete build output (build/ and the package's .build/).
clean:
    rm -rf build "{{pkg}}/.build"

# ---------------------------------------------------------------------------
# Local install
# ---------------------------------------------------------------------------

# Build a signed Release app and install (or replace) it in /Applications, link the CLI, register the agent.
local-install: (build-signed "Release")
    #!/usr/bin/env bash
    set -euo pipefail
    built="{{derived}}/Build/Products/Release/{{app_name}}"
    dest="{{installed}}"
    [[ -d "$built" ]] || { echo "error: build output missing: $built" >&2; exit 1; }

    if [[ -d "$dest" ]]; then
        echo "==> Replacing existing $dest"
        # Unregister with the old bundle so launchd/BTM drop the old agent definition.
        "$dest/Contents/MacOS/dotfilesync" service uninstall >/dev/null 2>&1 || true
    else
        echo "==> Installing to $dest"
    fi
    just _stop-processes

    rm -rf "$dest"
    ditto "$built" "$dest"
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

    # Refresh LaunchServices so Finder, Spotlight and Launchpad see the new build.
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$lsregister" -f -R -trusted "$dest" || true

    # CLI on PATH. A wrapper, not a symlink, so the binary still resolves its own app bundle.
    mkdir -p "{{bin_dir}}"
    rm -f "{{cli_shim}}"
    printf '#!/bin/sh\nexec "%s/Contents/MacOS/dotfilesync" "$@"\n' "$dest" > "{{cli_shim}}"
    chmod 755 "{{cli_shim}}"
    echo "==> CLI: {{cli_shim}}"
    case ":$PATH:" in *":{{bin_dir}}:"*) ;; *) echo "    note: {{bin_dir}} is not on PATH; add it to use \`dotfilesync\`." ;; esac

    if [[ "${DOTFILESYNC_SKIP_REGISTER:-0}" != "1" ]]; then
        echo "==> Registering the agent"
        "$dest/Contents/MacOS/dotfilesync" service install || echo "    warning: registration failed; open the app and register from there."
    fi

    echo "==> Installed $(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?') at $dest"
    "$dest/Contents/MacOS/dotfilesync" service status || true
    if [[ "${DOTFILESYNC_NO_OPEN:-0}" != "1" ]]; then open "$dest"; fi

# Remove the app, CLI link, agent registration, settings and all saved data. Pass `--yes` to skip the prompt.
uninstall-local *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="{{installed}}"
    data="${DOTFILESYNC_DATA_DIR:-$HOME/Library/Application Support/dotfilesync}"
    targets=(
        "$dest"
        "{{cli_shim}}"
        "$data"
        "$HOME/Library/Preferences/{{bundle_id}}.plist"
        "$HOME/Library/Caches/{{bundle_id}}"
        "$HOME/Library/HTTPStorages/{{bundle_id}}"
        "$HOME/Library/WebKit/{{bundle_id}}"
        "$HOME/Library/Saved Application State/{{bundle_id}}.savedState"
        "$HOME/Library/Containers/{{bundle_id}}"
        "$HOME/Library/Logs/dotfilesync"
    )
    echo "This permanently removes DotfileSync from this Mac:"
    echo "  - unregisters the agent ({{agent_label}}) from launchd / Login Items"
    for t in "${targets[@]}"; do [[ -e "$t" || -L "$t" ]] && echo "  - $t"; done
    echo "  - Touch ID / privacy (TCC) grants for {{bundle_id}}"
    echo "Your dotfiles, manifest (dotfilesync.toml) and repositories are NOT touched."
    if [[ " $* " != *" --yes "* && " $* " != *" -y "* ]]; then
        read -r -p "Continue? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi

    if [[ -x "$dest/Contents/MacOS/dotfilesync" ]]; then
        "$dest/Contents/MacOS/dotfilesync" service uninstall || true
    fi
    just _stop-processes
    launchctl bootout "gui/$(id -u)/{{agent_label}}" 2>/dev/null || true

    if [[ -d "$dest" ]]; then
        lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        "$lsregister" -u "$dest" 2>/dev/null || true
    fi
    # Drop cached preferences before deleting the plist, or cfprefsd writes it back.
    defaults delete {{bundle_id}} 2>/dev/null || true
    tccutil reset All {{bundle_id}} >/dev/null 2>&1 || true

    for t in "${targets[@]}"; do
        if [[ -e "$t" || -L "$t" ]]; then rm -rf "$t" && echo "removed $t"; fi
    done
    echo "DotfileSync uninstalled."

# Show what is installed: app, CLI, agent registration and data folder.
status:
    #!/usr/bin/env bash
    dest="{{installed}}"
    if [[ -d "$dest" ]]; then
        echo "app:    $dest ($(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
        codesign -dv "$dest" 2>&1 | grep -E 'TeamIdentifier|Authority=Apple' | head -2 | sed 's/^/        /'
    else
        echo "app:    not installed"
    fi
    if [[ -e "{{cli_shim}}" ]]; then echo "cli:    {{cli_shim}}"; else echo "cli:    not linked"; fi
    data="${DOTFILESYNC_DATA_DIR:-$HOME/Library/Application Support/dotfilesync}"
    if [[ -d "$data" ]]; then echo "data:   $data"; else echo "data:   none"; fi
    if [[ -x "$dest/Contents/MacOS/dotfilesync" ]]; then "$dest/Contents/MacOS/dotfilesync" service status || true; fi

# Tail the agent log.
logs:
    tail -n 100 -F "${DOTFILESYNC_DATA_DIR:-$HOME/Library/Application Support/dotfilesync}/logs/dotfilesyncd.log"

# Open System Settings → Login Items to approve the agent.
open-settings:
    open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

# Quit the app and stop the agent.
_stop-processes:
    #!/usr/bin/env bash
    osascript -e 'tell application id "{{bundle_id}}" to quit' >/dev/null 2>&1 || true
    pkill -x DotfileSyncApp 2>/dev/null || true
    pkill -x dotfilesyncd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x DotfileSyncApp >/dev/null || pgrep -x dotfilesyncd >/dev/null || exit 0
        sleep 0.5
    done
    pkill -9 -x DotfileSyncApp 2>/dev/null || true
    pkill -9 -x dotfilesyncd 2>/dev/null || true
