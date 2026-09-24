# Discovery findings

What the resolver misses, and what must never be deleted per-project.

Task 17 has two halves. The **retrospective** half is done and recorded below: it asks
whether anything under `%APPDATA%\Code` mentions a project but falls outside what the
resolver returns. The **live** half — running `vscode-discover.ps1` through a real VS Code
session — is still outstanding, and is the only way to find artifacts that have no textual
link to the project at all.

## Method (retrospective)

Scanned all 44,205 files under `%APPDATA%\Code` for a plain substring match on
`file:///d%3A/Nuxt/mastering-nuxt-3`, then checked which matches fell outside the 15
artifacts the resolver returns for that project. Took 851 seconds.

Result: 61 files mention the project URI. 31 are inside a resolver artifact. 30 are not.

## Finding 1 — the 30 "uncovered" files are siblings, not gaps

Not a gap. A validation.

All 30 belong to *different projects* whose paths happen to begin with the same
characters. The six `workspaceStorage` folders resolve to:

```
file:///d%3A/Nuxt/mastering-nuxt-3%20fixed/nuxt-course
file:///d%3A/Nuxt/mastering-nuxt-3%20fixed
file:///d%3A/Nuxt/mastering-nuxt-3%204.6
file:///d%3A/Nuxt/mastering-nuxt-3%204.3
file:///d%3A/Nuxt/mastering-nuxt-3-main
file:///d%3A/Nuxt/mastering-nuxt-3%20-%20Kopie
```

and the eleven `History` entries point at files inside those same siblings.

The scan used a naive substring match — precisely the approach `Test-UriUnderProject` was
written to reject. It produced 30 false positives and the resolver excluded every one.
This is the sibling-collision hazard the spec calls out, measured against real data:
a cleanup built on substring matching would have deleted six other projects' state.

**Classification: no action.** The boundary check works.

## Finding 2 — `User\globalStorage\storage.json` is shared, and must never be deleted

**Classification: shared/global. Never delete per-project. No scanner should be added.**

A single 31 KB file holding state for *all* projects at once:

- `profileAssociations.workspaces` — 192 entries, one per project
- `backupWorkspaces`, `windowsState`, `windowSplashWorkspaceOverride`
- `telemetry.sqmId`, `telemetry.machineId`, `telemetry.devDeviceId`
- `theme`, `themeBackground`, `windowControlHeight`

It references 192 distinct project URIs. Deleting it to clean up one project would
discard every other project's association, the window layout, and the machine's telemetry
identity.

It *does* contain a per-project entry, so a surgical edit is theoretically possible:
remove one key from `profileAssociations.workspaces`. That is deliberately not done.
Rewriting a live shared JSON file that VS Code may hold open, to reclaim a few hundred
bytes, trades a real risk of corrupting global state against no meaningful disk saving.
The tool's contract is to delete whole directories it can attribute with certainty.

## Finding 3 — timestamp-named `workspaceStorage` folders that identify nothing

**Classification: not project-specific. No scanner. Genuinely orphaned — see below.**

This is what the live discovery run was for, and it found something the retrospective
scan could not.

Six `workspaceStorage` folders are named by millisecond timestamp rather than the usual
32-hex hash, contain only `state.vscdb`, and have **no `workspace.json`**:

```
1790059424687   2026-09-22 08:43:44
1790059461907   2026-09-22 08:44:21
1790070512547   2026-09-22 11:48:32
1790070732817   2026-09-22 11:52:12
1790071394772   2026-09-22 12:03:14   <- created during the discovery run
1790071477686   2026-09-22 12:04:37   <- created during the discovery run
```

Two appeared while the watcher was running, so VS Code creates them on startup. Nothing
inside records which folder, if any, they belong to.

This is precisely the failure mode the tool had to be checked for: an artifact with no
reverse mapping to a project. The resolver cannot attribute them, so per-project cleanup
will never remove them — but neither could any correct per-project rule, because they do
not belong to a project. Adding a scanner would mean guessing.

### Correction — these are not garbage, and no sweep should be built

An earlier revision of this document called them "garbage nothing will ever collect" and
proposed an orphan-sweep feature. **That was wrong**, and the measurement that disproved
it is worth recording because it nearly became a feature that deletes live files.

Two observations, in order:

1. All 6 had their `state.vscdb` **locked by a running process**, while all 5 sampled
   *attributed* folders were unlocked. So they were in active use, not abandoned.
2. After VS Code was fully quit, the count went from 6 to **0**. VS Code deletes them
   itself on exit.

They are per-session scratch storage with a lifetime of one VS Code run. The whole
machine reconciles: `workspaceStorage` went 265 → 257 across a quit-and-cleanup cycle,
which is exactly 6 self-collected sessions plus 2 folders this tool deleted.

**No orphan sweep. No scanner.** A rule of "`workspaceStorage` entries with no
`workspace.json`" would have targeted files VS Code had open, and would have raced its
own cleanup for no benefit.

An interim reading — that the 6 corresponded to 6 open *windows* — was also wrong. The
user had two windows open, not six. A lock indicates only that VS Code touched the
workspace during the session and retains the handle until it exits; it says nothing about
whether a window is open. Closing a window does not release it.

## Finding 4 — everything else written during a session is shared cache

Of the 385 paths recorded during the live run, the top-level buckets were:

```
130  Service Worker      6  CachedData        3  Network
130  Local Storage       3  CachedConfigurations   3  blob_storage
 73  logs               32  User              1  Crashpad
```

Everything outside `User\` is browser-engine cache belonging to the Electron shell, not
to any project: shared, never per-project deletable, and consistent with the spec's
decision to keep caches out of scope. The `User\` paths are the `workspaceStorage` and
`History` entries the resolver already handles, plus the two orphans from Finding 3.

No new project-specific artifact type was discovered. The resolver's four sources are
complete for self-identifying artifacts.

## Note on the run itself

The diff reported zero covered paths. That is not a tool fault: the run was started with
`-Project 'C:\Users\<you>\Desktop\throwaway-test'` while the folder actually opened
in VS Code during the watch was `throwaway-2`. Both are now registered workspaces, so the
resolver was answering about a project that saw no writes during the window.

Worth fixing in the script rather than in documentation: `vscode-discover.ps1` could warn
when `Covered` is zero but `Written` is not, since that combination almost always means
the watched session and the `-Project` argument disagree.

## Reclaimable space, measured

The question behind the whole tool — how much is left behind — answered across the whole
machine rather than one project:

```
workspaceStorage   159 folders, 24.0 MB   project still exists on disk
                   100 folders, 11.5 MB   project GONE from disk
                     6 folders,  0.1 MB   unattributable (Finding 3)

History           1297 folders, 71.7 MB   source file still exists
                   679 folders, 38.2 MB   source file GONE

TOTAL RECLAIMABLE                49.7 MB  across projects no longer on disk
```

Largest single dead project: `d:\Nuxt\mastering-nuxt-3`, 8 workspaceStorage folders,
0.73 MB — deleted from disk, still fully present in VS Code's state.

## Finding 5 — locked files, and what "close VS Code" has to mean

Verified end to end on a real deletion. With VS Code running, deleting a project's
`workspaceStorage` fails with a sharing violation on `state.vscdb`; the `History` entry
for the same project deletes fine. `Remove-VSCodeArtifacts` handled that correctly — it
warned, skipped the locked artifact, deleted the other, and reported the true count
rather than claiming success.

The important part is which files are locked. VS Code held handles for **14** workspaces
while only **2** windows were open, including projects whose windows had been closed
hours earlier. The handle is retained for any workspace touched during the session and
released only when VS Code exits.

So the CLI's warning — "Close it first" — is too weak, because it is naturally read as
closing the project's window, which does nothing. It must say quit VS Code entirely.

## Finding 6 — a window log belongs to every project opened in that window

Both throwaway projects resolved the *same* `logs\...\window6` directory, 1.68 MB,
because both had been opened through that window. It was correctly left alone: `logs`
artifacts are `probable`, and `-IncludeProbable` was not passed.

Had it been deleted for one project it would have destroyed a log belonging to the other.
This is the confidence tier doing exactly what it exists for, on real data. It is also a
caution about `-IncludeProbable`: a window log is shared by every project that window
touched, and nothing in the log structure separates them.

## Finding 7 — second machine: `agent-host-config.json` is shared too

**Classification: shared/global. Never delete per-project. No scanner should be added.**

A live run was repeated on a second PC (2026-09-24), with a newer VS Code, against a
fresh test folder `C:\Users\<you>\A`. The `-Project` path matched: 410 paths written,
22 covered, 388 gaps.

The 22 covered paths were the test folder's one `workspaceStorage` folder — including
`chatSessions` and `chatEditingSessions`, which the resolver takes along because they sit
inside it — and its two `History` entries.

The gaps split the same way as Finding 4, with three additions under `User\`:

- **`globalStorage\agent-host-config.json`** (plus `agent-host.db`, `agent-host-storage.json`),
  new since the first run. It holds VS Code's agent/Copilot settings. It *does* name the
  test folder, but only as one entry in a `workspaceTrust` list of 31 trusted folders,
  among ~50 unrelated settings. Same shape as `storage.json` (Finding 2): one shared file
  with a per-project line in it. Not edited, for the same reason.
- **`workspaceStorage\<hash>` of a different project.** The `cleaner` repo itself was open
  in another window during the run. Its `workspace.json` names that repo, so the resolver
  was right not to claim it.
- **`globalStorage\vscode.git\askpass\*`** and `Code\*.tmp` — short-lived helper files for
  git credential prompts and VS Code's own writes. Not project-specific.

Nothing project-specific was missed. The resolver's sources still cover everything that
can be attributed to one project.

A second full cycle on the same PC — clean up, delete the folder, recreate it, run again —
gave the same picture: 408 written, 21 covered, 387 gaps, and no new path under `User\`.
The first cycle's `workspaceStorage` folder was gone, confirming the cleanup had removed
it. VS Code gave the recreated folder a new `workspaceStorage` hash. The only new name in
the gaps was `WebStorage\QuotaManager`, which is Electron's storage bookkeeping, i.e. shared cache.

## Conclusion

Both halves of Task 17 are done. The retrospective scan found no missed self-identifying
artifact. The live run found one unattributable artifact type, which turned out to be
VS Code's own per-session storage that it collects on exit (Finding 3).

The resolver's four sources — `workspaceStorage`, `History`, `Backups`, `logs` — are
complete for everything that can be attributed to a project. **No scanner was added, and
no orphan sweep is needed.**

Verified by real deletion: after quitting VS Code, both throwaway projects resolve zero
artifacts, and the machine-wide count moved 265 → 257 with every one of those 8 folders
accounted for.

## Scope note

Findings 1–6 are from one project on one machine; Finding 7 repeats the live run on a
second machine with a newer VS Code and reaches the same conclusion. The sibling result generalises — it is a
property of the matching logic, not of this data. The `globalStorage` result generalises
too, since that file is structurally shared. Neither says anything about extensions not
installed here.
