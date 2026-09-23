<#
    REGTeches Media Stack Uninstaller
    Developed by Ronald Goodchild for your pleasure

    Stops and removes every REGTMS-* Windows service (including Seerr),
    the SABnzbd/qBittorrent/Jellyfin logon Scheduled Tasks, the Edge
    favorites folder and Desktop shortcut this stack created, and every
    firewall rule it opened. By default your media/config/downloads are
    left on disk -- pass -PurgeData to delete everything, including your
    media library references (the actual video/music/book files under
    \media are only removed if they still live under InstallRoot; anything
    you pointed elsewhere is untouched either way). -PurgeData also runs
    qBittorrent's own uninstaller first (it lives inside InstallRoot and
    would otherwise leave a stale "Apps & Features" entry once its files
    are gone).

    What this deliberately leaves alone, since none of it is stack-specific
    (see the warnings this script prints for each): Tailscale, Node.js/npm/
    pnpm (installed for Seerr), and Windows' own "enable long paths" setting
    (other software can depend on any of these; safest not to guess).
#>

param(
    [string]$InstallRoot = "C:\REGTechesMediaStack",
    [switch]$PurgeData,
    [switch]$RemoveJellyfin,
    [switch]$RemoveSABnzbd
)

$stackName = "REGTeches Media Stack"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
    Write-Host "Run this from an elevated (Administrator) PowerShell window." -ForegroundColor Red
    exit 1
}

$nssmExe = Join-Path $InstallRoot "tools\nssm.exe"
$services = @("REGTMS-Prowlarr","REGTMS-Sonarr","REGTMS-Radarr","REGTMS-Lidarr","REGTMS-Readarr","REGTMS-Whisparr","REGTMS-Seerr","REGTMS-Dashboard")

foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Write-Host "Stopping and removing $svc..." -ForegroundColor Cyan
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        if (Test-Path $nssmExe) {
            & $nssmExe remove $svc confirm | Out-Null
        } else {
            sc.exe delete $svc | Out-Null
        }
    }
}

# SABnzbd, qBittorrent, and Jellyfin all run as logon Scheduled Tasks, not
# services (Session 0 breaks all three -- see README).
$logonTasks = @(
    @{ Task = "REGTeches Media Stack - SABnzbd"; Process = @("SABnzbd", "SABnzbd-console") }
    @{ Task = "REGTeches Media Stack - qBittorrent"; Process = "qbittorrent" }
    @{ Task = "REGTeches Media Stack - Jellyfin"; Process = "jellyfin" }
)
foreach ($lt in $logonTasks) {
    if (Get-ScheduledTask -TaskName $lt.Task -ErrorAction SilentlyContinue) {
        Write-Host "Removing $($lt.Task)..." -ForegroundColor Cyan
        Stop-ScheduledTask -TaskName $lt.Task -ErrorAction SilentlyContinue
        Get-Process -Name $lt.Process -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $lt.Task -Confirm:$false
    }
}

# Everything the installer registered with Windows outside InstallRoot --
# none of it holds user data, so this always runs, not just under
# -PurgeData (same category as removing the services/tasks above).
$edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (Get-ItemProperty -Path $edgePolicyPath -Name "ManagedFavorites" -ErrorAction SilentlyContinue) {
    Write-Host "Removing the Edge favorites folder..." -ForegroundColor Cyan
    Remove-ItemProperty -Path $edgePolicyPath -Name "ManagedFavorites" -ErrorAction SilentlyContinue
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "$stackName.url"
if (Test-Path $desktopShortcut) {
    Write-Host "Removing the Desktop shortcut..." -ForegroundColor Cyan
    Remove-Item -Path $desktopShortcut -Force -ErrorAction SilentlyContinue
}

$firewallRules = Get-NetFirewallRule -DisplayName "$stackName*" -ErrorAction SilentlyContinue
if ($firewallRules) {
    Write-Host "Removing $(@($firewallRules).Count) firewall rule(s)..." -ForegroundColor Cyan
    $firewallRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# Jellyfin's installer is NSIS-based and only supports /D= to redirect the
# install folder -- if that switch wasn't honored (can happen with UAC
# self-elevation), it lands at the default Program Files location instead.
$jfUninstaller = Get-ChildItem -Path (Join-Path $InstallRoot "apps\Jellyfin") -Filter "Uninstall.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $jfUninstaller) {
    $jfUninstaller = Get-ChildItem -Path (Join-Path $env:ProgramFiles "Jellyfin") -Filter "Uninstall.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($RemoveJellyfin -and $jfUninstaller) {
    Write-Host "Uninstalling Jellyfin silently..." -ForegroundColor Cyan
    Start-Process -FilePath $jfUninstaller.FullName -ArgumentList "/S" -Wait
    Write-Host "Jellyfin uninstalled." -ForegroundColor Green
} elseif ($PurgeData -and $jfUninstaller -and -not $RemoveJellyfin) {
    Write-Host "WARNING: -PurgeData will delete Jellyfin's files, but Jellyfin itself won't be uninstalled --" -ForegroundColor Red
    Write-Host "its 'Apps & Features' entry will be left pointing at a deleted folder." -ForegroundColor Red
    Write-Host "Re-run with -RemoveJellyfin too for a clean removal." -ForegroundColor Red
} elseif ($jfUninstaller) {
    Write-Host "Jellyfin is still installed (pass -RemoveJellyfin to also uninstall it)." -ForegroundColor Yellow
}

# SABnzbd's own installer forces itself into Program Files on 64-bit
# Windows regardless of what this stack asked for (see README), so its
# program files live outside InstallRoot and -PurgeData alone won't touch them.
$sabProgramDir = Join-Path $env:ProgramFiles "SABnzbd"
$sabInstalled = Test-Path (Join-Path $sabProgramDir "Uninstall.exe")
if ($RemoveSABnzbd -and $sabInstalled) {
    Write-Host "Uninstalling SABnzbd silently..." -ForegroundColor Cyan
    Start-Process -FilePath (Join-Path $sabProgramDir "Uninstall.exe") -ArgumentList "/S" -Wait
    Write-Host "SABnzbd uninstalled." -ForegroundColor Green
} elseif ($PurgeData -and $sabInstalled -and -not $RemoveSABnzbd) {
    Write-Host "WARNING: SABnzbd itself lives in $sabProgramDir, not under $InstallRoot --" -ForegroundColor Red
    Write-Host "-PurgeData won't remove it. Re-run with -RemoveSABnzbd too for a clean removal." -ForegroundColor Red
} elseif ($sabInstalled) {
    Write-Host "SABnzbd is still installed at $sabProgramDir (pass -RemoveSABnzbd to also uninstall it)." -ForegroundColor Yellow
}

# Unlike Jellyfin/SABnzbd, qBittorrent's own installer honors /D= and lands
# entirely inside InstallRoot -- no separate -RemoveQBittorrent flag needed,
# since -PurgeData already means "delete it". Still worth running its own
# uninstaller first, though: it registers an "Apps & Features" entry
# (confirmed from its own NSIS installer source) that -PurgeData's plain
# folder delete would otherwise leave pointing at nothing.
$qbtUninstaller = Join-Path $InstallRoot "apps\qBittorrent\uninst.exe"
if ($PurgeData -and (Test-Path $qbtUninstaller)) {
    Write-Host "Uninstalling qBittorrent silently..." -ForegroundColor Cyan
    Start-Process -FilePath $qbtUninstaller -ArgumentList "/S" -Wait
    Write-Host "qBittorrent uninstalled." -ForegroundColor Green
}

$ts = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
if ($ts) {
    Write-Host "Tailscale is still installed (it's host-wide networking, not stack-specific)." -ForegroundColor Yellow
    Write-Host "Remove it separately from Windows Settings -> Apps -> Tailscale if you no longer want it." -ForegroundColor Yellow
}

if (Test-Path "C:\Program Files\nodejs\node.exe") {
    Write-Host "Node.js (installed for Seerr) is still installed -- it's a general-purpose runtime, not stack-specific, so this leaves it alone." -ForegroundColor Yellow
    Write-Host "Remove it separately from Windows Settings -> Apps -> Node.js if nothing else on this machine needs it (this also takes pnpm with it)." -ForegroundColor Yellow
}

if ($PurgeData) {
    Write-Host "Removing $InstallRoot ..." -ForegroundColor Yellow
    Remove-Item -Path $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Done. All REGTeches Media Stack files, config, and API keys were deleted." -ForegroundColor Green
} else {
    Write-Host "Services removed. Files, media, and config left in place at $InstallRoot." -ForegroundColor Green
    Write-Host "Re-run Install-REGTechesMediaStack.ps1 any time to recreate the services." -ForegroundColor Green
}
