# Step by step

Two parts:

- **[Part 1 — Check the tool sees everything](#part-1--check-the-tool-sees-everything)**
  A one-off. Already done once; redo it after a big VS Code update.
- **[Part 2 — Clean up a project](#part-2--clean-up-a-project)**
  The thing you'll actually do, every time.

---

# Once per PC — tell PowerShell where the tool is

The commands below use `$env:CLEANER_HOME` instead of a hard-coded path, so no personal
path lives in this repo. Set it once, from inside the folder you cloned this repo into:

```powershell
[Environment]::SetEnvironmentVariable('CLEANER_HOME', (Get-Location).Path, 'User')
```

Then **close and reopen PowerShell** — new windows pick it up, the current one doesn't.
Check it with `$env:CLEANER_HOME`; it should print the folder.

If you ever move the repo, run the same line again from the new location.

---

# Part 1 — Check the tool sees everything

**You do not need this before every cleanup.** It's a one-time validation: it proves the
cleanup tool isn't blind to some artifact VS Code writes. Run it once (done — see
`docs/discovery-findings.md`), then again only if VS Code has a major update and you
suspect the layout changed.

1. **Quit VS Code completely.** All windows, check the tray.

2. **Use `$env:USERPROFILE\A` as the test folder** (that is, `C:\Users\<you>\A`).
   It must not exist yet — if it's left over from a previous run, do step 14 first to
   clear it out. Don't create it yet.

3. **Start the watcher first:**

   ```powershell
   cd $env:CLEANER_HOME
   .\vscode-discover.ps1 -Project "$env:USERPROFILE\A"
   ```

   Wait for `Watching 3 root(s).` Leave the window open. Don't press Enter yet.

4. **Now create the folder:** `mkdir "$env:USERPROFILE\A"`

5. **Open it in VS Code.**

6. **Add two or three files, type something, save.**

7. **Start a Claude Code session in that folder** (a second PowerShell window:
   `cd "$env:USERPROFILE\A"; claude`), ask it to edit one of the files, let it make the
   edit, then quit it (`/exit`).

8. **Close the VS Code window.**

9. **Reopen the same folder.**

10. **Quit VS Code entirely.**

11. **Press Enter** in the PowerShell window.

12. **Check `Covered` is not zero** in the output. If it's zero, the `-Project` path didn't
    match the folder you opened — fix it and redo from step 3.

13. **Open the `.gaps.txt` file** it names.

> The path after `-Project` must be exactly the folder you open in VS Code and start
> Claude Code in.

## Reading the gaps file

Most of it is expected. Group what you see:

| Path contains | Meaning |
|---|---|
| `Service Worker`, `Local Storage`, `Session Storage`, `WebStorage`, `SharedStorage`, `Cache`, `CachedData`, `CachedConfigurations`, `GPUCache`, `Dawn…Cache`, `Network`, `blob_storage`, `Crashpad` | Electron browser cache. Shared by all projects, never per-project deletable. **Ignore.** |
| `logs\` | Window logs. Already handled as `probable`. **Ignore.** |
| `workspaceStorage\<digits>` (a long number, not a hex hash) | VS Code's per-session scratch. It deletes these itself on exit. **Ignore.** |
| `User\globalStorage\storage.json` | One shared file for all 190 projects. **Never delete.** |
| `User\globalStorage\agent-host-config.json` (and `agent-host.db`, `agent-host-storage.json`) | VS Code's agent/Copilot settings. Lists your project once, in a shared `workspaceTrust` list of every trusted folder. **Never delete.** |
| `User\globalStorage\state.vscdb`, `vscode.git\askpass`, `*.tmp` | Shared global state and short-lived helper files. **Ignore.** |
| `workspaceStorage\<hex hash>` of a *different* project | Another VS Code window was open during the test (e.g. this repo). Correctly not claimed. **Ignore.** |
| `.claude\backups`, `.claude\plugins`, `.claude\cache`, `.claude\ide`, `.claude\sessions`, `.claude\shell-snapshots`, `.claude\.last-cleanup` | Claude Code's own shared state. **Ignore.** |
| `.claude\session-env\<id>` or `.claude\projects\<other>` of a *different* session | Another Claude Code session was running during the test (e.g. the one in this repo). **Ignore.** |
| **Anything else under `User\` or `.claude\`** | **This is the interesting part.** |

If that last row is empty, the tool is complete. Nothing to do.

If it isn't — something under `User\` that mentions your project and isn't in
`workspaceStorage` or `History` — that's a real gap and the tool needs a new scanner.

14. **Clean up the throwaway** (VS Code still closed):

    ```powershell
    cd $env:CLEANER_HOME
    .\vscode-cleanup.ps1 -Project "$env:USERPROFILE\A" -Delete
    Remove-Item "$env:USERPROFILE\A" -Recurse -Force
    ```

---

# Part 2 — Clean up a project

This is the routine one. Takes about two minutes.

The worked example deletes VS Code's leftovers for `D:\Nuxt\mastering-nuxt-3`. Swap in
whatever project you actually want.

---

## Step 1 — Quit VS Code and Claude Code completely

Not just the project's window. **All of VS Code.**

Close every window, then check the system tray and Task Manager for a lingering `Code.exe`.

Also quit any **Claude Code** session that was started in the project (or a folder inside
it). A running session keeps writing its transcript.

> **Heads-up:** this also deletes Claude Code's **memory** for that project
> (`~\.claude\projects\<project>\memory\`). If there's something in it you want to keep,
> copy it out first.

> **Why this matters more than it sounds.** VS Code keeps a lock on `state.vscdb` for every
> workspace it touched since it started, and only lets go when it exits. When this was
> tested, 14 workspaces were locked while only 2 windows were open — including projects
> whose windows had been closed hours earlier.
>
> If you skip this step nothing breaks. Deletion just fails on the locked files, tells you
> so, and you do it again afterwards.

Check it's really gone:

```powershell
Get-Process -Name 'Code','Code - Insiders' -ErrorAction SilentlyContinue
```

No output means you're clear.

---

## Step 2 — Open PowerShell in the tool folder

```powershell
cd $env:CLEANER_HOME
```

---

## Step 3 — Look before you touch

Run it **without** `-Delete`. This only reads.

```powershell
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\mastering-nuxt-3'
```

You'll see something like:

```
Found 15 artifact(s), 0.76 MB
Report: C:\...\cleaner\vscode-artifacts-mastering-nuxt-3-20260922.txt
Nothing was deleted. Re-run with -Delete to purge.
```

Three things to check in that output:

- **The count.** 15 for one project is normal — VS Code makes a new workspace folder each
  time you reopen a project. Hundreds would mean you passed a parent directory.
- **No warnings.** If you got one, jump to [If something looks off](#if-something-looks-off).
- **The report path.** You want that next.

---

## Step 4 — Read the report

```powershell
notepad .\vscode-artifacts-mastering-nuxt-3-20260922.txt
```

It looks like this:

```
Artifacts for project: D:\Nuxt\mastering-nuxt-3
Generated: 2026-09-22 12:11:25

[History] 7 item(s), 32652 bytes
  (certain) 727 bytes   C:\...\Code\User\History\-1d98c2f7
  (certain) 4575 bytes  C:\...\Code\User\History\-20e5b96d
  ...

[workspaceStorage] 8 item(s), 762272 bytes
  (certain) 114740 bytes  C:\...\Code\User\workspaceStorage\00b0847d...
  ...

TOTAL: 794924 bytes across 15 artifact(s)
```

What you're looking at:

- **`History`** — copies of your files from every edit-and-save, VS Code's local undo history
- **`workspaceStorage`** — per-workspace state: open tabs, search history, extension data
- **`(certain)`** — VS Code's own metadata says this belongs to your project. Safe.
- **`(probable)`** — only a *log* that mentions your project, or a Claude Code project
  folder with just `memory\` left that matches by folder name alone. Not deleted by
  default. [More on those below.](#about-probable)
- **`claude:projects`** — Claude Code chat transcripts, subagent transcripts and project memory
- **`claude:file-history`** — Claude Code's copies of files from before it edited them
- **`claude:session-env`** — Claude Code per-session environment data

Glance down the paths. Every one should sit under `AppData\Roaming\Code\User\` or `.claude\`. If
something looks wrong, stop and ask — don't continue.

---

## Step 5 — Delete

Same command, plus `-Delete`:

```powershell
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\mastering-nuxt-3' -Delete
```

```
Found 15 artifact(s), 0.76 MB
Report: C:\...\cleaner\vscode-artifacts-mastering-nuxt-3-20260922.txt
Deleted 15 artifact(s).
```

**`Deleted 15` should match `Found 15`.** If it's lower, something was locked — almost
always VS Code still running. Go back to Step 1 and run this again; it's safe to repeat.

> Want to see it happen without it happening? Add `-WhatIf`. It prints every deletion it
> would make, deletes nothing, and still writes the report.

---

## Step 6 — Confirm it's gone

```powershell
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\mastering-nuxt-3'
```

```
Found 0 artifact(s), 0 MB
```

`0` means clean. Done.

---

## Step 7 — Delete the project folder itself, if you want

This tool only removes VS Code's leftovers. Your actual folder is untouched. Delete it
normally, in Explorer or however you like.

(Order doesn't matter. The tool works fine on projects whose folder is already gone —
that's what it's for.)

---

# If something looks off

## "VS Code is running"

```
WARNUNG: VS Code is running. Quit it completely before deleting - closing the
project's window is not enough...
```

Go back to Step 1. Deletion will partly or completely fail until you do.

## "Could not delete ... used by another process"

Same cause. The tool skips that one, keeps going with the rest, and reports the real
count. Quit VS Code and re-run — repeating is harmless.

## "is a parent of N separate VS Code projects"

```
WARNUNG: 'D:\Nuxt' is a parent of 53 separate VS Code projects...
```

You passed a folder that *contains* projects rather than a project. `D:\Nuxt` covers 53 of
them; `Documents\GitHub` covers 68. That's legitimate if you really are deleting the whole
tree — but if you meant one project, add the project name to the path and re-run.

## "Project path contains character(s) that appear nowhere..."

Your path has something like `#`, `&`, `+` or `(`. The way VS Code encodes those hasn't
been verified against real data, so artifacts *might* be missed. Nothing unsafe gets
deleted — just don't assume `Found 0` means clean for that project.

## "A drive root is not a project"

You passed `D:\` or similar. Refused deliberately: that would match every artifact on the
whole drive. Give it an actual project path.

## Found 0 artifacts but you expected some

Usually the path doesn't match exactly what VS Code recorded. Check the spelling against
its own list:

```powershell
Get-ChildItem "$env:APPDATA\Code\User\workspaceStorage" -Directory | ForEach-Object {
    $m = Join-Path $_.FullName 'workspace.json'
    if (Test-Path $m) { (Get-Content $m -Raw | ConvertFrom-Json).folder }
} | Sort-Object -Unique
```

Find yours in that list. `file:///d%3A/Nuxt/foo` means `D:\Nuxt\foo`.

---

# About `probable`

Artifacts marked `(probable)` are one of two things:

- **VS Code window logs** — matched only because your project's path appears somewhere in
  the log text.
- **Claude Code project folders with only `memory\` left** (`claude:projects`) — no
  transcript remains to say whose they are, so they match by folder name alone.

They are never deleted unless you ask:

```powershell
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo' -Delete -IncludeProbable
```

**Usually don't.** A window log belongs to *every project opened in that window*. In
testing, two different projects both resolved the same `window6` log — deleting it for one
would have thrown away a log still relevant to the other. VS Code rotates old logs away by
itself anyway, so leaving them costs you nothing.

The Claude Code folder name is lossy: `D:\Nuxt\A-B` and `D:\Nuxt\A B` both become
`D--Nuxt-A-B`. So `-IncludeProbable` on `...\A-B` can also delete the Claude Code memory
of the different project `...\A B`. Check every `(probable)` Claude Code folder in the
report is really yours first.

`certain` Claude Code data — folders or transcripts whose recorded launch directory is
your project — needs none of this: plain `-Delete` removes it, like the `certain` VS Code
artifacts.

---

# Doing several projects

One command per project. There's no bulk mode on purpose.

Simplest way — just repeat the line, one per project:

```powershell
cd $env:CLEANER_HOME
.\vscode-cleanup.ps1 -Project "$env:USERPROFILE\A" -Delete
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\old-one' -Delete
```

Each one prints its own `Found` / `Deleted` counts, so you can see which succeeded.

For a longer list, loop instead:

```powershell
'D:\Nuxt\old-one', 'D:\Nuxt\old-two', "$env:USERPROFILE\A" |
    ForEach-Object { .\vscode-cleanup.ps1 -Project $_ -Delete }
```

Quit VS Code first, same as always. Run it once without `-Delete` to see the totals before
you commit.

To find candidates — every project VS Code knows about whose folder no longer exists:

```powershell
Get-ChildItem "$env:APPDATA\Code\User\workspaceStorage" -Directory | ForEach-Object {
    $m = Join-Path $_.FullName 'workspace.json'
    if (-not (Test-Path $m)) { return }
    $u = (Get-Content $m -Raw | ConvertFrom-Json).folder
    if (-not $u) { return }
    $p = [System.Uri]::UnescapeDataString($u.Substring(8)) -replace '/','\'
    if (-not (Test-Path $p)) { $p }
} | Sort-Object -Unique
```

On this machine that lists **77 distinct projects**, holding 100 `workspaceStorage`
folders and 679 `History` folders — **49.7 MB** in total.

Feed that list straight in if you're feeling brave — but run it without `-Delete` first,
and read what comes back:

```powershell
$dead | ForEach-Object { .\vscode-cleanup.ps1 -Project $_ }
```
