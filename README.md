# VS Code project cleanup

> **First time, or just want the steps?** Read **[HOWTO.md](HOWTO.md)** instead — it walks
> through cleaning one project from start to finish. This file is the reference.

Finds everything VS Code wrote **outside** a project folder on that project's behalf —
local file history, workspace storage, unsaved-buffer backups, window logs — so a project
can be deleted properly instead of leaving state behind forever.

It works retroactively. A project you deleted months ago still has its VS Code state, and
this finds it.

---

## Quick start

```powershell
cd $env:CLEANER_HOME   # one-time setup: see HOWTO.md

# 1. Look, don't touch
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\some-project'

# 2. Read the report it names, then actually delete
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\some-project' -Delete
```

It never deletes without `-Delete`. Both forms write a report file you can read first.

---

## Quit VS Code first. Completely.

This is the one thing that will waste your time if you forget it.

VS Code keeps `state.vscdb` **open for every workspace it touched during the session** and
releases those handles only when it exits. Measured here: 14 workspaces locked while just
2 windows were open, including projects whose windows had been closed hours earlier.

So **closing the project's window does nothing.** Quit VS Code entirely — all windows,
and check the system tray.

If you don't, deletion fails on the locked files with a sharing violation, the tool warns
and tells you honestly how many it actually removed, and you re-run it afterwards. Nothing
breaks; you just do it twice.

---

## Flags

| Flag | What it does |
|---|---|
| `-Project <path>` | Required. The project folder. Must be a real drive path (`D:\...`). |
| `-Delete` | Actually delete. Without it, report only. |
| `-WhatIf` | Show what `-Delete` would remove, without removing it. Still writes the report. |
| `-IncludeProbable` | Also delete window logs. **Read the warning below first.** |
| `-ReportPath <file>` | Where to write the report. Defaults to a timestamped file in the current directory. |
| `-CodeRoot <dir>` | Point at a different VS Code data folder. For testing, or a portable install. |

---

## certain vs probable

The report marks every artifact one of two ways.

**`certain`** — ownership came from VS Code's own metadata: a `folder` URI, a `resource`
URI, or a matching workspace hash. These are deleted by `-Delete`.

**`probable`** — a window log that merely *mentions* the project's path. Skipped unless you
pass `-IncludeProbable`.

**Why `-IncludeProbable` deserves care:** a window log belongs to *every project opened in
that window*. Observed here — two different projects both resolved the same
`logs\...\window6`, 1.68 MB. Deleting it for one would have destroyed a log still relevant
to the other. VS Code also rotates old logs away by itself, so leaving them alone usually
costs nothing.

---

## What it refuses to do

Each of these exists because it was a real hazard, not a hypothetical:

- **Won't delete outside VS Code's artifact folders.** Only `workspaceStorage`, `History`,
  `Backups` and `logs`. Not `settings.json`, not `snippets`, not your extensions.
- **Won't accept a drive root.** `D:\`, `D:\.`, `D:\..`, `D:\\` are all refused. That path
  would otherwise match every artifact on the drive.
- **Won't delete a tree containing a junction or symlink**, and refuses if it cannot fully
  inspect one.
- **Validates everything before deleting anything**, so a bad entry can't leave you half
  purged.
- **Won't stop on one locked file** — it warns, skips it, and continues with the rest.

---

## Warnings you may see

**"is a parent of N separate VS Code projects"**
You passed a folder that contains other projects. `D:\Nuxt` sweeps in 53 of them;
`Documents\GitHub` 68. That's correct behaviour — deleting a parent folder does mean
deleting everything under it — but make sure it's what you meant.

**"Project path contains character(s) that appear nowhere in this machine's VS Code data"**
Your path has a character like `#`, `&`, `+` or `(` whose URI encoding hasn't been verified
against real data. Artifacts might be missed. Check the report before deleting.

**"VS Code is running"**
See above. Quit it completely.

---

## What it does *not* touch

- **Your project folder.** Only VS Code's leftovers. Delete the folder yourself.
- **Shared caches** — `Service Worker`, `Local Storage`, `CachedData`, `GPUCache`,
  `Network`. These belong to the Electron shell, not to any project.
- **`User\globalStorage\storage.json`** — one 31 KB file holding all 192 projects'
  associations plus window layout and telemetry IDs. Shared, never per-project deletable.
- **Unattributed `workspaceStorage` folders** (timestamp-named, no `workspace.json`).
  These are VS Code's per-session scratch and it deletes them itself on exit. Verified:
  6 of them vanished the moment VS Code was quit.

---

## vscode-discover.ps1

A one-off sanity check, already run. It watches what VS Code writes during a real session
and diffs that against what the cleanup tool would find, to catch artifacts the resolver is
blind to. Results are in `docs/discovery-findings.md`: no missed artifact type.

You'd only re-run it after a major VS Code update, if you suspect the layout changed:

```powershell
.\vscode-discover.ps1 -Project "$env:USERPROFILE\A"
```

Start it **first**, wait for `Watching 2 root(s)`, *then* create and open that exact folder
in VS Code, edit something, close, reopen, quit VS Code, press Enter. If the `-Project`
path and the folder you open disagree, it now tells you instead of reporting everything as
a gap.

---

## Worth knowing

On this machine, as measured: **49.7 MB** is held for projects that no longer exist on
disk — 11.5 MB across 100 `workspaceStorage` folders and 38.2 MB across 679 `History`
folders. 259 workspace folders for 190 distinct projects.

There's no bulk "clean every dead project" mode. One project per invocation, deliberately.

---

## Tests

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests
```

86 tests. Run them after any change — several guardrails here look like defensive noise
and are actually load-bearing. `docs/superpowers/plans/` records why each one exists.
