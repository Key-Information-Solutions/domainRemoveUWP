# Post-build for removeUWP.exe (called by build.cmd):
#   1. Copy dist\removeUWP.exe to the "Bloatware cleaner" folder root.
#      Overwriting the existing file keeps the same SharePoint item, so the
#      portal / share URL keeps working and now serves the new build.
#   2. Compute its SHA256.
#   3. Stamp that hash into the removeUWP.exe pin in the Computer Setup
#      tool's pins.json. The setup tool reads pins.json from the share at
#      runtime, so the new exe is accepted as soon as OneDrive syncs -- no
#      Computer Setup rebuild. Building this exe is the human "yes, ship
#      this" that check-pins.py otherwise asks for.
$ErrorActionPreference = 'Stop'

$src  = Join-Path $PSScriptRoot 'dist\removeUWP.exe'
$dest = Join-Path (Split-Path $PSScriptRoot -Parent) 'removeUWP.exe'
Copy-Item $src $dest -Force
$hash = (Get-FileHash $dest -Algorithm SHA256).Hash
Write-Host "Published : $dest"
Write-Host "SHA256    : $hash"

$pins = Join-Path $PSScriptRoot '..\..\Computer Setup\source code\pins.json'
if (Test-Path $pins) {
    # Regex rather than ConvertTo-Json, which would reformat the whole file.
    # Anchored on the pin's key, so only this entry can ever be touched.
    $pinsPath = (Resolve-Path $pins).Path
    $text = [IO.File]::ReadAllText($pinsPath)
    $pattern = '("removeUWP\.exe"\s*:\s*\{[^}]*?"sha256"\s*:\s*")[0-9A-Fa-f]{64}'
    if ($text -match $pattern) {
        $new = $text -replace $pattern, ('${1}' + $hash)
        if ($new -ne $text) {
            [IO.File]::WriteAllText($pinsPath, $new)
            Write-Host "pins.json : removeUWP.exe re-pinned (live once OneDrive syncs)."
        } else {
            Write-Host "pins.json : removeUWP.exe pin already current."
        }
    } else {
        Write-Warning "pins.json: no removeUWP.exe pin found."
        Write-Warning "Run check-pins.py in the Computer Setup source folder to pin: $hash"
    }
} else {
    Write-Warning "pins.json not found at $pins"
    Write-Warning "Run check-pins.py in the Computer Setup source folder to pin: $hash"
}
