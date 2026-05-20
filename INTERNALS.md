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
11. **Gitignore inheritance** — if the source dir is inside a git repo, walks from the
    git root down to `parent(source)` and collects `.gitignore` patterns, then appends
    them to the **workspace root** `.gitignore` (`<WORKSPACES_DIR>/<name>/.gitignore`),
    not to the source subdir's `.gitignore`. This keeps the inherited rules out of the
    sync diff entirely — they are never patched back to the original.
    - Non-anchored patterns (e.g. `node_modules/`, `*.log`) are written as-is; git
      applies them at every directory level so they work from the workspace root.
    - Anchored patterns (starting with `/`) are translated if they point strictly inside
      the source dir: `/apps/v3/frontend/app/coverage/` → `/frontend/app/coverage/`
      (prefixed with `/<basename>/` to anchor correctly at the workspace root).
    - Anchored patterns with glob characters or pointing outside the source dir are skipped.
    - Patterns are written under a `# ── drift: inherited gitignore rules for /<basename>` section.
    - This makes the workspace self-contained in isolated environments where parent-level
      `.gitignore` files would otherwise be invisible to agents or tools.
12. Recursively finds and removes every `.git` directory and `.git` file (worktrees).
13. Runs `git init` inside the workspace.

**Metadata + initial commit**
14. Writes `<name>.meta` (sibling to workspace dir) in `KEY=value` format — workspace
    name, creation timestamp, and for each source: its absolute path and subdir name.
15. Runs `git add -A && git commit` to record the exact starting state.

---

## `drift sync` (`lib/sync.sh`) — Syncing changes back to the original

### Startup

1. Parses flags: apply method (`--3way` or `--reject`), output mode (`--dry-run` or
   `--patch`), and `--force`.
2. Reads `DRIFT_WORKSPACES_DIR` from env to resolve workspace names.
3. Reads `<workspace>.meta` — errors with a clear message if it is missing.
4. Parses `workspace.name` and all `source.*` entries from the meta file.
5. Creates a temp directory for patch files; registers a `_cleanup` trap to delete it
   on exit and remove any linked worktree that may have been left behind.

### Per-source loop

6. Reads `source.<n>.path` (original dir) and `source.<n>.subdir` (workspace subdir).
7. Validates both directories exist on disk.

**`--3way` only: stash WIP**
8. Checks the original is a git repository.
9. Runs `git stash push -u` to save any dirty working tree state; records the stash ref
   so sync can report it to the user.

**`--3way` only: worktree-based tracked patch**

This is where `--3way` diverges from the other modes. Rather than diffing the
filesystem with `git diff --no-index` (which would include gitignored files and cause
`git apply --3way` to fail atomically when it encounters files not in the index), a
linked worktree is used so that git's own index and gitignore machinery filter the diff.

10. Creates a linked worktree with `git worktree add --no-checkout --detach`. The
    `--no-checkout` flag skips the working tree checkout entirely — no smudge filters
    (e.g. git-crypt) are triggered.
11. Runs `git read-tree HEAD` inside the worktree to initialise the index from HEAD
    without writing any files to disk.
12. Copies all `.gitignore` files from the main working tree into the linked worktree at
    the same relative paths. This is necessary because linked worktrees share `.git` but
    NOT the main working tree's files, so file-based gitignore rules from the main tree
    would otherwise be invisible to `git add` in the empty linked worktree.
13. Removes the target subdir in the worktree, then copies the workspace files into it
    (the copy overwrites the `.gitignore` in the subdir with the workspace's own version,
    which is correct). For root-level sources the `.git` directory is preserved.
14. Runs `git add -A` scoped to the subdir. Because the index is at HEAD and the worktree
    now contains the workspace files, this stages exactly the tracked delta: modifications,
    additions, and deletions. Gitignored files (dist/, coverage/, build artifacts) are
    silently skipped by git's normal ignore machinery.
15. Runs `git diff --cached HEAD` to produce `PATCH_TRACKED` — a clean patch with
    repo-root-relative paths that `git apply` can consume without `-p2` or `--directory`.
16. Removes the worktree with `git worktree remove --force`.
17. If `PATCH_TRACKED` is empty, all differences are in gitignored files; reports
    "No tracked changes to sync" and skips to the next source (exit 0).

**All modes: raw filesystem patch**

18. Copies the original into a temp subdirectory, strips every `.git` entry.
19. Creates a symlink to the workspace subdir alongside the clean copy.
20. Runs `git diff --no-index --binary --full-index -M` from the temp dir, producing
    a raw unified diff with two-component paths (e.g. `a/orig/file` `b/ws/file`).
    Used by `--patch`, `--dry-run`, and `--reject`; ignored for `--3way`.

### Output modes

**`--patch`** — prints the raw diff to stdout; nothing is modified.

**`--dry-run`** — runs `git apply --stat` and `--numstat` on the raw diff; nothing is modified.

### Apply modes

**`--3way`**
21. Creates (or reuses) a `drift/<workspace-name>` safety branch in the original repo.
22. Applies `PATCH_TRACKED` with `git apply --3way`. Paths in the patch are already
    repo-root-relative (standard `-p1`), so no `-p2` or `--directory` flags are needed.
    Conflicts produce `<<<<`/`====`/`>>>>` markers.
23. Checks `git ls-files --unmerged` for conflict markers and `git diff --name-only HEAD`
    for applied changes; reports the result and prints next-step instructions.

**`--reject`**
24. Warns about any file deletions; prompts interactively (or requires `--force`).
25. Applies the raw patch with `git apply --reject -p2` — failed hunks land in `<file>.rej`.
26. Lists any `.rej` files left behind.

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
