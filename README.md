# KIS Bloatware Cleaner (removeUWP) — v2

One self-contained `removeUWP.exe`: download from the portal, double-click,
approve UAC, done. The exe is a ~20 KB launcher that **fetches the live
`removeUWP.ps1` from KIS SharePoint at each run** (the copy in this folder,
via its "Anyone with the link" share URL), so script updates ship by simply
editing the synced file — no rebuild, no re-upload. A copy of the script is
also embedded in the exe at build time as an automatic fallback for offline
or locked-down sites. Either way it runs with a **process-scoped**
ExecutionPolicy bypass, so nothing about the machine's script policy is
touched, and the transcript records which source ran (`live` / `embedded`).

## What changed vs v1 (the Python/PyInstaller `domainRemoveUWP.exe`)

| v1 behavior | v2 behavior |
|---|---|
| Ran the removal *as the logged-in user* — temporarily added them to Administrators, prompted for their password, removed them from the group after | Runs once, elevated, as whichever admin approves UAC. `Remove-AppxPackage -AllUsers` cleans **every** profile. Group membership is never touched — the "removed myself as admin" lockout can't happen |
| Guessed the domain from DNS (`socket.getfqdn()`) — broke on Entra, VPNs, offsite laptops | No domain guessing at all. Entra/domain join detected via `dsregcmd` / WMI, used only for mode selection and logging |
| `--azure` had to be remembered, and was silently dropped on the elevated relaunch | Entra join is **auto-detected** → OneDrive/Teams/Office hub kept automatically. `-Azure` still accepted as a manual override |
| Downloaded and ran whatever was on a personal GitHub repo's `main` at runtime | Fetches the script from KIS-controlled SharePoint, with a build-time embedded copy as offline fallback; the transcript logs which one ran |
| One appx + one DISM query per app name (~119 each, slow) | One query each, filtered in memory |
| Ran `Set-ExecutionPolicy default` at the end (stomped GPO/company policy) | Dropped — bypass is process-scoped, nothing to undo |
| Errors silently ignored | Per-step try/catch, failure count, transcript log |

## Shipping a script update (the normal case)

Edit `removeUWP.ps1` in this folder and let OneDrive sync it. That's the
whole deploy — every future run everywhere fetches the new version.

**This file is production.** Saving it into this folder publishes it to every
machine that runs the tool afterward. For anything non-trivial, edit a copy
outside the synced folder, test it (run the `.ps1` directly with `-DryRun` —
it self-elevates), and only then paste it back here. Bump `$ScriptVersion` so
logs show which version ran.

## Rebuilding the exe (rare)

Only needed when `host.cs` changes, the share link is regenerated, or you
want to refresh the embedded fallback copy to a newer script baseline.
Double-click `build.cmd`, grab `dist\removeUWP.exe`. The build uses the C#
compiler that ships in Windows (.NET Framework 4.x) — works on any Windows
10/11 PC, no Python/PyInstaller/modules.

## Publishing

Test `dist\removeUWP.exe` on a bench machine first (start with `-DryRun`),
then copy it up to the **Bloatware cleaner** folder root so it syncs to the
public portal (tools.keydns.us). The old `domainRemoveUWP.exe` at the root is
v1 — delete it once v2 is validated.

## Switches (all optional — plain double-click does the right thing)

| Switch | Effect |
|---|---|
| `-DryRun` | List everything that *would* be removed; change nothing |
| `-Azure` | Force Entra mode (keep OneDrive/Teams/Office hub). Normally auto-detected |
| `-RemoveOneDrive` | Remove OneDrive even on an Entra-joined machine |
| `-Silent` | No "Press Enter" pause at the end — for RMM/automated runs |
| `-DebugMode` | Pause before each step |
| `-Embedded` | Skip the SharePoint fetch and run the copy baked into the exe (escape hatch if a bad edit lands on SharePoint) |

Run the bare `.ps1` directly and it self-elevates (UAC), so techs can also
right-click → Run with PowerShell if they ever need to.

Logs: `C:\ProgramData\KIS\Logs\removeUWP-<timestamp>.log` (full transcript).

## Distribution plumbing

- The exe downloads `removeUWP.ps1` via the read-only share link with
  `?download=1` appended (SharePoint's instant-download format). The URL is
  the `ScriptUrl` constant in `host.cs`. If the share link is ever
  regenerated or the file moves, update that constant and rebuild.
- The link is anonymous ("Anyone with the link"), which is what lets customer
  PCs fetch it — and also means whoever can edit this file controls code that
  runs as admin on every machine using the tool. It lives in KIS's tenant
  behind KIS accounts, which is the point of moving off the personal GitHub
  repo; just treat edit access to this folder accordingly.
- The host sanity-checks the download (must contain "KIS Bloatware Cleaner",
  so a SharePoint error/login page never gets executed) and falls back to the
  embedded copy on any failure, after ~10–20 s at fully offline sites.
- The git repo in this folder is now optional dev history, not part of
  distribution. Keep it or delete `.git` — nothing references it.

## Notes / review candidates

- App list is identical to v1 (duplicate `Microsoft.Todos` entry deduped).
- `Microsoft.OutlookForWindows` is still removed even in Entra mode — same as
  v1, but worth a think for M365 customers using new Outlook.
- The exe is unsigned (same as v1), so SmartScreen shows the usual
  "unrecognized app" prompt on first download. If KIS ever gets a code-signing
  cert, signing `dist\removeUWP.exe` removes that prompt.
- v1 source (`removeUWP.py`, `removeUWP.spec`) is superseded but left in place.
