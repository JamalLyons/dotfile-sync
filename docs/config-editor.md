# Config discovery, editor and working tree

dotfilesync can find the config files on your Mac, show which ones the repo manages, let you edit them safely, and enroll or un-enroll a file through the normal plan, approve, apply flow. This page describes that behavior. The code is in `Packages/DotfileSyncKit/Sources/Core/` under `ConfigDiscovery/`, `Editor/`, `WorkingTree/`, `Plan/ManifestChange.swift`, `Apply/ManifestChangeApply.swift` and `Manifest/ManifestTextEdit.swift`. The SwiftUI screens are issue #8; this page covers the core and the agent operations they call.

## 1. Discovery

`discoverConfigs` returns a report of tools, entries, a `truncated` flag and diagnostics.

- **Metadata only.** It uses `lstat`, `readlink` and directory listings. It never opens a file, so it never reads a body.
- **Bounded.** It looks only at: the config paths of the registry tools below; the immediate children of `~/.config` (listed once, never descended); and a fixed list of well-known top-level dotfiles (`lstat` only). `$HOME` itself is never listed or scanned recursively.
- **Consent.** Discovery never enrolls a file. It only reports. Nothing enters the manifest until you promote it (section 5). Secret-like paths are reported as excluded and are never opened or listed.
- **Symlinks** are reported, never followed. A symlinked directory is not descended, and a registry path under a symlinked ancestor (for example a symlinked `~/.config`) is not visited: the ancestor is reported instead. A `config` symlink entry carries its raw `symlink_target` and `symlink_outside_home`, resolved lexically against the link's directory.
- **Unknown tools.** Children of `~/.config` that no registry entry claims are reported at depth 1 only, with `tool` unset. They are `lstat`ed, never descended.
- **Detection.** A registry tool is reported when `$SHELL` names it, a binary is on `PATH` or in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, an app bundle is in `/Applications` or `~/Applications`, or one of its config paths exists. `detected_by` lists every signal that fired (`shell`, `binary`, `application`, `config_present`).

### Default limits

| Limit | Default | Effect when hit |
|---|---|---|
| `maxDepth` | 8 | Directories at this depth below a config root are reported but not listed. `truncated` is set. |
| `maxEntries` | 5000 | Discovery stops adding entries. `truncated` is set. |
| `maxEntriesPerDirectory` | 1000 | Only the first 1000 sorted names are read. `truncated` is set. |

A directory that cannot be listed adds a diagnostic and discovery continues.

### Tool registry

From `ToolRegistry.swift`. Paths are relative to `$HOME`. A file or a directory is allowed.

| Tool | id | Binaries | Shell names | Apps | Config paths |
|---|---|---|---|---|---|
| Bash | `bash` | `bash` | `bash` | | `.bashrc`, `.bash_profile`, `.bash_login`, `.bash_logout`, `.profile` |
| Fish | `fish` | `fish` | `fish` | | `.config/fish` |
| Ghostty | `ghostty` | `ghostty` | | `Ghostty.app` | `.config/ghostty`, `Library/Application Support/com.mitchellh.ghostty` |
| Git | `git` | `git` | | | `.gitconfig`, `.config/git` |
| Neovim | `nvim` | `nvim` | | | `.config/nvim` |
| Starship | `starship` | `starship` | | | `.config/starship.toml` |
| tmux | `tmux` | `tmux` | | | `.tmux.conf`, `.config/tmux` |
| Zed | `zed` | `zed` | | `Zed.app` | `.config/zed` |
| Zsh | `zsh` | `zsh` | `zsh` | | `.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`, `.zlogout`, `.config/zsh` |

`~/.ssh` and other secret-holding locations deliberately have no registry entry.

### Well-known dotfiles

Reported by `lstat` alone. Several are secret-like, cache or data locations: they are listed so the UI can show them as excluded, and are never opened or listed.

`.aws`, `.bash_history`, `.cache`, `.curlrc`, `.docker`, `.editorconfig`, `.gemrc`, `.git-credentials`, `.gnupg`, `.hushlogin`, `.inputrc`, `.kube`, `.netrc`, `.npmrc`, `.pypirc`, `.ssh`, `.tool-versions`, `.vimrc`, `.wgetrc`, `.zsh_history`.

## 2. Classification and default exclusions

`classifyConfigPath` looks at names and extensions only, never contents. Names compare case-insensitively. Every component of the path is checked, so anything under an excluded directory is excluded too. Precedence: secret-like, then data, then cache, then generated, then config. Only `config` entries are offered for editing; every other class is excluded by default and carries a reason.

| Class | Rule |
|---|---|
| `secret_like` | Names `.ssh`, `.gnupg`, `.aws`, `.netrc`, `.git-credentials`, `.npmrc`, `.pypirc`, `.docker`, `.kube`, `.password-store`, `.env`; prefixes `.env.`, `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`; gh `hosts.yml`; names containing `token`, `secret`, `credential`, `password` or `passwd`; extensions `pem`, `key`, `p12`, `pfx`, `gpg`, `asc`, `kdbx`, `keychain`, `keychain-db`. `.npmrc` and `.pypirc` routinely hold registry tokens. |
| `data` | Names containing `history`, `.lesshst`, `fish_variables` (fish rewrites it itself), `.git`, `log`, `logs`, `.DS_Store`; extensions `log`, `sqlite`, `sqlite3`, `db`, `db-wal`, `db-shm`, `db-journal`, `sqlite-wal`, `sqlite-shm`, `sqlite-journal`. |
| `cache` | `.cache`, names starting or ending with `cache` (`Cache`, `Caches`, `GPUCache`, `Code Cache`), extension `cache`. |
| `generated` | `*.zwc`, `.zcompdump*`, `__pycache__`, `*.pyc`, `node_modules`, `lazy-lock.json` (lazy.nvim rewrites it on every sync), `packer_compiled.lua`, `*.lock`, `*.swp`, `*.swo`, `*~`. |
| `config` | Everything else. |

## 3. Editor safety

`ConfigEditor` reads and writes regular files. It is a library: it never runs a command, and no editor operation executes file contents.

- **Allowed roots.** The editor is built from absolute directory roots plus an absolute backup directory. Roots are resolved once; both the configured spelling and the resolved path are accepted. A path outside every root is `outsideRoots`; a relative path is too.
- **Traversal.** A `..` component or an embedded NUL byte is `pathTraversal`. The `String` overloads check for NUL before building a path.
- **Symlinks.** Directories are walked with `O_NOFOLLOW`. A symlink anywhere below the root, including the file itself, is `symlinkEscape`. Non-regular files are `notRegularFile`.
- **Size limit.** Default 1 MiB (`maxFileSize`). Larger files on disk, or larger input text, are `tooLarge(limit:size:)`.
- **Binary files are view-only.** A file with a NUL byte or invalid UTF-8 opens as bytes with no text (`isBinary`). Saving one, or saving text that contains NUL, is `binaryFile`.
- **Atomic saves.** `save` writes the new bytes to a hidden temp file (`.dotfilesync-editor-<uuid>.tmp`, created exclusively, fsynced) in the same directory, then renames it over the original.
- **Backups.** Before a save replaces a file, the previous bytes are copied under the backup directory at `<backup>/<path relative to the allowed root>/<name>.backup.<YYYYmmdd_HHMMSS>` (UTC; `.<n>` is appended on a collision). Backup directories are created mode `0700`, backup files `0600`. If the replace fails, the backup is removed. `create` and `rename` make no backup.
- **Permissions preserved.** A save sets the new file's mode to the old file's mode. `create` writes mode `0600` and creates missing parents (inside the root) with `0755`.
- **External-edit conflicts.** `open` returns a version: mtime (ns), size and SHA-256. `save` must be given that version. If the file on disk differs, it fails with `conflict(current:)` carrying the current version. The file's identity is checked again just before the rename, so an edit that lands during the save is also a conflict. `force` accepts a stale version; every other check still applies.
- **Create and rename.** `create` fails with `alreadyExists` if the path exists. `rename` moves a regular file within one root, needs an existing destination parent and an absent destination, and applies the size limit.
- Writes in one process are serialized.

## 4. Working tree and diff

`buildWorkingTree` returns a sorted tree rooted at `$HOME` (empty relative path). It merges discovery with the resolved manifest, so tracked paths missing from discovery are still present. Directories carry an `aggregate` count of their descendants, and `truncated` mirrors discovery.

| Status | Meaning |
|---|---|
| `managed` | Tracked by the manifest, and the machine file matches its repo source (or is a symlink to it). |
| `modified` | Tracked, but different, missing, unreadable, or the repo source is missing. |
| `unmanaged` | Discovered `config` file the manifest does not track. |
| `excluded` | Secret-like, data, cache or generated; manifest `exclusions`; or a machine-local override. |

Directories have no status of their own, only counts.

`diffWorkingFile` compares one HOME file with its managed repo source. **The base is the repo source file today.** A git base arrives with #6.

| Diff status | Meaning |
|---|---|
| `unchanged` | Bytes equal. |
| `changed` | Differ. `hunks` hold unified-diff lines with 3 lines of context and `\ No newline at end of file` markers. `target_missing` is set when the machine file is absent (shown as a deletion). |
| `no_base` | Not tracked, or its repo source is missing. Machine contents are not loaded. |
| `binary` | Either side has a NUL or invalid UTF-8. |
| `too_large` | Either side exceeds `maxBytes` (default 1 MiB). |
| `too_complex` | Line diff exceeds the work limit (edit distance 2048 or 8,388,608 comparisons). |

An excluded path throws `excluded` before either side is opened. Symlinks are not followed, except a machine symlink that points at its own repo source and repo symlinks that stay inside the repo. Anything else is `unsafePath`.

## 5. Promote and demote

Promote enrolls machine files; demote stops managing them. Both are ordinary plans (`promote_file`, `demote_file` actions) that go through approve and apply ([plan-apply.md](plan-apply.md)). Neither deletes or modifies the machine file.

**Promote** (`planManifestChange` with `promote`):

- Each target is classified by name before anything is read. Secret-like, data, cache and generated files are refused without being opened.
- Targets must be absolute, inside `$HOME`, with no `.` or `..` and no symlinked parent directory. A symlink target is refused ("promote the file it points to").
- A directory expands to its eligible regular files only: symlinks skipped, excluded names skipped without descending, already managed files, manifest exclusions, overrides and `local.fish` skipped. At most 256 files and 8 levels deep; otherwise the plan fails.
- A file larger than 4 MiB is refused.
- A target already in the manifest is refused.

**Source path mapping.** Take the path relative to `$HOME`; drop a leading `.config` component, otherwise strip one leading `.` from the first component.

| Target | Repo source |
|---|---|
| `~/.config/fish/config.fish` | `fish/config.fish` |
| `~/.gitconfig` | `gitconfig` |
| `~/.local/bin/tool` | `local/bin/tool` |

The plan fails if the source is already used by another entry, two targets map to the same source, it would overwrite the manifest, or an ancestor in the repo is not a directory. The new entry is `source = "<mapped>"`, `target = "~/<relative path>"`.

**Demote** removes the matching **base** `[[files]]` entry. An entry that exists only in a profile is refused ("edit that profile's `[[files]]` by hand").

**Plan properties.** Each action is risk `medium`, reversible, with backup. The plan's `state_fingerprint` is a SHA-256 over the manifest bytes' hash, each promote target's content hash and repo source state, and each demote target's file type.

**Fail closed.** Right before apply, the host recomputes the fingerprint from disk. A changed manifest, target or repo source rejects the approval. The executor also re-classifies and re-hashes the target and fails with "changed after the plan was approved; re-plan the promotion" on any difference.

**Apply steps (promote).**

1. Reload the manifest. Another source for the same target means "re-plan".
2. Copy the target into the repo (atomic write, target's mode). A differing existing repo source is first backed up.
3. Append the `[[files]]` entry to the manifest (below), after backing up the manifest.

**Comment-preserving manifest edit.** `dotfilesync.toml` is edited as text, not rewritten. Promote inserts one `[[files]]` table (`source`, `target`) after the last existing base `[[files]]` table, or at the end when there is none. Demote removes that entry's table (plus one blank line before it), leaving comments and blank lines that introduce the next section. Header detection is line-based, so the edited text is re-parsed and must equal the expected manifest; any difference fails closed ("edit it by hand"). The write is atomic and keeps the manifest's mode.

**Backups.** The manifest and any replaced repo source are copied (never moved) to `<data>/backups/<run_id>/<path relative to home>.backup.<YYYYmmdd_HHMMSS>.<action id>`.

**Idempotent resume.** Promote skips the copy if the repo source already holds the target's bytes, and skips the manifest edit if the entry is already present. Demote is `skipped` when the entry is already gone. A crashed run resumes with `plan.resume`.

## 6. Syntax highlighting coverage

Detection is by file name and extension only (`detectConfigLanguage`, case-insensitive). The SwiftUI app (#8) does the rendering. The core only reports the language. Discovery sets `language` on `config` files and symlinks; the working tree sets it on non-directory, non-excluded nodes.

Fish, TOML, JSON, YAML and shell are required by issue #11.

| Language (`ConfigLanguage`) | Matches |
|---|---|
| `fish` | `*.fish` |
| `toml` | `*.toml` |
| `json` | `*.json`, `*.jsonc`, `*.json5` |
| `yaml` | `*.yaml`, `*.yml` |
| `shell` | `*.sh`, `*.bash`, `*.zsh`, `*.ksh`; dotfiles `.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`, `.zlogout`, `.bashrc`, `.bash_profile`, `.bash_login`, `.bash_logout`, `.profile`, `.kshrc` |
| `lua` | `*.lua` |
| `gitconfig` | `.gitconfig`, `*.gitconfig`, and a file named `config` inside a directory named `git` (`~/.config/git/config`) |
| `ini` | `*.ini`, `*.cfg`, `.editorconfig` |
| `plaintext` | Everything else (for example `.tmux.conf`, `*.conf`, `*.vim`) |

## 7. Agent operations

Requests use the usual envelope ([daemon-architecture.md](daemon-architecture.md)). Parameter and result shapes: see `Sources/IPC/Messages.swift`.

| op | Purpose |
|---|---|
| `config.discover` | Run discovery and return the report. |
| `config.tree` | Working tree with statuses and counts. |
| `config.diff` | Diff of one file against its repo source. |
| `config.open` | Read a file through the editor, with its version. |
| `config.save` | Save text with backup, conflict check and atomic replace. |
| `config.create` | Create a new file. |
| `config.rename` | Rename a file within its root. |
| `config.promote` | Plan enrolling files. Returns a normal plan. |
| `config.demote` | Plan un-enrolling files. Returns a normal plan. |

`config.promote` and `config.demote` do not change anything. They return a normal plan (see `Sources/IPC/Messages.swift` for the exact result). The client then follows the normal flow:

1. `config.promote` / `config.demote` returns the plan. Show it to the user.
2. `plan.approve` with `plan_id` and the reviewed `digest`. The agent asks for Touch ID and returns a single-use token.
3. `plan.apply` with `plan_id` and the token. The agent re-checks the fingerprint, then runs the actions as a job.
4. `plan.resume` continues an interrupted run.

## 8. Not yet

- **Watcher (#7).** The tree, status and diff are computed on request. Nothing watches the filesystem for changes.
- **Sync (#6).** The diff base is the repo working copy. There is no git base, commit or push of promoted files.
