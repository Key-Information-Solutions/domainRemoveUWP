<#
    KIS Bloatware Cleaner - removeUWP.ps1
    v2.4 (2026-09-23) - New -KeepOneDrive switch: keeps OneDrive (app + Store
    sync package) and the Office hub (part of Office for Business) while
    Teams is still removed. For
    on-prem-domain customers with Office for Business but no Teams/Entra
    (e.g. Colonial), where auto-detect would otherwise remove OneDrive.

    v2.3 (2026-08-18) - Dell SupportAssist removal hardened. The MSIX build
    ships as "Dell.SupportAssistforPCs"; the app list only had the older
    "DellInc.DellSupportAssistforPCs", and because matching is exact the Store
    copy was silently left installed AND provisioned (so it returned for every
    new profile). Both names are now listed, plus a pattern-based safety net,
    a pre-uninstall service stop to avoid MSI Error 1922, removal of the
    SupportAssist AutoUpdate reinstall task, and more leftover paths.

    v2.2 (2026-07-17) - OneDrive removal now cleans every profile (incl.
    future users via the Default profile), not just the invoking admin's.

    NOTE: the removeUWP.exe host downloads THIS file live from SharePoint at
    each run (embedded fallback if offline). Editing this file in the synced
    "source code" folder updates what every future run executes -- no rebuild.
    Keep the phrase "KIS Bloatware Cleaner" in this header: the host uses it
    as a sanity check on the downloaded content.

    Removes OEM/consumer bloatware for EVERY user profile on the machine and
    deprovisions it so future profiles start clean. Also removes Dell
    SupportAssist and applies misc cleanup (8.3 names, XPS, Fax & Scan).

    Runs from any elevated admin session (local, domain, or Entra admin).
    It never needs to run *as* the end user and never touches group membership,
    so there is no password prompt and no way to strip anyone's admin rights.

    Switches (all optional -- defaults auto-detect):
      -DryRun          Show what would be removed; change nothing
      -Azure           Force Entra mode: keep OneDrive/Teams/Office hub
                       (normally auto-detected via dsregcmd, flag kept for
                       muscle memory / odd cases like workgroup handoffs)
      -RemoveOneDrive  Remove OneDrive/Teams even on an Entra-joined machine
      -KeepOneDrive    Keep OneDrive + Office hub (Teams still removed),
                       regardless of join state. Cannot combine with
                       -RemoveOneDrive
      -Silent          No pause at the end (for RMM / automated use)
      -DebugMode       Pause before each step
#>
param(
    [switch]$DryRun,
    [switch]$Azure,
    [switch]$RemoveOneDrive,
    [switch]$KeepOneDrive,
    [switch]$Silent,
    [switch]$DebugMode,
    # Set by the exe host: 'live' (fetched from SharePoint) or 'embedded'
    # (baked-in fallback). 'direct' means the .ps1 was run on its own.
    [string]$ScriptSource = 'direct'
)

$ScriptVersion = '2.4'

# Self-elevate when launched as a bare .ps1 without admin. The exe wrapper
# already forces elevation via its UAC manifest, so this only fires on direct
# script runs. UAC accepts local, domain, or Entra admin credentials.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch] -or $p.Value -is [bool]) {
            if ($p.Value) { $argList += "-$($p.Key)" }
        } else {
            $argList += "-$($p.Key)"
            $argList += "`"$($p.Value)`""
        }
    }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Warning 'Elevation was cancelled. Nothing was changed.'
        if (-not $Silent) { Read-Host 'Press Enter to close' | Out-Null }
    }
    exit
}

$LogDir = 'C:\ProgramData\KIS\Logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ('removeUWP-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

# --- Environment detection (replaces the old getfqdn() domain guessing) ---
$dsreg = dsregcmd /status 2>$null
$EntraJoined  = [bool]($dsreg | Select-String -Quiet 'AzureAdJoined\s*:\s*YES')
$DomainJoined = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain
$KeepM365     = ($Azure -or $EntraJoined) -and -not $RemoveOneDrive
# -KeepOneDrive keeps OneDrive + Office hub; -Azure/Entra also keeps Teams.
$KeepOD       = $KeepM365 -or $KeepOneDrive

Write-Host "KIS Bloatware Cleaner v$ScriptVersion"
Write-Host "Script source: $ScriptSource"
Write-Host "Running as   : $(whoami) (elevated)"
Write-Host "Computer     : $env:COMPUTERNAME"
Write-Host "Entra joined : $EntraJoined    Domain joined: $DomainJoined"
Write-Host "Keep M365    : $KeepM365  (OneDrive/Teams/Office hub)"
Write-Host "Keep OneDrive: $KeepOD"
if ($DryRun) { Write-Host 'MODE         : DRY RUN -- nothing will be changed' }
Write-Host "Log          : $LogFile"

if ($KeepOneDrive -and $RemoveOneDrive) {
    Write-Warning '-KeepOneDrive and -RemoveOneDrive contradict each other. Nothing was changed.'
    Stop-Transcript | Out-Null
    if (-not $Silent) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

$script:Failures = 0
# Removal counters live here (not in the UWP section) so the SupportAssist
# section can add its own MSIX removals to the same summary totals.
$script:remCount  = 0
$script:provCount = 0
function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DebugMode) { Read-Host "Next: $Description  (Enter to continue)" | Out-Null }
    if ($DryRun) { Write-Host "[DRYRUN] Would run: $Description"; return }
    Write-Host ">> $Description"
    try { & $Action } catch { $script:Failures++; Write-Warning "FAILED: $Description -- $($_.Exception.Message)" }
}

# --- Dell SupportAssist (3.2* intentionally excluded, as in v1) ---
# SupportAssist ships as TWO independent products and needs both handled:
#   1. a Win32 MSI  ("Dell SupportAssist", has an ARP uninstall entry)
#   2. an MSIX/Store app ("Dell.SupportAssistforPCs", invisible to ARP and to
#      Win32_Product -- only Get-AppxPackage sees it)
# Removing only the MSI looks like success while the Store copy stays put.
Write-Host "`n=== Dell SupportAssist ==="

# Stop the agent BEFORE the MSI runs. A running -- or worse, StopPending --
# SupportAssistAgent makes the uninstall die with "Error 1922. Service Dell
# SupportAssist (SupportAssistAgent) could not be deleted. Verify that you have
# sufficient privileges to remove system services." That message blames rights,
# but elevation is not the problem: Windows refuses to delete a service wedged
# in a pending state, and the MSI misreports it. Force-killing clears it.
# (Hit on Marc-PC26, 2026-08-18.)
$saServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SupportAssist' })
foreach ($svc in $saServices) {
    Invoke-Step "Stop service $($svc.Name) (currently $($svc.Status))" {
        # Capture the PID before stopping -- a wedged service reports it, and we
        # need it to kill the process the graceful stop cannot. Never name this
        # $pid: that is a PowerShell automatic variable (our own process).
        $svcPid = (Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue).ProcessId
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        if ($svcPid) { Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue }
    }
}
$saProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SupportAssist' })
if ($saProcs) {
    Invoke-Step "Kill leftover SupportAssist processes ($($saProcs.Name -join ', '))" {
        $saProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# 1. Win32 MSI
$saEntries = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Get-ItemProperty |
    Where-Object { $_.DisplayName -match 'SupportAssist' -and $_.DisplayVersion -notlike '3.2*' }
if ($saEntries) {
    Write-Host 'Violently removing Dell SupportAssist'
    foreach ($sa in $saEntries) {
        if ($sa.UninstallString) {
            Invoke-Step "Uninstall $($sa.DisplayName) $($sa.DisplayVersion)" { cmd /c $sa.UninstallString /quiet /norestart }
        }
    }
} else {
    Write-Host 'No removable SupportAssist MSI found.'
}

# 2. MSIX / Store copy. The exact-name list further down is also updated, but
# this pattern sweep is the real fix: relying on an exact name is exactly how
# this slipped through (Dell dropped the "DellInc." publisher prefix and the
# list was never updated). Deliberately narrow -- SupportAssist only, never the
# whole Dell namespace, since Dell Command Update is intentionally kept.
# Provisioning must go too, or the app reinstalls into every NEW user profile.
$saAppx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SupportAssist' })
foreach ($pkg in $saAppx) {
    $userCount = @($pkg.PackageUserInformation).Count
    if ($DryRun) { Write-Host "[DRYRUN] Would remove MSIX $($pkg.Name) (installed for $userCount profile(s))"; continue }
    if ($DebugMode) { Read-Host "Next: remove MSIX $($pkg.Name)  (Enter to continue)" | Out-Null }
    try {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        Write-Host "Removed MSIX $($pkg.Name) ($userCount profile(s))"
        $script:remCount++
    } catch {
        $script:Failures++
        Write-Warning "Could not remove MSIX $($pkg.Name): $($_.Exception.Message)"
    }
}
$saProv = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'SupportAssist' })
foreach ($prov in $saProv) {
    if ($DryRun) { Write-Host "[DRYRUN] Would deprovision MSIX $($prov.DisplayName)"; continue }
    if ($DebugMode) { Read-Host "Next: deprovision MSIX $($prov.DisplayName)  (Enter to continue)" | Out-Null }
    try {
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        Write-Host "Deprovisioned MSIX $($prov.DisplayName)"
        $script:provCount++
    } catch {
        $script:Failures++
        Write-Warning "Could not deprovision MSIX $($prov.DisplayName): $($_.Exception.Message)"
    }
}
if (-not $saAppx -and -not $saProv) { Write-Host 'No SupportAssist MSIX package present.' }

# Any service the MSI still left registered (or that was already orphaned).
foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SupportAssist' })) {
    Invoke-Step "Delete leftover service $($svc.Name)" {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $svc.Name | Out-Null
    }
}

# "Dell SupportAssistAgent AutoUpdate" launches SupportAssistInstaller.exe --
# a live reinstall vector that outlives the MSI uninstall. Remove any SA task.
foreach ($saTask in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'SupportAssist' })) {
    Invoke-Step "Remove scheduled task '$($saTask.TaskName)'" { $saTask | Unregister-ScheduledTask -Confirm:$false }
}

# Leftover dirs. SARemediation shows up under ProgramData on some builds and
# Program Files on others (Marc-PC26 had the Program Files one), so check both.
foreach ($saPath in @('C:\ProgramData\Dell\SARemediation',
                      'C:\Program Files\Dell\SARemediation',
                      'C:\Program Files (x86)\Dell\SARemediation',
                      'C:\Program Files\Dell\SupportAssistAgent',
                      'C:\Program Files (x86)\Dell\SupportAssistAgent',
                      'C:\Program Files\Dell\SupportAssist',
                      'C:\Program Files (x86)\Dell\SupportAssist',
                      'C:\ProgramData\SupportAssist',
                      'C:\ProgramData\Dell\SupportAssist')) {
    if (Test-Path $saPath) {
        Invoke-Step "Remove $saPath" { Remove-Item $saPath -Recurse -Force }
    }
}

# --- UWP / Store apps ---
Write-Host "`n=== UWP / Store apps ==="
$UWPApps = @(
"26720RandomSaladGamesLLC.SimpleSolitaire"
"2B24874D.DealsOffers"
"4DF9E0F8.Netflix"
"598StudiosInc.qoolforToshiba"
"5A894077.McAfeeSecurity"
"828B5831.HiddenCityMysteryofShadows"
"89006A2E.AutodeskSketchBook"
"9E2F88E3.Twitter"
"A278AB0D.DisneyMagicKingdoms"
"A278AB0D.MarchofEmpires"
"AD2F1837.HPJumpStart"
"AD2F1837.SmartfriendbyHPCare"
"Amazon.com.Amazon"
"AMZNMobileLLC.KindleforWindows8"
"C27EB4BA.DropboxOEM"
"CAF9E577.Plex"
"ClearChannelRadioDigital.iHeartRadio"
"Clipchamp.Clipchamp"
"CyberLinkCorp.hs.PowerMediaPlayer14forHPConsumerPC"
"D52A8D61.FarmVille2CountryEscape"
"DB6EA5DB.MediaSuiteEssentialsforDell"
"DB6EA5DB.Power2GoforDell"
"DB6EA5DB.PowerDirectorforDell"
"DB6EA5DB.PowerMediaPlayerforDell"
"DellInc.DellCustomerConnect"
"DellInc.DellDigitalDelivery"
"DellInc.DellOptimizer"
# Both SupportAssist MSIX identities. Dell dropped the "DellInc." publisher
# prefix at some point; the old string stays for machines still shipping it.
# Matching here is exact (-contains), which is why the renamed package slipped
# through -- the SupportAssist section above also sweeps by pattern as a net.
"DellInc.DellSupportAssistforPCs"
"Dell.SupportAssistforPCs"
"DellInc.MyDell"
"DellInc.PartnerPromo"
"Disney.37853FC22B2CE"
"DropboxInc.Dropbox"
"E046963F.AIMeetingManager"
"E0469640.SmartAppearance"
"eBayInc.eBay"
"EnnovaResearch.ToshibaPlaces"
"HONHAIPRECISIONINDUSTRYCO.DellWatchdogTimer"
"HuluLLC.HuluPlus"
"king.com.BubbleWitch3Saga"
"king.com.CandyCrushFriends"
"king.com.CandyCrushSaga"
"king.com.CandyCrushSodaSaga"
"king.com.FarmHeroesSaga"
"McAfeeInc.04.McAfeeSecurityAdvisorforToshiba"
"Microsoft.3DBuilder"
"Microsoft.549981C3F5F10"
"Microsoft.BingFinance"
"Microsoft.BingFoodAndDrink"
"Microsoft.BingHealthAndFitness"
"Microsoft.BingNews"
"Microsoft.BingSports"
"Microsoft.BingTravel"
"Microsoft.BingWeather"
"Microsoft.Copilot"
"Microsoft.GamingApp"
"Microsoft.GetHelp"
"Microsoft.Getstarted"
"Microsoft.Messaging"
"Microsoft.Microsoft3DViewer"
"Microsoft.MicrosoftJournal"
"Microsoft.MicrosoftOfficeHub"
"Microsoft.MicrosoftSolitaireCollection"
"Microsoft.MicrosoftSudoku"
"Microsoft.MicrosoftTreasureHunt"
"Microsoft.MinecraftUWP"
"Microsoft.MixedReality.Portal"
"Microsoft.MSPaint"
"Microsoft.Office.OneNote"
"Microsoft.Office.Sway"
"Microsoft.OneConnect"
"Microsoft.OneDriveSync"
"Microsoft.OutlookForWindows"
"Microsoft.People"
"Microsoft.PowerAutomateDesktop"
"Microsoft.Print3D"
"Microsoft.Reader"
"Microsoft.RemoteDesktop"
"Microsoft.SkypeApp"
"Microsoft.SkypeWiFi"
"Microsoft.Todos"
"Microsoft.Wallet"
"Microsoft.Whiteboard"
"Microsoft.Windows.Ai.Copilot.Provider"
"Microsoft.Windows.DevHome"
"microsoft.windowscommunicationsapps"
"Microsoft.WindowsFeedbackHub"
"Microsoft.WindowsReadingList"
"Microsoft.Xbox.TCUI"
"Microsoft.XboxApp"
"Microsoft.XboxGameOverlay"
"Microsoft.XboxGamingOverlay"
"Microsoft.XboxIdentityProvider"
"Microsoft.XboxSpeechToTextOverlay"
"Microsoft.YourPhone"
"Microsoft.ZuneMusic"
"Microsoft.ZuneVideo"
"MicrosoftCorporationII.MicrosoftFamily"
"MicrosoftTeams"
"MicrosoftWindows.CrossDevice"
"MirametrixInc.GlancebyMirametrix"
"MSTeams"
"MSWP.DellTypeCStatus"
"NextIssue.NextIssueMagazines"
"PandoraMediaInc.29680B314EFC2"
"PricelinePartnerNetwork.Priceline.comTheBestDealso"
"RivetNetworks.KillerControlCenter"
"ScreenovateTechnologies.DellMobileConnectPlus"
"sMedioforToshiba.TOSHIBAMediaPlayerbysMedioTrueLin"
"SpotifyAB.SpotifyMusic"
"ToshibaAmericaInformation.ToshibaCentral"
"Weather.TheWeatherChannelforToshiba"
"WildTangentGames.63435CFB65F55"
"WinZipComputing.WinZipUniversal"
"ZapposIPInc.Zappos.com"
#Dell Command Update is useful and has not previously caused issues
)

if ($KeepM365) {
    $keepApps = 'Microsoft.OneDriveSync', 'MicrosoftTeams', 'MSTeams', 'Microsoft.MicrosoftOfficeHub'
    $UWPApps = $UWPApps | Where-Object { $keepApps -notcontains $_ }
    Write-Host "Entra mode: keeping $($keepApps -join ', ')"
} elseif ($KeepOneDrive) {
    $keepApps = 'Microsoft.OneDriveSync', 'Microsoft.MicrosoftOfficeHub'
    $UWPApps = $UWPApps | Where-Object { $keepApps -notcontains $_ }
    Write-Host "KeepOneDrive: keeping $($keepApps -join ', ')"
}

# One query each instead of one DISM/appx query per app name (v1 did ~119 of each).
Write-Host 'Scanning installed and provisioned packages...'
$installedTargets = Get-AppxPackage -AllUsers | Where-Object { $UWPApps -contains $_.Name }
$provTargets = Get-AppxProvisionedPackage -Online | Where-Object { $UWPApps -contains $_.DisplayName }

# NB: counters are initialised near the top -- do not reset them here, or the
# SupportAssist MSIX removals above would be dropped from the summary.
foreach ($pkg in $installedTargets) {
    $userCount = @($pkg.PackageUserInformation).Count
    if ($DryRun) { Write-Host "[DRYRUN] Would remove $($pkg.Name) (installed for $userCount profile(s))"; continue }
    if ($DebugMode) { Read-Host "Next: remove $($pkg.Name)  (Enter to continue)" | Out-Null }
    try {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        Write-Host "Removed $($pkg.Name) ($userCount profile(s))"
        $remCount++
    } catch {
        $script:Failures++
        Write-Warning "Could not remove $($pkg.Name): $($_.Exception.Message)"
    }
}

foreach ($prov in $provTargets) {
    if ($DryRun) { Write-Host "[DRYRUN] Would deprovision $($prov.DisplayName)"; continue }
    if ($DebugMode) { Read-Host "Next: deprovision $($prov.DisplayName)  (Enter to continue)" | Out-Null }
    try {
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        Write-Host "Deprovisioned $($prov.DisplayName)"
        $provCount++
    } catch {
        $script:Failures++
        Write-Warning "Could not deprovision $($prov.DisplayName): $($_.Exception.Message)"
    }
}
if (-not $installedTargets -and -not $provTargets) { Write-Host 'No targeted apps present -- nothing to do.' }

# --- OneDrive (all profiles) ---
# OneDrive is a per-user install, and this script runs elevated as whichever
# admin approved UAC -- so simply running OneDriveSetup /uninstall (the v1
# approach, which ran AS the logged-in user) only ever cleans the admin's own
# profile. Instead: machine-wide uninstall first, then direct cleanup of every
# local profile (binaries, run keys, uninstall entry, sidebar pin), then the
# Default profile's first-logon trigger so FUTURE users never get OneDrive.
# Only the app is touched -- any <profile>\OneDrive user-files folder is left
# alone.
Write-Host "`n=== OneDrive (all profiles) ==="
if ($KeepOD) {
    if ($KeepOneDrive) { Write-Host '-KeepOneDrive: keeping OneDrive.' }
    else { Write-Host 'Entra-joined (or -Azure): keeping OneDrive. Use -RemoveOneDrive to override.' }
} else {
    Invoke-Step 'Stop running OneDrive processes' {
        Get-Process -Name 'OneDrive', 'OneDriveSetup' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Machine-wide install (modern Win11 ships OneDrive under Program Files;
    # its uninstall entry carries the correct "/uninstall /allusers" command).
    $odMachine = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                   'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') |
        Where-Object { Test-Path $_ } | ForEach-Object { (Get-ItemProperty $_).UninstallString } | Where-Object { $_ }
    foreach ($odCmd in $odMachine) {
        Invoke-Step "Machine-wide OneDrive uninstall: $odCmd" { cmd /c $odCmd }
    }
    foreach ($stub in @("$env:windir\System32\OneDriveSetup.exe", "$env:windir\SysWOW64\OneDriveSetup.exe")) {
        if (Test-Path $stub) {
            Invoke-Step "Run in-box $stub /uninstall" { Start-Process $stub '/uninstall' -Wait }
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Invoke-Step 'winget uninstall Microsoft.OneDrive (machine scope)' { winget uninstall microsoft.onedrive --scope machine --accept-source-agreements }
    }

    # Per-profile cleanup. Loaded hives (logged-on users) are edited in place
    # under HKEY_USERS\<SID>; others are temp-loaded from NTUSER.DAT.
    $odProfiles = Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path (Join-Path $_.LocalPath 'NTUSER.DAT')) }
    foreach ($prof in $odProfiles) {
        $profName = Split-Path $prof.LocalPath -Leaf
        if ($DryRun) { Write-Host "[DRYRUN] Would clean OneDrive from profile '$profName'"; continue }
        if ($DebugMode) { Read-Host "Next: clean OneDrive from profile '$profName'  (Enter to continue)" | Out-Null }
        Write-Host ">> Cleaning OneDrive from profile '$profName'"
        $hiveRoot = "Registry::HKEY_USERS\$($prof.SID)"
        $loadedByUs = $false
        try {
            if (-not (Test-Path $hiveRoot)) {
                $null = reg load "HKU\$($prof.SID)" (Join-Path $prof.LocalPath 'NTUSER.DAT') 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'could not load profile hive' }
                $loadedByUs = $true
            }
            foreach ($runVal in 'OneDrive', 'OneDriveSetup') {
                Remove-ItemProperty -Path "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Run" -Name $runVal -ErrorAction SilentlyContinue
            }
            Remove-Item -Path "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe" -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($clsid in @("$hiveRoot\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                                 "$hiveRoot\Software\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}")) {
                if (Test-Path $clsid) { Set-ItemProperty -Path $clsid -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -ErrorAction SilentlyContinue }
            }
            $odAppDir = Join-Path $prof.LocalPath 'AppData\Local\Microsoft\OneDrive'
            if (Test-Path $odAppDir) { Remove-Item $odAppDir -Recurse -Force -ErrorAction SilentlyContinue }
            $odLnk = Join-Path $prof.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk'
            if (Test-Path $odLnk) { Remove-Item $odLnk -Force -ErrorAction SilentlyContinue }
        } catch {
            $script:Failures++
            Write-Warning "Profile '$profName': $($_.Exception.Message)"
        } finally {
            if ($loadedByUs) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                $null = reg unload "HKU\$($prof.SID)" 2>&1
                if ($LASTEXITCODE -ne 0) { Write-Warning "Profile '$profName': hive left loaded (unload failed); it will release at reboot." }
            }
        }
    }

    # Default profile: remove the first-logon trigger that installs OneDrive
    # into every newly created profile.
    if (Test-Path 'C:\Users\Default\NTUSER.DAT') {
        Invoke-Step 'Remove OneDrive first-logon trigger from the Default profile' {
            $null = reg load 'HKU\KISDefaultProfile' 'C:\Users\Default\NTUSER.DAT' 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'could not load Default profile hive' }
            try {
                Remove-ItemProperty -Path 'Registry::HKEY_USERS\KISDefaultProfile\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
            } finally {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                $null = reg unload 'HKU\KISDefaultProfile' 2>&1
            }
        }
    }

    foreach ($odTask in @(Get-ScheduledTask -TaskName '*OneDrive*' -ErrorAction SilentlyContinue)) {
        Invoke-Step "Remove scheduled task '$($odTask.TaskName)'" { $odTask | Unregister-ScheduledTask -Confirm:$false }
    }
}

# --- Misc cleanup ---
Write-Host "`n=== Misc cleanup ==="
Invoke-Step 'Disable 8.3 short filename creation' { fsutil behavior set disable8dot3 1 }

$xps = Get-WindowsOptionalFeature -Online -FeatureName Printing-XPSServices-Features -ErrorAction SilentlyContinue
if ($xps -and $xps.State -eq 'Enabled') {
    Invoke-Step 'Disable XPS printing feature' { Disable-WindowsOptionalFeature -Online -FeatureName Printing-XPSServices-Features -NoRestart -ErrorAction Stop | Out-Null }
} else {
    Write-Host 'XPS printing feature already absent.'
}

$faxScan = Get-WindowsCapability -Online | Where-Object { $_.Name -like '*Print.Fax.Scan*' -and $_.State -eq 'Installed' }
if ($faxScan) {
    foreach ($cap in $faxScan) {
        Invoke-Step "Remove capability $($cap.Name)" { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
    }
} else {
    Write-Host 'Windows Fax and Scan already absent.'
}

# Note: v1 ran "Set-ExecutionPolicy default" here. Dropped -- the bypass is
# process-scoped now, so there is no machine policy change to undo.

# --- Summary ---
Write-Host "`n=== Summary ==="
if ($DryRun) { Write-Host 'DRY RUN -- nothing was changed.' }
Write-Host "Apps removed: $remCount   Deprovisioned: $provCount   Failures: $($script:Failures)"
Write-Host "Log saved to: $LogFile"
Stop-Transcript | Out-Null
if (-not $Silent) { Read-Host 'Done. Press Enter to close' | Out-Null }
if ($script:Failures -gt 0) { exit 1 } else { exit 0 }
