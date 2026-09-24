# Claude Code Project Cleanup — Design

**Date:** 2026-09-24
**Status:** Draft, awaiting review

## Problem

Claude Code keeps per-project data under `~\.claude`, outside the project folder:
chat transcripts, subagent transcripts, pre-edit file copies, per-session environment
folders. Deleting the project folder leaves all of it behind, exactly like VS Code's
`workspaceStorage` and `History`.

The goal: one cleanup command removes a project's VS Code data **and** its Claude Code
data.

## Scope

**In scope:** Claude Code data that can be attributed to one project with certainty.

**Out of scope, never touched:**

| Path | Why |
|---|---|
| `~\.claude.json` | One shared file: login, all projects' settings, caches. Holds a per-project entry, but editing a shared file Claude Code rewrites constantly is the same trade as VS Code's `storage.json` (discovery Finding 2): real risk to global state, no meaningful saving. Decided: leave it. |
| `settings.json`, `.credentials.json`, `plugins\`, `skills\` | Global configuration. |
| `shell-snapshots\` | Named by timestamp (`snapshot-bash-<ms>-<rand>.sh`), no project or session link. |
| `sessions\` | Live-session registry. Read (see *Running check*), never deleted. |
| `backups\`, `cache\`, `ide\`, `telemetry\`, `.last-cleanup` | Shared, global. |
| `session-env\<id>` with no matching transcript | 302 of 321 on this machine. Unattributable, same category as VS Code's timestamp `workspaceStorage` folders (Finding 3). No orphan sweep. |

Anything inside the project folder itself (`<project>\.claude\`, `CLAUDE.md`) goes when
the user deletes the folder; the tool never touches the project folder.

## Observed layout

Verified on this machine with a fresh session in `C:\Users\<you>\A` that edited a file,
ran a shell command and used a subagent:

```
~\.claude\projects\c--Users-<you>-A\
    <sid>.jsonl                          transcript; every line has "cwd": "c:\\Users\\<you>\\A"
    <sid>\subagents\agent-<id>.jsonl     subagent transcript
    <sid>\subagents\agent-<id>.meta.json
    <sid>\tool-results\...               (only when a tool result was large; seen elsewhere)
    memory\                              per-project memory
~\.claude\file-history\<sid>\            pre-edit copies, one folder per session
~\.claude\session-env\<sid>\             per-session environment, may be empty
~\.claude\sessions\<pid>.json            {pid, sessionId, cwd, status, ...} while a session runs;
                                         removed when it exits
```

### The folder name is lossy — never trust it alone

The `projects\` folder name is the launch directory with **every character outside
`A-Za-z0-9` replaced by `-`**: `C:\Users\<you>\OneDrive\Desktop\Neuer Ordner` →
`c--Users-<you>-OneDrive-Desktop-Neuer-Ordner`. So `...\A-B`, `...\A B` and `...\A\B`
all map to the same folder. This is the Claude Code version of the sibling-collision
hazard (Finding 1), except it is worse: the collision is exact, not a prefix. Ownership
therefore comes from the `cwd` recorded **inside** each transcript.

## Approach

Add Claude Code as additional sources in the existing pipeline. The scanners return the
same artifact objects (`Path`, `Source`, `Confidence`, `Hash`) the VS Code scanners do,
so reporting, `-WhatIf`, validate-before-delete, the junction guard and skip-on-lock all
apply unchanged.

Rejected: a separate Claude pass with its own delete loop. It would duplicate the
deletion safety code, which is the part of this tool that most needs to exist once.

## Components

### Roots (`src/VSCodeRoots.ps1`)

`Get-VSCodeRoots` gains a `-ClaudeRoot` parameter (default `~\.claude`) and properties
`ClaudeRoot`, `ClaudeProjects`, `ClaudeFileHistory`, `ClaudeSessionEnv`, `ClaudeSessions`.
One roots object keeps flowing through every existing function.

`Test-PathUnderArtifactRoots` adds **exactly three** roots to its allowlist:
`ClaudeProjects`, `ClaudeFileHistory`, `ClaudeSessionEnv`. Not `ClaudeRoot` wholesale —
the same reasoning as not allowlisting `%APPDATA%\Code`: a scanner bug emitting a parent
must fail validation rather than take `settings.json` or credentials with it. Not
`ClaudeSessions`: it is read, never deleted. The root folders themselves stay
non-deletable (existing `Equals` rule).

### Scanners (`src/ClaudeCodeSources.ps1`, new)

Paths from Claude Code are plain Windows paths (`c:\Users\<you>\A`), so matching converts
them with the existing `ConvertTo-VSCodeUri` and compares with the existing
`Test-UriUnderProject`. That reuses the proven boundary rule (exact match or `/`
descendant, case-insensitive), so `A` does not swallow `A-main`.

**`Get-ClaudeTranscriptOwner -Path <jsonl>`** — the `cwd` of the first line that has one,
reading line by line and stopping there (transcripts reach ~1 MB). The first `cwd` is the
launch directory, which is what Claude Code filed the transcript under; later lines may
show a different `cwd` after the session `cd`s elsewhere, and are ignored. Unreadable or
no `cwd` → `$null`.

**`Get-ClaudeProjectArtifacts -Roots -ProjectUri`** — for each folder in `ClaudeProjects`:

1. Owner of every `*.jsonl` directly in it. Each transcript is **owned** (owner under the
   project), **foreign** (owner outside it) or **ownerless** (no `cwd` anywhere — see
   below).
2. At least one owned and **no foreign** → the whole folder is one artifact,
   `claude:projects`, `certain` (includes `memory\`, `<sid>\` subfolders and any
   ownerless stubs). Claude Code filed every transcript in it under the same launch
   directory, and none contradicts the match.
3. Owned **and** foreign (a lossy-name collision) → per owned transcript, two artifacts:
   the `<sid>.jsonl` file and, if present, the `<sid>\` folder; `certain`. `memory\`,
   ownerless stubs and the folder itself stay — they may belong to the other project.
4. **Nothing owned or foreign** — only `memory\` and/or ownerless stubs (5 of 17 folders
   on this machine are memory-only, presumably after Claude Code's own periodic
   transcript cleanup) → the whole folder, `probable`, but only if its name equals the
   project path encoded by the rule above (case-insensitive). Never deleted without
   `-IncludeProbable`.
5. Otherwise, nothing.

**Ownerless transcripts exist.** One of 25 transcripts on this machine is a single line
`{"type":"teleported-from","remoteSessionId":...}` with no `cwd`, no `<sid>\` folder, no
`file-history`. Counting it as foreign would make rule 3 strand the stub, `memory\` and
the folder for that project, so it is neither owned nor foreign.

Checked against all 17 folders here: for every transcript that has a `cwd`, the first
`cwd` encodes to exactly its folder's name.

Each artifact carries the session IDs it covers, for the next scanner.

**`Get-ClaudeSessionArtifacts -Roots -SessionIds`** — `file-history\<sid>` →
`claude:file-history`, `session-env\<sid>` → `claude:session-env`, both `certain`, only
for session IDs of **owned** transcripts (rules 2 and 3) — not ownerless stubs, not
rule-4 folders. Exact folder-name equality, no
prefix matching.

**`Get-ClaudeRunningSessions -Roots -ProjectUri`** — entries in `sessions\*.json` whose
`cwd` is under the project and whose `pid` is a live process. Read-only.

### Orchestration (`src/ProjectArtifacts.ps1`, new)

`Get-ProjectArtifacts -Project -Roots` runs the existing `Get-VSCodeProjectArtifacts` and
the Claude scanners and returns one list. The drive-root guard and the path-character
warning stay where they are and run first. Both `vscode-cleanup.ps1` and
`vscode-discover.ps1` switch to it, so the discovery diff covers Claude Code too.

**Parent warning:** if matched Claude transcripts have more than one distinct owner,
warn "`<path>` is a parent of N separate Claude Code projects", like the VS Code one.

## CLI (`vscode-cleanup.ps1`)

- Same name, same flags; HOWTO commands stay valid. New testing seam `-ClaudeRoot`,
  like `-CodeRoot`.
- Report heading becomes `Artifacts for project: <path>`; new sections
  `[claude:projects]`, `[claude:file-history]`, `[claude:session-env]`.
- With `-Delete`: if `Get-ClaudeRunningSessions` returns anything, warn that Claude Code
  is running in this project and should be quit first (the transcript is still being
  written). Warn, don't refuse — consistent with the VS Code check; a locked file is
  skipped and reported by the existing delete loop.

## Discovery (`vscode-discover.ps1`)

Also watches `ClaudeRoot`. Expected noise in the gaps, to be documented in the HOWTO
table: `backups\.claude.json.backup.*`, `plugins\`, `cache\`, `ide\`, `sessions\`,
`shell-snapshots\`, `.last-cleanup`, and writes from any *other* Claude Code session
running at the time (including one driving the test). `~\.claude.json` sits outside the
watched folder and will not appear.

## Error handling

- Missing `~\.claude` or any sub-root → that scanner returns nothing, no error.
- Unparseable transcript line → skip the line; no owner found → treat as unowned (rule 4
  or 5). Never guess an owner.
- Unparseable `sessions\*.json` → skip with a warning; the running check is advisory.

## Testing (Pester 3.4, fixtures under `$TestDrive`)

- Folder whose transcripts all belong to the project → one `certain` folder artifact.
- **Lossy-name collision:** one folder holding transcripts from `C:\x\A-B` and
  `C:\x\A B` → cleaning `A-B` returns only its `.jsonl` + `<sid>\`, never `memory\` or the
  folder.
- Sibling prefix: project `C:\x\A` does not match a transcript from `C:\x\A-main`.
- Descendant: project `C:\x\A` matches a transcript launched in `C:\x\A\sub`.
- Transcript that `cd`s away: only the first `cwd` counts.
- Folder with only `memory\` → `probable` when the name matches, nothing otherwise.
- Folder with owned transcripts plus an ownerless `teleported-from` stub → whole folder,
  `certain` (the stub does not turn it into rule 3).
- `file-history` / `session-env` returned only for matched session IDs; orphans ignored.
- Allowlist: accepts paths under the three Claude roots; rejects `ClaudeRoot` itself,
  `settings.json`, `sessions\`, `shell-snapshots\`, and the roots themselves.
- Running check: live pid + matching `cwd` → reported; dead pid or other `cwd` → not.
- CLI end to end with `-CodeRoot` and `-ClaudeRoot` fixtures: `-Delete` removes the
  Claude artifacts, `-WhatIf` removes nothing.
- All existing tests still pass.

## Docs

README and HOWTO: say the tool now covers Claude Code, list what it leaves alone, add
the Claude noise to the gaps table, and add "quit Claude Code in that project" to Step 1.
