# Drift — How It Works Under the Hood

Concise numbered-step explanations of what each command actually does.

---

## File layout

```
<repo>/
  bin/
    drift              ← dispatcher; symlinked to ~/.local/bin/drift by install.sh
  lib/
    prepare.sh         ← prepare workspace logic
    sync.sh            ← sync-back logic
  configs/
    copilot/
      .github/
        copilot-instructions.md
  tests/
    test-prepare-workspace.sh
    test-sync-back.sh
  install.sh
  README.md
  INTERNALS.md
```

Runtime paths (outside the repo, created by `install.sh`):

```
~/.local/bin/drift                         ← symlink → <repo>/bin/drift
~/.local/share/drift/workspaces/           ← default workspace root
~/.config/drift/config                     ← stores DRIFT_SOURCE_DIR for upgrades
```

The workspace root is overridable via `$DRIFT_WORKSPACES_DIR`.

---

## `bin/drift` — Dispatcher

1. Sources `~/.config/drift/config` (if present) to learn `DRIFT_SOURCE_DIR`.
2. Falls back to resolving `DRIFT_SOURCE_DIR` as the repo containing the script.
3. Sets `DRIFT_WORKSPACES_DIR` (default: `~/.local/share/drift/workspaces`).
4. Exports both variables so the lib scripts inherit them.
5. Dispatches: `prepare` → `lib/prepare.sh`, `sync` → `lib/sync.sh`.
6. Implements `list`, `upgrade`, and `help` inline.

---

## `drift prepare` (`lib/prepare.sh`) — Creating a workspace

**Setup**
1. Checks bash version is 4+ (associative arrays require it).
2. Verifies `git` is on `PATH`.
3. Validates the workspace `<name>` — only letters, digits, hyphens, underscores.
4. Reads `DRIFT_WORKSPACES_DIR` from env; creates it if it doesn't exist.
5. Checks `<WORKSPACES_DIR>/<name>` does not already exist.

**Source validation** (repeated for each source dir)
6. Resolves the path to an absolute canonical form.
7. Rejects `/` and any path that is a parent of (or equal to) the workspaces dir.
8. Rejects duplicate basenames (e.g. two different dirs both named `api`).

**Creating the workspace**
9. Creates `<WORKSPACES_DIR>/<name>/` with a single `mkdir`.
10. Copies each source dir using `cp -a` (preserves permissions, symlinks, timestamps).
11. Recursively finds and removes every `.git` directory and `.git` file (worktrees).
12. Runs `git init` inside the workspace.

**Metadata + initial commit**
13. Writes `<name>.meta` (sibling to workspace dir) in `KEY=value` format — workspace
    name, creation timestamp, and for each source: its absolute path and subdir name.
14. Runs `git add -A && git commit` to record the exact starting state.

---

## `drift sync` (`lib/sync.sh`) — Syncing changes back to the original

### Startup

1. Parses flags: apply method (`--3way` or `--reject`), output mode (`--dry-run` or
   `--patch`), and `--force`.
2. Reads `DRIFT_WORKSPACES_DIR` from env to resolve workspace names.
3. Reads `<workspace>.meta` — errors with a clear message if it is missing.
4. Parses `workspace.name` and all `source.*` entries from the meta file.
5. Creates a temp directory for patch files; registers a `trap` to delete it on exit.

### Per-source loop

6. Reads `source.<n>.path` (original dir) and `source.<n>.subdir` (workspace subdir).
7. Validates both directories exist on disk.

**`--3way` pre-flight only**
8. Checks the original is a git repository.
9. Runs `git stash push -u` to stash WIP before the clean copy is made.

**Clean copy for diffing**
10. Copies the original into a temp subdirectory, strips every `.git` entry.
11. Creates a symlink to the workspace subdir alongside the clean copy.

**Generating the patch**
12. Runs `git diff --no-index --binary --full-index -M` from the temp dir, producing
    a unified diff with relative single-component paths.

### Output modes

**`--patch`** — prints the raw diff to stdout; nothing is modified.

**`--dry-run`** — runs `git apply --stat` and `--numstat`; nothing is modified.

### Apply modes

**`--3way`**
13. Creates (or reuses) a `drift/<workspace-name>` safety branch in the original.
14. Applies with `git apply --3way -p2` — conflicts get `<<<<`/`====`/`>>>>` markers.
15. Reports unmerged paths and prints next-step instructions.

**`--reject`**
16. Warns about any file deletions; prompts interactively (or requires `--force`).
17. Applies with `git apply --reject -p2` — failed hunks land in `<file>.rej`.
18. Lists any `.rej` files left behind.

---

## `drift upgrade`

1. Sources `~/.config/drift/config` to find `DRIFT_SOURCE_DIR`.
2. Runs `git -C "$DRIFT_SOURCE_DIR" pull`.
3. Re-checks the `~/.local/bin/drift` symlink and updates it if needed.

---

## `install.sh`

1. Validates bash 4+ and git.
2. Determines `DRIFT_SOURCE_DIR` as the directory containing the script.
3. Creates `~/.local/bin/`, `~/.local/share/drift/workspaces/`, `~/.config/drift/`.
4. Symlinks `<repo>/bin/drift` → `~/.local/bin/drift`.
5. Writes `~/.config/drift/config` with `DRIFT_SOURCE_DIR=<path>`.
6. Detects if `~/.local/bin` is on PATH; prints shell-specific instructions if not.

---

## The `.meta` file

Written to `<WORKSPACES_DIR>/<name>.meta` by `drift prepare`. Plain `KEY=value` text.

```
# Generated by drift prepare — do not edit manually
workspace.name=my-refactor
workspace.created=2026-05-18T09:44:38Z
source.1.name=api
source.1.path=/home/user/projects/api
source.1.subdir=api
source.2.name=frontend
source.2.path=/home/user/projects/frontend
source.2.subdir=frontend
```

Parsed with: `grep -m1 "^KEY=" file | cut -d= -f2-`  
Source count: `grep -c '^source\.[0-9]*\.name=' file`
