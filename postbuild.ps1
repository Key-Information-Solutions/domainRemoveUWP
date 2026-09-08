# Post-build for removeUWP.exe (called by build.cmd):
#   1. Copy dist\removeUWP.exe to the "Bloatware cleaner" folder root.
#      Overwriting the existing file keeps the same SharePoint item, so the
#      portal / share URL keeps working and now serves the new build.
#   2. Compute its SHA256.
#   3. Stamp that hash into uninstall_bloatware() in the Computer Setup
#      tool's installs.py (anchored on the share-link token of the exe's
#      download URL, so only that entry can ever be touched).
$ErrorActionPreference = 'Stop'

$src  = Join-Path $PSScriptRoot 'dist\removeUWP.exe'
$dest = Join-Path (Split-Path $PSScriptRoot -Parent) 'removeUWP.exe'
Copy-Item $src $dest -Force
$hash = (Get-FileHash $dest -Algorithm SHA256).Hash
Write-Host "Published : $dest"
Write-Host "SHA256    : $hash"

$installs = Join-Path $PSScriptRoot '..\..\Computer Setup\source code\installs.py'
if (Test-Path $installs) {
    # Share-link token of the exe's SharePoint URL inside uninstall_bloatware().
    # If that share link is ever regenerated, update the URL in installs.py AND
    # this marker to its new token.
    $marker = 'EZv41R8oLOVFkMRYA7a_tgQBgvQTMSYzj6aQhe1570vHmw'
    $installsPath = (Resolve-Path $installs).Path
    $text = [IO.File]::ReadAllText($installsPath)
    $pattern = "($marker[^\r\n]*?)[0-9A-Fa-f]{64}"
    if ($text -match $pattern) {
        $new = $text -replace $pattern, ('${1}' + $hash)
        if ($new -ne $text) {
            [IO.File]::WriteAllText($installsPath, $new)
            Write-Host "installs.py: SHA256 updated for uninstall_bloatware()."
            Write-Host "REMINDER  : rebuild the Computer Setup tool so the new hash ships."
        } else {
            Write-Host "installs.py: hash already current."
        }
    } else {
        Write-Warning "installs.py: removeUWP entry not found (marker $marker)."
        Write-Warning "Update its SHA256 manually to: $hash"
    }
} else {
    Write-Warning "installs.py not found at $installs"
    Write-Warning "Update its removeUWP SHA256 manually to: $hash"
}
