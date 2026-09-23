<#
    REGTeches Media Stack Updater
    Developed by Ronald Goodchild for your pleasure

    Checks each *arr app's GitHub repo for a newer version than what's
    recorded in config\state.json. For anything newer, stops its service,
    replaces the binaries, and restarts it. Your appdata/config/API keys
    are untouched -- only the apps\<Name> folder is replaced.

    Also checks and updates Seerr, but differently: it has no prebuilt
    binary at all (see the installer), so updating it means re-fetching its
    source and rebuilding with pnpm, not just swapping a folder -- can take
    several minutes.

    NOT covered here, same as always: SABnzbd, qBittorrent, Jellyfin, and
    Tailscale. Each has its own real installer rather than a plain
    GitHub-release zip, so none of them fit this script's "swap the folder"
    model -- update those from their own UI/installer, or re-run
    Install-REGTechesMediaStack.ps1 (Jellyfin/Tailscale silently no-op if
    already current; SABnzbd/qBittorrent only reinstall if missing).
#>

param([string]$InstallRoot = "C:\REGTechesMediaStack")

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdmin)) {
    Write-Host "Run this from an elevated (Administrator) PowerShell window." -ForegroundColor Red
    exit 1
}

$ghHeaders = @{ "User-Agent" = "REGTechesMediaStack-Updater" }
$statePath = Join-Path $InstallRoot "config\state.json"
if (-not (Test-Path $statePath)) { Write-Host "No state.json found -- run the installer first." -ForegroundColor Red; exit 1 }
$state = @{}
(Get-Content $statePath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }

$apps = @(
    [pscustomobject]@{ Name="Prowlarr"; Repo="Prowlarr/Prowlarr"; ZipPattern="windows-core-x64\.zip$" }
    [pscustomobject]@{ Name="Sonarr";   Repo="Sonarr/Sonarr";     ZipPattern="win-x64\.zip$" }
    [pscustomobject]@{ Name="Radarr";   Repo="Radarr/Radarr";     ZipPattern="windows-core-x64\.zip$" }
    [pscustomobject]@{ Name="Lidarr";   Repo="Lidarr/Lidarr";     ZipPattern="windows-core-x64\.zip$" }
    [pscustomobject]@{ Name="Readarr";  Repo="Readarr/Readarr";   ZipPattern="windows-core-x64\.zip$" }
    [pscustomobject]@{ Name="Whisparr"; Repo="Whisparr/Whisparr"; ZipPattern="win-x64\.zip$" }
)

foreach ($app in $apps) {
    $svcName = "REGTMS-$($app.Name)"
    if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) { continue }

    try {
        $release = $null
        try { $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.Repo)/releases/latest" -Headers $ghHeaders }
        catch { $release = (Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.Repo)/releases?per_page=5" -Headers $ghHeaders) | Select-Object -First 1 }

        $current = $state["$($app.Name)_Version"]
        if ($release.tag_name -eq $current) {
            Write-Host "$($app.Name): up to date ($current)" -ForegroundColor Gray
            continue
        }

        Write-Host "$($app.Name): $current -> $($release.tag_name), updating..." -ForegroundColor Cyan
        $asset = $release.assets | Where-Object { $_.name -match $app.ZipPattern } | Select-Object -First 1
        $zipPath = Join-Path $InstallRoot "apps\$($app.Name)-update.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -Headers $ghHeaders

        Stop-Service -Name $svcName -Force
        $appFolder = Join-Path $InstallRoot "apps\$($app.Name)"
        Remove-Item -Path $appFolder -Recurse -Force
        Microsoft.PowerShell.Archive\Expand-Archive -Path $zipPath -DestinationPath $appFolder -Force
        Remove-Item $zipPath -Force
        Start-Service -Name $svcName

        $state["$($app.Name)_Version"] = $release.tag_name
        Write-Host "$($app.Name) updated to $($release.tag_name)" -ForegroundColor Green
    } catch {
        Write-Host "$($app.Name): update failed -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Seerr: no prebuilt binary exists (see the installer's own comments on
# this), so "updating" means re-fetching its source and rebuilding with
# pnpm rather than swapping a folder -- structurally different enough from
# the loop above that it isn't worth forcing into the same shape.
$seerrSvc = "REGTMS-Seerr"
if (Get-Service -Name $seerrSvc -ErrorAction SilentlyContinue) {
    try {
        $release = $null
        try { $release = Invoke-RestMethod -Uri "https://api.github.com/repos/seerr-team/seerr/releases/latest" -Headers $ghHeaders }
        catch { $release = (Invoke-RestMethod -Uri "https://api.github.com/repos/seerr-team/seerr/releases?per_page=5" -Headers $ghHeaders) | Select-Object -First 1 }

        $current = $state["Seerr_Version"]
        if ($release.tag_name -eq $current) {
            Write-Host "Seerr: up to date ($current)" -ForegroundColor Gray
        } else {
            Write-Host "Seerr: $current -> $($release.tag_name), updating (rebuilds from source -- can take several minutes)..." -ForegroundColor Cyan
            $seerrRoot = Join-Path $InstallRoot "apps\Seerr"
            $seerrZip = Join-Path $InstallRoot "apps\seerr-update.zip"
            Invoke-WebRequest -Uri "https://github.com/seerr-team/seerr/archive/refs/tags/$($release.tag_name).zip" -OutFile $seerrZip -UseBasicParsing -Headers $ghHeaders

            Stop-Service -Name $seerrSvc -Force

            $seerrExtract = Join-Path $InstallRoot "apps\seerr_update_extract"
            Microsoft.PowerShell.Archive\Expand-Archive -Path $seerrZip -DestinationPath $seerrExtract -Force
            $extractedRoot = Get-ChildItem -Path $seerrExtract -Directory | Select-Object -First 1
            Remove-Item -Path $seerrRoot -Recurse -Force
            Move-Item $extractedRoot.FullName $seerrRoot
            Remove-Item $seerrZip, $seerrExtract -Recurse -Force -ErrorAction SilentlyContinue

            # Same "ask npm where its global prefix actually is" fix as the
            # installer -- confirmed live that pnpm.cmd doesn't reliably
            # end up under Node's own install dir.
            $npmCmd = "C:\Program Files\nodejs\npm.cmd"
            $npmGlobalPrefix = (& $npmCmd prefix -g 2>$null | Select-Object -Last 1)
            $pnpmCmd = Join-Path $npmGlobalPrefix.Trim() "pnpm.cmd"
            if (-not (Test-Path $pnpmCmd)) {
                $seerrPkg = Get-Content (Join-Path $seerrRoot "package.json") -Raw | ConvertFrom-Json
                $pnpmVersion = if ($seerrPkg.packageManager -match '^pnpm@([\d.]+)') { $Matches[1] } else { "10" }
                Write-Host "Seerr: installing pnpm $pnpmVersion..." -ForegroundColor Cyan
                & $npmCmd install -g "pnpm@$pnpmVersion" | Out-Null
            }

            $env:CYPRESS_INSTALL_BINARY = "0"
            Push-Location $seerrRoot
            try {
                & $pnpmCmd install --frozen-lockfile
                if ($LASTEXITCODE -ne 0) { throw "pnpm install failed (exit $LASTEXITCODE)" }
                & $pnpmCmd build
                if ($LASTEXITCODE -ne 0) { throw "pnpm build failed (exit $LASTEXITCODE)" }
            } finally {
                Pop-Location
            }
            if (-not (Test-Path (Join-Path $seerrRoot "dist\index.js"))) { throw "Build finished but dist\index.js still doesn't exist." }

            Start-Service -Name $seerrSvc
            $state["Seerr_Version"] = $release.tag_name
            Write-Host "Seerr updated to $($release.tag_name)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Seerr: update failed -- $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "If Seerr won't start now, re-run Install-REGTechesMediaStack.ps1 -- it detects and fixes a half-finished build." -ForegroundColor Yellow
        Start-Service -Name $seerrSvc -ErrorAction SilentlyContinue
    }
}

($state | ConvertTo-Json -Depth 6) | Set-Content -Path $statePath -Encoding UTF8
Write-Host "Update check complete." -ForegroundColor Green
