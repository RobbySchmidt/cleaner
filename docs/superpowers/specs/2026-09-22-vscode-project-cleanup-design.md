# VS Code Project Cleanup — Design

**Date:** 2026-09-22
**Status:** Approved, ready for implementation planning

## Problem

VS Code scatters per-project data across several locations under `%APPDATA%\Code`.
When a project folder is deleted, that data stays behind: local file history,
workspace storage, backups, log references. On this machine there are already
259 `workspaceStorage` folders and 1977 `History` folders, most belonging to
projects that no longer matter.

The goal is to be able to fully remove a project: the folder *and* everything
VS Code wrote elsewhere on its behalf.

## Scope

**In scope:** VS Code's own artifacts only.

**Out of scope:** package manager caches (npm/pnpm/yarn), build caches
(`.nuxt`, `.vite`, `.turbo`), CLI state (Supabase, Docker). These are frequently
shared between projects and deleting them per-project is unsafe.

## Approach

Two components. The resolver does the work; the discovery run exists once, to
prove the resolver is complete.

A live write-tracker was considered as the primary mechanism and rejected: it
cannot help with the 259 projects that already exist, and it requires
remembering to start it before every session. Its value is as a one-off
validation of the resolver, which is what Part 2 uses it for.

---

## Part 1 — Resolver (`vscode-cleanup.ps1`)

### Interface

```powershell
.\vscode-cleanup.ps1 -Project "D:\Nuxt\foo"                    # report only (default)
.\vscode-cleanup.ps1 -Project "D:\Nuxt\foo" -Delete            # purge certain matches
.\vscode-cleanup.ps1 -Project "D:\Nuxt\foo" -Delete -IncludeProbable
```

### Path normalization

VS Code stores URIs, not Windows paths:

```
D:\Nuxt\foo  ->  file:///d%3A/Nuxt/foo
```

Lowercased drive letter, forward slashes, and percent-encoding. The normalizer must
produce this form, compare case-insensitively, and match **descendants** —
History entries reference individual files (`file:///d%3A/Nuxt/foo/components/X.vue`)
which still belong to project `foo`.

**Encoding rule.** Everything outside the unreserved set `A-Z a-z 0-9 - . _ ~` and the
path separator `/` is percent-encoded as its UTF-8 bytes. An earlier draft of this spec
said "URL-encoded colon and `%20` for spaces" and stopped there; that is wrong, and the
evidence is on this machine. Of the 2232 live `file://` URIs under `%APPDATA%\Code`,
the escapes actually present are:

```
2232  %3A      the drive colon
 516  %20      spaces
 118  %5B/%5D  Nuxt dynamic-route folders, e.g. /pages/wohnungen/%5Bid%5D/index.vue
```

The full rule was validated by decoding all 2232 live URIs back to Windows paths,
re-encoding them, and comparing: **0 mismatches**. No live URI contains a literal
character outside the unreserved set, so the strict rule cannot over-encode relative
to what VS Code actually writes.

Encoding `%` itself as `%25` is not cosmetic. Under the old rule `C:\My%20Project` and
`C:\My Project` both produce `file:///c%3A/My%20Project` — two different folders
collapsing to one URI, which in a tool that deletes things means purging the wrong
project's artifacts. This is the only known failure in the dangerous direction.

**Rooted drive paths only.** `\\server\share\proj` and relative paths are rejected with
an error. The old `Substring(0,1)` / `Substring(2)` drive assumption turned a UNC path
into the malformed `file:///\%3Aserver/share/proj`, which matches nothing and reports
"No artifacts found" — the tool's worst failure mode, since it looks like success. UNC
support is out of scope; a loud error is the correct outcome.

**Known limitation.** The unreserved-set rule is proven for every character class that
occurs in the live data (letters, digits, `-` `.` `_` `/`, space, `[`, `]`, `:`). No live
URI contains `#`, `&`, `+`, `(`, `)` or non-ASCII, so the rule is unverified for those.
If VS Code leaves any of them literal, a project whose folder name contains one would
report "no artifacts found" — the safe direction, not the dangerous one.

Note also that not every stored resource uses the `file:` scheme: one live entry uses
`vscode-userdata:`. Non-`file:` URIs simply fail the prefix match, which is correct —
they are global settings, not project files.

This is the only non-trivial logic in the resolver. Everything else is directory
traversal and JSON reads.

### Sources

| Source | Ownership determined by | Confidence |
|---|---|---|
| `%APPDATA%\Code\User\workspaceStorage\<hash>\` | `workspace.json` -> `.folder` or `.workspace` | certain |
| `%APPDATA%\Code\User\History\<hash>\` | `entries.json` -> `.resource` is under project | certain |
| `%APPDATA%\Code\Backups\<hash>\` | hash matches a workspaceStorage hit | certain |
| `%APPDATA%\Code\logs\<session>\window*\` | log text mentions the project path | probable |

When a source matches, the entire `<hash>` directory is the artifact.

### Output

One record per artifact: `Path`, `Source`, `SizeBytes`, `Confidence`.

Written to `vscode-artifacts-<project>-<date>.txt` in the current working
directory (overridable with `-ReportPath`), grouped by source, with per-group
and total sizes. A summary is also printed to the console.

### Deletion guardrails

1. Without `-Delete` the script only reports and never touches the filesystem.
   `-Delete` is an explicit opt-in switch, not PowerShell's `SupportsShouldProcess`.
2. Refuses to delete any path not under a hard-coded allowlist of VS Code roots.
3. Skips `probable` entries unless `-IncludeProbable` is passed.
4. Warns if `Code.exe` is running.

### Error handling

Locked `state.vscdb`, malformed JSON, and missing roots are each skipped with a
warning. A single bad artifact never aborts the run.

---

## Part 2 — Discovery run (`vscode-discover.ps1`)

Runs **once**, to validate the resolver. Not a background service.

### Mechanism

A `FileSystemWatcher` over `%APPDATA%\Code` and `%USERPROFILE%\.vscode` with
`IncludeSubdirectories = $true`, logging `Created` and `Changed` events
(timestamp + path) to a flat log file.

ProcMon was considered and is the fallback, not the default: it needs admin and
a separate download. FileSystemWatcher drops events under load, which is
acceptable because this is a discovery aid rather than the mechanism being
relied on. If results look implausibly thin, redo the run with ProcMon filtered
to `Code.exe`.

### Procedure

1. Start the watcher.
2. Put a throwaway project through a full lifecycle: create, open in VS Code,
   edit several files, let extensions activate, close the window, reopen, close
   VS Code entirely.
3. Stop the watcher.

### The diff

The script runs the Part 1 resolver against the same throwaway project and
compares the two path sets:

- **written ∩ resolver-found** — resolver works, no action
- **written − resolver-found** — the gap; paths that would be left behind
- **resolver-found − written** — stale artifacts from earlier sessions; expected

The middle set is the deliverable. Each gap is classified as either
project-specific (add a rule to the resolver) or shared/global (document as
not safe to delete per-project).

---

## Deliverables

- `vscode-cleanup.ps1`
- `vscode-discover.ps1`
- Gap findings folded into the resolver as named rules, each with a comment
  recording which discovery run it came from.

Both scripts live in `C:\Users\<you>\Desktop\Test\`. PowerShell, no
external dependencies.

## Verification

Before `-Delete` is trusted: point the resolver at one existing project from the
259 already present, and confirm by hand that the `workspaceStorage` folder it
names really does contain that project's URI in its `workspace.json`.
