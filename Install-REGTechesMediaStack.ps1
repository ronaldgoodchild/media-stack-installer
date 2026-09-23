<#
    REGTeches Media Stack Installer
    Developed by Ronald Goodchild for your pleasure

    Installs Prowlarr, Sonarr, Radarr, Lidarr, Readarr, Whisparr, SABnzbd and
    Jellyfin natively on Windows 11 (no Docker), wires them together, and wires
    them up per TRaSH-Guides conventions (root folders, categories, download
    client, Prowlarr sync, Recyclarr for quality profiles/custom formats).

    Usage (elevated PowerShell):
        powershell -ExecutionPolicy Bypass -File .\Install-REGTechesMediaStack.ps1

    Re-running is safe: every step checks current state first and skips work
    that is already done.
#>

param(
    [string]$InstallRoot = "C:\REGTechesMediaStack",
    # Where movies/TV actually live. Empty (default) keeps the old behavior --
    # nested under $InstallRoot\media. Set this to split media storage from the
    # apps/appdata/downloads on the install drive: a separate local drive
    # (e.g. D:\Media) or a mapped/UNC NAS path (e.g. \\192.168.1.50\vol3\media,
    # your NAS). The share must already exist and be reachable when the installer
    # runs; the \media subfolder itself is created if missing.
    [string]$MediaRoot = "",
    [string[]]$SkipApps = @(),
    [switch]$OpenFirewallPorts,
    [switch]$SkipRecyclarr,
    [string]$AdminUsername = "media",
    [string]$AdminPassword = "",   # blank = generate a random one on first run (re-runs reuse it)
    [switch]$SkipTailscale,
    [string]$TailscaleAuthKey = "",
    [switch]$SkipQBittorrent,
    [string]$UsenetHost = "",
    [int]$UsenetPort = 563,
    [string]$UsenetUsername = "",
    [string]$UsenetPassword = "",
    [int]$UsenetConnections = 8,
    [switch]$UsenetNoSSL,
    [switch]$SkipSizeLimits,
    # Sonarr/Radarr/Whisparr express quality-definition size limits as MB
    # per minute of runtime, not a flat file size -- these defaults are
    # picked to land at roughly 2-4GB for a ~45min TV episode and 8-10GB
    # for a ~2hr movie, the stock TRaSH-Guides/Sonarr defaults being
    # considerably more generous (up to ~155 MB/min, i.e. 18GB+ for a
    # 2hr movie -- confirmed by reading Sonarr's own QualityDefinitionService
    # defaults). Only applied to 720p/1080p; Remux and 2160p/4K are left
    # alone since a cap sized for standard encodes would make Remux
    # unusable, and this stack doesn't default to 4K.
    [int]$MaxTvEpisodeSizeMBPerMin = 70,
    [int]$MaxMovieSizeMBPerMin = 77,
    [switch]$SkipJellyfinPlugins,
    [switch]$SkipSeerr
)

$ErrorActionPreference = "Stop"
$SkipApps = @($SkipApps | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$stackName = "REGTeches Media Stack"
$ghHeaders = @{ "User-Agent" = "REGTechesMediaStack-Installer" }

# ============================================================
# Bootstrap: paths, logging, admin check
# ============================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "REGTeches Media Stack must be installed from an elevated (Administrator) PowerShell window." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as administrator, then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Windows' classic 260-character path limit is a real problem for this stack:
# release names from indexers are long, qBittorrent nests multi-file torrents
# into a subfolder named after the release, and everything sits under an
# already-longish InstallRoot -- confirmed as the cause of a live "I/O error"
# on a real download (ruled out permissions first: a plain write test to the
# same folder succeeded fine). This lifts the limit for apps that opt in,
# which modern qBittorrent/.NET-based *arr apps do automatically.
$longPathsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
if ((Get-ItemProperty -Path $longPathsKey -Name "LongPathsEnabled" -ErrorAction SilentlyContinue).LongPathsEnabled -ne 1) {
    Set-ItemProperty -Path $longPathsKey -Name "LongPathsEnabled" -Value 1 -Type DWord
    Write-Host "Enabled Windows long path support (was off -- this is what caused the I/O error on long release names)." -ForegroundColor Yellow
}

$paths = @{
    Root       = $InstallRoot
    Apps       = Join-Path $InstallRoot "apps"
    AppData    = Join-Path $InstallRoot "appdata"
    Tools      = Join-Path $InstallRoot "tools"
    Media      = if ($MediaRoot) { $MediaRoot } else { Join-Path $InstallRoot "media" }
    Downloads  = Join-Path $InstallRoot "downloads"
    Dashboard  = Join-Path $InstallRoot "dashboard"
    Logs       = Join-Path $InstallRoot "logs"
    Config     = Join-Path $InstallRoot "config"
}
if ($MediaRoot) {
    $mediaDriveRoot = [System.IO.Path]::GetPathRoot($MediaRoot)
    if (-not $mediaDriveRoot -or -not (Test-Path $mediaDriveRoot)) {
        Write-Host "MediaRoot '$MediaRoot' isn't reachable -- its drive/share '$mediaDriveRoot' doesn't exist. Map the drive (or fix the path) and re-run." -ForegroundColor Red
        exit 1
    }
}
foreach ($p in $paths.Values) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
foreach ($m in @("movies", "tv", "music", "books", "adult")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $paths.Media $m) | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $paths.Downloads "complete\$m") | Out-Null
}
New-Item -ItemType Directory -Force -Path (Join-Path $paths.Downloads "incomplete") | Out-Null

$logFile = Join-Path $paths.Logs "install.log"
function Log {
    param([string]$msg, [string]$level = "INFO")
    $line = "{0}`t{1}`t{2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    $line | Tee-Object -FilePath $logFile -Append | Out-Null
    switch ($level) {
        "ERROR" { Write-Host $msg -ForegroundColor Red }
        "WARN"  { Write-Host $msg -ForegroundColor Yellow }
        "OK"    { Write-Host $msg -ForegroundColor Green }
        default { Write-Host $msg -ForegroundColor Gray }
    }
}

Log "Media library: $($paths.Media)$(if ($MediaRoot) { ' (custom -MediaRoot)' } else { ' (default, under -InstallRoot)' })."

$statePath = Join-Path $paths.Config "state.json"
$state = @{}
if (Test-Path $statePath) {
    try { (Get-Content $statePath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } } catch {}
}
function Save-State {
    ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $statePath -Encoding UTF8
}

# The dashboard runs as its own separate process/service and needs these to
# query qBittorrent's session-based API. state.json already holds every
# app's API key in plaintext (same trust boundary: whoever can read this
# file already has full control of the stack), so this adds no new exposure.
$GeneratedPassword = $false
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    if ($state["AdminPassword"] -and -not [string]::IsNullOrWhiteSpace([string]$state["AdminPassword"])) {
        $AdminPassword = [string]$state["AdminPassword"]      # re-run: keep the login chosen on first install
    } else {
        $pwBytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($pwBytes)
        $AdminPassword = ([Convert]::ToBase64String($pwBytes) -replace '[^A-Za-z0-9]', '').Substring(0, 20)
        $GeneratedPassword = $true
    }
}
if ($OpenFirewallPorts -and @('media1', 'password', 'admin', 'changeme') -contains $AdminPassword) {
    Write-Host "Heads up: you're opening LAN access with a weak password. Pick a strong -AdminPassword before exposing this beyond your own LAN." -ForegroundColor Yellow
}
$state["AdminUsername"] = $AdminUsername
$state["AdminPassword"] = $AdminPassword

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " $stackName" -ForegroundColor Cyan
Write-Host " Developed by Ronald Goodchild for your pleasure" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Log "Installer started. InstallRoot=$InstallRoot"

# ============================================================
# Generic helpers
# ============================================================

function Invoke-DownloadFile {
    param([string]$Url, [string]$OutFile, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers $ghHeaders
            return
        } catch {
            Log "Download attempt $i failed for $Url : $($_.Exception.Message)" "WARN"
            Start-Sleep -Seconds 3
        }
    }
    throw "Failed to download $Url after $Retries attempts"
}

function Resolve-GitHubAsset {
    <# Finds the download URL for the newest release asset matching a regex.
       Falls back to including pre-releases if no stable release exists
       (needed for Readarr, whose upstream repo is archived/dev-only). #>
    param([string]$Repo, [string]$Pattern)

    $release = $null
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $ghHeaders
    } catch {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=5" -Headers $ghHeaders
        $release = $releases | Select-Object -First 1
    }
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' found in $Repo latest release ($($release.tag_name))" }
    return [pscustomobject]@{
        Version = $release.tag_name
        Url     = $asset.browser_download_url
        Name    = $asset.name
    }
}

function Wait-ForHttpOk {
    param([string]$Url, [int]$TimeoutSec = 90)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { return $true }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -lt 500) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-ForJellyfinApiReady {
    # Confirmed live: Wait-ForHttpOk on Jellyfin's base URL returns true
    # within seconds of the scheduled task starting -- Kestrel accepts
    # connections and serves the static web UI well before Jellyfin's own
    # internal services (library manager, plugin manager, etc.) finish
    # initializing. Every real API route keeps returning 503 "Jellyfin
    # Server is loading. Please try again shortly." during that window.
    # Calling an API too early during that window doesn't fail gracefully --
    # it throws, which (via the AuthenticateByName call) cascaded into the
    # library step failing outright, which then made the plugin step fail
    # too (it reuses $jfHeaders, never set because the library step's own
    # try threw before reaching that assignment -- so a 401 instead of the
    # real 503). Poll a real API endpoint and specifically wait out 503s
    # instead of just checking that the port is open.
    param([string]$JfBase, [int]$TimeoutSec = 90)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            Invoke-RestMethod -Uri "$JfBase/System/Info/Public" -TimeoutSec 5 | Out-Null
            return $true
        } catch {
            $resp = $_.Exception.Response
            if ($resp -and [int]$resp.StatusCode -ne 503) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---- NSSM (service wrapper for the portable *arr / SABnzbd console builds) ----
# Their own installers just add a "run at login" shortcut, not a real Windows
# service. NSSM wraps any console exe as a proper auto-starting, self-healing
# service that runs with no one logged in -- the right behavior for a server.

$nssmExe = Join-Path $paths.Tools "nssm.exe"
if (-not (Test-Path $nssmExe)) {
    Log "Downloading NSSM (service wrapper)..."
    $nssmZip = Join-Path $paths.Tools "nssm.zip"
    Invoke-DownloadFile -Url "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    $nssmExtract = Join-Path $paths.Tools "nssm_extract"
    Microsoft.PowerShell.Archive\Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    Copy-Item (Join-Path $nssmExtract "nssm-2.24\$arch\nssm.exe") $nssmExe -Force
    Remove-Item $nssmZip, $nssmExtract -Recurse -Force -ErrorAction SilentlyContinue
    Log "NSSM ready." "OK"
}

function Install-NssmService {
    param(
        [string]$ServiceName,
        [string]$DisplayName,
        [string]$BinPath,
        [string]$AppArgs,
        [string]$WorkingDir,
        [string]$ExtraEnv = ""
    )
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) {
        & $nssmExe install $ServiceName $BinPath | Out-Null
    } else {
        # Re-running against a service that's already there must still be
        # able to fix it if the launch command was ever wrong -- "already
        # exists" is not the same as "already configured correctly". Stop it
        # first: NSSM doesn't hot-reload AppParameters/Application on a
        # running service, so a config change needs a restart to take effect.
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & $nssmExe set $ServiceName Application $BinPath | Out-Null
    }

    & $nssmExe set $ServiceName AppParameters $AppArgs | Out-Null
    & $nssmExe set $ServiceName AppDirectory $WorkingDir | Out-Null
    & $nssmExe set $ServiceName DisplayName "$stackName - $DisplayName" | Out-Null
    & $nssmExe set $ServiceName Description "$stackName component: $DisplayName" | Out-Null
    & $nssmExe set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $nssmExe set $ServiceName AppStdout (Join-Path $paths.Logs "$ServiceName.out.log") | Out-Null
    & $nssmExe set $ServiceName AppStderr (Join-Path $paths.Logs "$ServiceName.err.log") | Out-Null
    & $nssmExe set $ServiceName AppRestartDelay 5000 | Out-Null
    & $nssmExe set $ServiceName AppExit Default Restart | Out-Null
    if ($ExtraEnv) { & $nssmExe set $ServiceName AppEnvironmentExtra $ExtraEnv | Out-Null }

    # Belt-and-suspenders on top of NSSM's own restart-on-exit: make Windows'
    # own service recovery restart it too, and make sure it's actually set to
    # start automatically at boot (not just "on demand").
    sc.exe config $ServiceName start= auto | Out-Null
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    sc.exe failureflag $ServiceName 1 | Out-Null

    Log "Service configured: $ServiceName -> $BinPath $AppArgs"

    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -ne "Running") {
        Start-Sleep -Seconds 2
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }
}

function Get-ArrApiKey {
    param([string]$ConfigXmlPath, [int]$TimeoutSec = 60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $ConfigXmlPath) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path $ConfigXmlPath)) { throw "config.xml never appeared at $ConfigXmlPath" }
    Start-Sleep -Seconds 1
    [xml]$cfg = Get-Content $ConfigXmlPath -Raw
    return $cfg.Config.ApiKey
}

function Get-ErrorResponseBody {
    # Invoke-RestMethod's own exception message is just "400 (Bad Request)" --
    # the actual FluentValidation error text (which field, why) is in the
    # response body, which needs pulling out differently depending on
    # whether this is running under Windows PowerShell 5.1 or pwsh 7+.
    param($ErrorRecord)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return $ErrorRecord.ErrorDetails.Message
        }
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $stream = $resp.GetResponseStream()
            $reader = New-Object IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            return $body
        }
    } catch {}
    return $null
}

function Set-ArrAuthentication {
    param([string]$BaseUrl, [string]$ApiKey, [string]$Username, [string]$Password)
    try {
        $headers = @{ "X-Api-Key" = $ApiKey }
        $hostConfig = Invoke-RestMethod -Uri "$BaseUrl/config/host" -Headers $headers
        $hostConfig.authenticationMethod = "Forms"
        $hostConfig.authenticationRequired = "Enabled"
        $hostConfig.username = $Username
        $hostConfig.password = $Password
        # passwordConfirmation isn't a real persisted field -- GET /config/host never
        # returns it, so it doesn't exist on this object yet. Direct assignment to a
        # property PSCustomObject doesn't already have throws; Add-Member -Force adds it.
        $hostConfig | Add-Member -NotePropertyName "passwordConfirmation" -NotePropertyValue $Password -Force
        Invoke-RestMethod -Uri "$BaseUrl/config/host" -Method Put -Headers $headers -ContentType "application/json" -Body ($hostConfig | ConvertTo-Json -Depth 8) | Out-Null
        Log "Login set on $BaseUrl (user: $Username)"
    } catch {
        $body = Get-ErrorResponseBody $_
        $detail = if ($body) { " -- $body" } else { "" }
        Log "Could not set login on $BaseUrl : $($_.Exception.Message)$detail" "WARN"
    }
}

function Invoke-ArrApi {
    param([string]$BaseUrl, [string]$ApiKey, [string]$Path, [string]$Method = "Get", $Body = $null)
    $uri = "$BaseUrl/$Path"
    $headers = @{ "X-Api-Key" = $ApiKey }
    try {
        if ($Body) {
            return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 8)
        } else {
            return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers
        }
    } catch {
        $body = Get-ErrorResponseBody $_
        $detail = if ($body) { " -- $body" } else { "" }
        Log "API call failed [$Method $uri]: $($_.Exception.Message)$detail" "WARN"
        return $null
    }
}

# ============================================================
# App catalog
# ============================================================
# ZipPattern / ApiVersion verified against each project's current GitHub
# release assets. Readarr's upstream repo is archived (no stable release),
# so it resolves the newest "develop" pre-release instead.

# CategoryField: each app's SabnzbdSettings/QBittorrentSettings C# class calls
# its category property something different -- an old naming quirk from each
# app being forked off Sonarr's or Lidarr's original codebase and never
# renamed (Sonarr & Whisparr: TvCategory; Radarr: MovieCategory; Lidarr &
# Readarr: MusicCategory), confirmed by reading each app's actual source.
# Sending the generic "category" field name they don't recognize made every
# one of them silently fall back to its own hardcoded default -- which
# happened to accidentally match for Sonarr/Radarr/Lidarr, but left Whisparr
# quietly pointed at the wrong ("tv") category and made Readarr fail outright.
$servarrApps = @(
    [pscustomobject]@{ Name="Prowlarr"; Port=9696; Repo="Prowlarr/Prowlarr"; ZipPattern="windows-core-x64\.zip$"; ApiVersion="v1"; Category=$null;    MediaFolder=$null;  CategoryField=$null }
    [pscustomobject]@{ Name="Sonarr";   Port=8989; Repo="Sonarr/Sonarr";     ZipPattern="win-x64\.zip$";          ApiVersion="v3"; Category="tv";      MediaFolder="tv";     CategoryField="tvCategory" }
    [pscustomobject]@{ Name="Radarr";   Port=7878; Repo="Radarr/Radarr";     ZipPattern="windows-core-x64\.zip$"; ApiVersion="v3"; Category="movies";  MediaFolder="movies"; CategoryField="movieCategory" }
    [pscustomobject]@{ Name="Lidarr";   Port=8686; Repo="Lidarr/Lidarr";     ZipPattern="windows-core-x64\.zip$"; ApiVersion="v1"; Category="music";   MediaFolder="music";  CategoryField="musicCategory" }
    [pscustomobject]@{ Name="Readarr";  Port=8787; Repo="Readarr/Readarr";   ZipPattern="windows-core-x64\.zip$"; ApiVersion="v1"; Category="books";   MediaFolder="books";  CategoryField="musicCategory" }
    [pscustomobject]@{ Name="Whisparr"; Port=6969; Repo="Whisparr/Whisparr"; ZipPattern="win-x64\.zip$";          ApiVersion="v3"; Category="adult";   MediaFolder="adult";  CategoryField="tvCategory" }
)

$appsToInstall = $servarrApps | Where-Object { $SkipApps -notcontains $_.Name }

# ============================================================
# Install Servarr apps (Prowlarr + all *arr) as NSSM services
# ============================================================

foreach ($app in $appsToInstall) {
    Log "---- $($app.Name) ----"
    $appFolder = Join-Path $paths.Apps $app.Name
    $appData   = Join-Path $paths.AppData $app.Name
    New-Item -ItemType Directory -Force -Path $appData | Out-Null
    $exePath = Get-ChildItem -Path $appFolder -Filter "$($app.Name).exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $exePath) {
        try {
            $asset = Resolve-GitHubAsset -Repo $app.Repo -Pattern $app.ZipPattern
            Log "Resolved $($app.Name) $($asset.Version) -> $($asset.Name)"
            $zipPath = Join-Path $paths.Apps "$($app.Name).zip"
            Invoke-DownloadFile -Url $asset.Url -OutFile $zipPath
            Microsoft.PowerShell.Archive\Expand-Archive -Path $zipPath -DestinationPath $appFolder -Force
            Remove-Item $zipPath -Force
            $exePath = Get-ChildItem -Path $appFolder -Filter "$($app.Name).exe" -Recurse | Select-Object -First 1
            $state["$($app.Name)_Version"] = $asset.Version
        } catch {
            Log "Failed to install $($app.Name): $($_.Exception.Message)" "ERROR"
            continue
        }
    } else {
        Log "$($app.Name) already downloaded, skipping fetch."
    }

    if (-not $exePath) { Log "$($app.Name).exe not found after extraction, skipping." "ERROR"; continue }

    $svcName = "REGTMS-$($app.Name)"
    $svcArgs = "-nobrowser -data=`"$appData`""
    Install-NssmService -ServiceName $svcName -DisplayName $app.Name -BinPath $exePath.FullName -AppArgs $svcArgs -WorkingDir $exePath.DirectoryName

    $baseUrl = "http://localhost:$($app.Port)/api/$($app.ApiVersion)"
    if (Wait-ForHttpOk -Url "http://localhost:$($app.Port)" -TimeoutSec 90) {
        try {
            $apiKey = Get-ArrApiKey -ConfigXmlPath (Join-Path $appData "config.xml")
            $state["$($app.Name)_ApiKey"]  = $apiKey
            $state["$($app.Name)_BaseUrl"] = $baseUrl
            Save-State
            Log "$($app.Name) is up on port $($app.Port), API key captured." "OK"
            Set-ArrAuthentication -BaseUrl $baseUrl -ApiKey $apiKey -Username $AdminUsername -Password $AdminPassword
        } catch {
            Log "$($app.Name) started but API key could not be read yet: $($_.Exception.Message)" "WARN"
        }
    } else {
        Log "$($app.Name) did not respond on port $($app.Port) within timeout." "WARN"
    }
}
Save-State

# ============================================================
# SABnzbd (download client)
# ============================================================

if ($SkipApps -notcontains "SABnzbd") {
    Log "---- SABnzbd ----"
    # SABnzbd's own NSIS installer hardcodes its install directory to
    # Program Files on 64-bit Windows in its .onInit function -- it does
    # `StrCpy $INSTDIR "$PROGRAMFILES64\SABnzbd"` unconditionally, which
    # clobbers /D= after the fact. Confirmed by testing directly: /D= is
    # silently ignored on every run, every time, on any 64-bit machine.
    # Unlike Jellyfin, there's no working command-line override for this --
    # so we point at where it actually lands instead of fighting it.
    $sabFolder = Join-Path $env:ProgramFiles "SABnzbd"
    $sabData   = Join-Path $paths.AppData "SABnzbd"
    New-Item -ItemType Directory -Force -Path $sabData | Out-Null
    $sabExe = Get-ChildItem -Path $sabFolder -Filter "SABnzbd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $sabExe) {
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/sabnzbd/sabnzbd/releases/latest" -Headers $ghHeaders
            $asset = $release.assets | Where-Object { $_.name -match "win-setup\.exe$" } | Select-Object -First 1
            $installerPath = Join-Path $paths.Apps "SABnzbd-setup.exe"
            Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $installerPath
            Log "Installing SABnzbd $($release.tag_name) silently (lands in $sabFolder -- its installer forces this on 64-bit Windows)..."
            Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
            Remove-Item $installerPath -Force
            $state["SABnzbd_Version"] = $release.tag_name
            $sabExe = Get-ChildItem -Path $sabFolder -Filter "SABnzbd.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        } catch {
            Log "Failed to install SABnzbd: $($_.Exception.Message)" "ERROR"
        }
    }

    if ($sabExe) {
        $sabIni = Join-Path $sabData "sabnzbd.ini"

        # Pre-seed the ini ourselves before SABnzbd ever launches. Letting it
        # generate its own config on first boot is what caused the setup
        # wizard to greet Ron in the browser, and made the installer scrape
        # api_key back out of a file that might still be mid-write (the
        # "started but api_key not found" race). Writing it ourselves with a
        # key we already know sidesteps both problems.
        if (-not (Test-Path $sabIni)) {
            $sabApiKey = [guid]::NewGuid().ToString("N")
            $sabNzbKey = [guid]::NewGuid().ToString("N")
            # inet_exposure gates get_config/set_config (used by the *arr apps'
            # own "test connection" check) at access level 3; it defaults to 0.
            # There's a loopback-IP fallback in SABnzbd's own code, but rather
            # than depend on that detecting 127.0.0.1 correctly in every case,
            # just grant level 3 directly -- this stack's actual security
            # boundary is Windows Firewall/Tailscale scoping, not SABnzbd's own
            # IP heuristics, so this doesn't change the real exposure.
            # host_whitelist requires lowercase entries (SABnzbd validates this).
            $seedIni = @"
[misc]
language = en
api_key = $sabApiKey
nzb_key = $sabNzbKey
username = $AdminUsername
password = $AdminPassword
host_whitelist = localhost,127.0.0.1,$($env:COMPUTERNAME.ToLower())
inet_exposure = 3
"@
            $seedIni | Set-Content -Path $sabIni -Encoding UTF8
            Log "Pre-seeded sabnzbd.ini (no setup wizard, known API key)."
        }

        # SABnzbd auto-detects Session 0 (exactly where NSSM runs child
        # processes) as "I must be a real Windows Service" and tries to
        # complete a real SCM handshake -- confirmed from its own source --
        # which fails ("service process could not connect to the service
        # controller") because NSSM, not SABnzbd, is the process actually
        # registered with the SCM. Its own native service installer turned
        # out to be broken too: it needs pythonservice.exe, which the
        # official frozen/PyInstaller build doesn't ship at all (confirmed
        # by running the install command directly). Since Session 0 is the
        # actual root cause of both, the real fix is the same one that
        # worked for qBittorrent: run it as a logon Scheduled Task, in a
        # real interactive session, not a SYSTEM service at all. Confirmed
        # SABnzbd runs completely normally outside Session 0 -- no service
        # logic triggers there. Deliberately using SABnzbd.exe, not
        # SABnzbd-console.exe -- confirmed via SABnzbd's own PyInstaller
        # spec (builder/SABnzbd.spec: console=False vs the -console
        # variant's console=True) that the plain .exe is the real windowless
        # build, not a debug-only option -- the console variant exists
        # specifically for troubleshooting and pops a visible log window
        # every logon, which there's no reason to inflict once things work.
        $sabTaskName = "REGTeches Media Stack - SABnzbd"
        # Kill both names -- installs from before this fix have "SABnzbd-console"
        # running and need it stopped too, on top of "SABnzbd" from any run since.
        Get-Process -Name "SABnzbd", "SABnzbd-console" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $sabTaskName -Confirm:$false -ErrorAction SilentlyContinue

        $sabAction = New-ScheduledTaskAction -Execute $sabExe.FullName -Argument "-s 0.0.0.0:8080 -b 0 -f `"$sabIni`"" -WorkingDirectory $sabExe.DirectoryName
        $sabTrigger = New-ScheduledTaskTrigger -AtLogOn
        $sabPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $sabSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden `
            -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $sabTaskName -Action $sabAction -Trigger $sabTrigger -Principal $sabPrincipal -Settings $sabSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $sabTaskName
        Log "SABnzbd registered as a logon task (real desktop session, not a SYSTEM service) and started."

        if (Wait-ForHttpOk -Url "http://localhost:8080" -TimeoutSec 90) {
            Start-Sleep -Seconds 2
            $line = Get-Content $sabIni | Where-Object { $_ -match "^\s*api_key\s*=\s*(.+)$" } | Select-Object -First 1
            if ($line -match "^\s*api_key\s*=\s*(.+)$") { $sabApiKey = $Matches[1].Trim() }

            if ($sabApiKey) {
                $state["SABnzbd_ApiKey"] = $sabApiKey
                $state["SABnzbd_BaseUrl"] = "http://localhost:8080"
                Save-State
                Log "SABnzbd is up (user: $AdminUsername)." "OK"

                $sabConfigFailures = 0
                function Set-SabConfig {
                    param([hashtable]$Query)
                    $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join "&"
                    try { Invoke-RestMethod -Uri "http://localhost:8080/api?$qs&apikey=$sabApiKey&output=json" -TimeoutSec 10 | Out-Null }
                    catch { Log "SABnzbd config call failed: $($_.Exception.Message)" "WARN"; $script:sabConfigFailures++ }
                }

                Set-SabConfig @{ mode="set_config"; section="misc"; keyword="complete_dir"; value=(Join-Path $paths.Downloads "complete") }
                Set-SabConfig @{ mode="set_config"; section="misc"; keyword="download_dir"; value=(Join-Path $paths.Downloads "incomplete") }

                foreach ($app in $appsToInstall | Where-Object { $_.Category }) {
                    Set-SabConfig @{ mode="set_config"; section="categories"; keyword=$app.Category; name=$app.Category; dir=$app.Category; priority=0; pp=3; script="None" }
                }
                if ($sabConfigFailures -eq 0) {
                    Log "SABnzbd categories and download folders configured." "OK"
                } else {
                    Log "$sabConfigFailures of SABnzbd's config calls failed -- categories/folders may be incomplete, check http://localhost:8080/config by hand." "WARN"
                }

                if ($UsenetHost) {
                    Set-SabConfig @{
                        mode="set_config"; section="servers"; keyword="primary"; name="primary"
                        host=$UsenetHost; port=$UsenetPort; username=$UsenetUsername; password=$UsenetPassword
                        connections=$UsenetConnections; ssl=[int](-not $UsenetNoSSL); enable=1
                    }
                    Log "Usenet server '$UsenetHost' wired into SABnzbd ($UsenetConnections connections, SSL=$(-not $UsenetNoSSL))." "OK"
                } else {
                    Log "No -UsenetHost given -- SABnzbd has no news server yet. Add one from its own Config -> Servers page, or re-run with -UsenetHost/-UsenetUsername/-UsenetPassword once you've got a provider (even a free trial is enough to confirm the whole chain works end to end)."
                }
            } else {
                Log "SABnzbd started but its ini couldn't be read back -- check $sabIni by hand." "WARN"
            }
        } else {
            Log "SABnzbd did not respond on port 8080 within timeout -- if this installer ran with no one interactively logged on to Windows, the logon task can't start yet and will launch next time someone logs in." "WARN"
        }
    } else {
        $found = Get-ChildItem -Path $sabFolder -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        Log "SABnzbd.exe not found under $sabFolder after install -- nothing was configured this run. .exe files actually there: $(if ($found) { $found -join ', ' } else { '(none)' })" "ERROR"
    }
}
Save-State

# ============================================================
# qBittorrent (torrent client) -- optional; needed if you add torrent indexers
# Prowlarr just added have somewhere to actually send downloads; SABnzbd
# only handles the Usenet side.
# ============================================================

if (-not $SkipQBittorrent) {
    Log "---- qBittorrent ----"
    $qbtFolder  = Join-Path $paths.Apps "qBittorrent"
    $qbtProfile = Join-Path $paths.AppData "qBittorrent"
    # qBittorrent's --profile=<dir> does NOT put config directly under <dir> --
    # its source (base/profile_p.cpp, CustomProfile) builds the base path as
    # <dir>\<applicationName>\config, and the Qt application name is
    # "qBittorrent". Missing that extra nested folder is why it silently fell
    # back to a fresh default profile (WebUI off, username "admin") instead
    # of ever reading the ini we wrote -- confirmed by seeing that exact
    # default state in its actual Options window.
    $qbtConfigDir = Join-Path $qbtProfile "qBittorrent\config"
    New-Item -ItemType Directory -Force -Path $qbtFolder, $qbtConfigDir | Out-Null
    $qbtExe = Get-ChildItem -Path $qbtFolder -Filter "qbittorrent.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $qbtExe) {
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest" -Headers $ghHeaders
            $asset = $release.assets | Where-Object { $_.name -match "_lt20_x64_setup\.exe$" } | Select-Object -First 1
            $installerPath = Join-Path $paths.Apps "qbittorrent-setup.exe"
            Invoke-DownloadFile -Url $asset.browser_download_url -OutFile $installerPath
            Log "Installing qBittorrent $($release.tag_name) silently..."
            Start-Process -FilePath $installerPath -ArgumentList "/S", "/D=$qbtFolder" -Wait
            Remove-Item $installerPath -Force
            $state["QBittorrent_Version"] = $release.tag_name
            Save-State
            $qbtExe = Get-ChildItem -Path $qbtFolder -Filter "qbittorrent.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        } catch {
            Log "Failed to install qBittorrent: $($_.Exception.Message)" "ERROR"
        }
    }

    if ($qbtExe) {
        $qbtIni = Join-Path $qbtConfigDir "qBittorrent.ini"
        if (-not (Test-Path $qbtIni)) {
            # Pre-seed WebUI credentials ourselves (same story as SABnzbd): qBittorrent's
            # default behavior is a random temporary password shown only in its log on
            # first launch, which is fragile to scrape. It stores the WebUI password as
            # a PBKDF2-SHA512 hash (100k iterations, 16-byte salt, 64-byte key), which
            # .NET can compute directly, so we can set the real login up front instead.
            $salt = New-Object byte[] 16
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
            $pbkdf2 = New-Object Security.Cryptography.Rfc2898DeriveBytes($AdminPassword, $salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA512)
            $hashB64 = [Convert]::ToBase64String($pbkdf2.GetBytes(64))
            $saltB64 = [Convert]::ToBase64String($salt)

            # LegalNotice\Accepted is checked first, before anything else, in
            # qBittorrent's own startup code (src/app/main.cpp) to decide if
            # this is a "first run". Leaving it out is what caused the actual
            # problem: it showed its EULA dialog, someone clicked through it
            # (there's no one else who could have), and going through that
            # first-run path is what reset our WebUI settings back to
            # defaults -- confirmed by finding "LegalNotice/Accepted=true"
            # already present, but every WebUI\* key gone, in the real ini
            # after a run. Pre-seeding this key skips that path entirely.
            #
            # WebUI\CSRFProtection=false: confirmed by reading qBittorrent
            # 5.2.3's actual shipped source (src/webui/webapplication.cpp) --
            # its CSRF check runs on every request, including the root page
            # load, with no exemption for cross-origin hyperlinks (that
            # exemption exists on qBittorrent's unreleased master branch, not
            # in any released version yet). That means clicking the
            # dashboard's qBittorrent tile -- a different origin, port 8090
            # vs 8181 -- gets rejected as "Unauthorized" purely because of
            # the Referer header, confirmed directly from qBittorrent's own
            # log ("Referer header & Target origin mismatch"). Typing the
            # same URL fresh works, because a typed/bookmarked navigation
            # sends no Referer at all. There's no browser-side fix for this
            # (Sec-Fetch-Site: same-site, from our own same-host dashboard,
            # is rejected the same way once Referer/Origin are stripped) --
            # it has to be disabled in qBittorrent's own config. Reasonable
            # trade-off for a private single-admin home LAN box like this one.
            $qbtIniContent = @"
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Enabled=true
WebUI\Address=*
WebUI\Port=8181
WebUI\Username=$AdminUsername
WebUI\Password_PBKDF2="@ByteArray(${saltB64}:${hashB64})"
WebUI\CSRFProtection=false
# Confirmed by reading Readarr's actual qBittorrent client source
# (QBittorrentProxyV2.cs): it maps an HTTP 403 from qBittorrent straight to
# "Failed to authenticate with qBittorrent" / "Authentication failure" -- the
# exact error seen live, deterministically, every single run, always for
# Readarr and Whisparr specifically (always the 4th and 5th app to test the
# qBittorrent connection). qBittorrent's own source has exactly one 403 code
# path: its brute-force protection (WebUI/MaxAuthenticationFailCount, default
# 5) bans an IP for an hour (WebUI/BanDuration, default 3600s) after that many
# failed attempts -- and every app here runs on localhost, so all 5 *arr
# apps' connection tests share one IP bucket. Disabling it (0 = the count
# check is skipped entirely, per qBittorrent's own source) is the same
# trade-off already made for CSRF protection: meaningless security value on
# a private single-admin home LAN box, real functional cost left enabled.
WebUI\MaxAuthenticationFailCount=0

[BitTorrent]
Session\DefaultSavePath=$(Join-Path $paths.Downloads "complete")\
Session\TempPath=$(Join-Path $paths.Downloads "incomplete")\
"@
            $qbtIniContent | Set-Content -Path $qbtIni -Encoding UTF8
            Log "Pre-seeded qBittorrent.ini (known WebUI login, no temp-password scraping)."
        } else {
            # Installs from before these fixes won't have one or both keys --
            # patch whichever are missing into the existing ini rather than
            # requiring a full reset. Both have to land inside the
            # [Preferences] section specifically (a bare file-end append
            # would fall under whatever section happens to be last in the
            # file instead). qBittorrent only reads this at startup, so the
            # process gets killed below and relaunched by the (re-registered)
            # Scheduled Task to pick up whatever changed.
            $qbtDesiredKeys = [ordered]@{
                "WebUI\CSRFProtection"           = @{ Value = "false"; Reason = "disable WebUI CSRF protection (fixes cross-origin dashboard links)" }
                "WebUI\MaxAuthenticationFailCount" = @{ Value = "0";     Reason = "disable qBittorrent's brute-force IP ban (was breaking Readarr/Whisparr's download-client test login)" }
            }
            $qbtIniLines = @(Get-Content -Path $qbtIni)
            foreach ($keyName in $qbtDesiredKeys.Keys) {
                $escapedKey = [regex]::Escape($keyName)
                if ($qbtIniLines | Select-String -Pattern "^$escapedKey=" -Quiet) { continue }
                $prefsMatch = $qbtIniLines | Select-String -Pattern '^\[Preferences\]$' | Select-Object -First 1
                if (-not $prefsMatch) { continue }
                $prefsLineIndex = $prefsMatch.LineNumber - 1
                $before = @($qbtIniLines[0..$prefsLineIndex])
                $after = if ($prefsLineIndex + 1 -le $qbtIniLines.Count - 1) { @($qbtIniLines[($prefsLineIndex + 1)..($qbtIniLines.Count - 1)]) } else { @() }
                $qbtIniLines = $before + "$keyName=$($qbtDesiredKeys[$keyName].Value)" + $after
                Log "Patched existing qBittorrent.ini to $($qbtDesiredKeys[$keyName].Reason)."
            }
            $qbtIniLines | Set-Content -Path $qbtIni -Encoding UTF8
        }

        # qBittorrent's Windows build is a Qt GUI app. Confirmed via Windows'
        # own Application Error log (0xc0000005 / 0xc0000409 faulting inside
        # qbittorrent.exe itself, no missing-DLL signature) that it crashes
        # under NSSM in Session 0, which has no real desktop -- and that
        # QT_QPA_PLATFORM=offscreen alone isn't enough to cover every Win32
        # GUI code path it touches (tray icon, single-instance detection,
        # etc). The standard, well-precedented way to run qBittorrent
        # unattended on Windows is a Scheduled Task triggered at logon, in a
        # real interactive session -- not a SYSTEM service. Trade-off: it
        # starts when you log in, not at boot, unlike everything else here.
        $qbtTaskName = "REGTeches Media Stack - qBittorrent"
        # Kill any already-running instance first -- unregistering/re-registering
        # the task doesn't touch a process it already launched, so a prior run
        # (possibly using a wrong profile path, as one did) would otherwise
        # keep running untouched right through this "fix".
        Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $qbtTaskName -Confirm:$false -ErrorAction SilentlyContinue

        # --confirm-legal-notice and --webui-port are CLI-level backups that
        # don't depend on the ini being read correctly at all -- belt and
        # suspenders alongside the LegalNotice/WebUI ini keys above.
        $qbtAction = New-ScheduledTaskAction -Execute $qbtExe.FullName `
            -Argument "--profile=`"$qbtProfile`" --confirm-legal-notice --webui-port=8181" -WorkingDirectory $qbtExe.DirectoryName
        $qbtTrigger = New-ScheduledTaskTrigger -AtLogOn
        $qbtPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $qbtSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden `
            -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $qbtTaskName -Action $qbtAction -Trigger $qbtTrigger -Principal $qbtPrincipal -Settings $qbtSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $qbtTaskName
        Log "qBittorrent registered as a logon task (real desktop session, not a SYSTEM service) and started."

        if (Wait-ForHttpOk -Url "http://localhost:8181" -TimeoutSec 90) {
            Start-Sleep -Seconds 2
            try {
                # A failed login throws (401), caught below -- reaching this
                # line at all already means it succeeded. Depending on
                # version, qBittorrent's login endpoint returns either 200
                # with body "Ok." or 204 with an empty body on success, so
                # checking Content text (as this used to) is unreliable;
                # not throwing is the actual signal.
                # -UseBasicParsing: confirmed live that running as a compiled
                # (ps2exe) .exe hits PowerShell 5.1's interactive "Script
                # Execution Risk" confirmation prompt without it -- the same
                # underlying IE-engine dependency already found and fixed for
                # the dashboard's own qBittorrent calls, just surfacing here
                # under a different execution context (raw .ps1 in an
                # interactive session apparently doesn't trigger the prompt;
                # the compiled exe does). Blocks forever waiting on Y/N input
                # nothing is there to answer, so this isn't optional here.
                $loginResp = Invoke-WebRequest -Uri "http://localhost:8181/api/v2/auth/login" -Method Post -UseBasicParsing `
                    -Body @{ username = $AdminUsername; password = $AdminPassword } -SessionVariable qbtSession -TimeoutSec 15
                foreach ($app in $appsToInstall | Where-Object { $_.Category }) {
                    $catPath = Join-Path $paths.Downloads "complete\$($app.Category)"
                    try {
                        Invoke-WebRequest -Uri "http://localhost:8181/api/v2/torrents/createCategory" -Method Post -UseBasicParsing `
                            -Body @{ category = $app.Category; savePath = $catPath } -WebSession $qbtSession -TimeoutSec 10 | Out-Null
                    } catch {
                        # 409 = category already exists (confirmed from
                        # qBittorrent's own SessionImpl::addCategory: it
                        # returns false -- which the controller maps to
                        # Conflict -- whenever m_categories already contains
                        # the name), i.e. a previous run already created it.
                        # -ErrorAction SilentlyContinue does NOT suppress
                        # this: Invoke-WebRequest throws a genuine
                        # terminating exception for an HTTP error status in
                        # Windows PowerShell 5.1, so it has to be caught
                        # explicitly instead. Anything that isn't 409 is a
                        # real problem -- let it propagate to the outer catch.
                        $statusCode = $_.Exception.Response.StatusCode
                        if ([int]$statusCode -ne 409) { throw }
                    }
                }
                $state["QBittorrent_Ready"] = $true
                $state["QBittorrent_Port"] = 8181
                Save-State
                Log "qBittorrent is up (user: $AdminUsername), categories created." "OK"
            } catch {
                Log "Could not finish configuring qBittorrent: $($_.Exception.Message)" "WARN"
            }
        } else {
            Log "qBittorrent did not respond on port 8181 within timeout -- if this installer ran with no one interactively logged on to Windows (e.g. over an unattended RDP session that disconnected), the logon task can't start yet. It will launch automatically the next time someone logs in." "WARN"
        }
    }
}
Save-State

# ============================================================
# Wire root folders, naming, and SABnzbd/qBittorrent into each *arr app
# ============================================================

function Get-FirstRecordId {
    # @($null) is a 1-element array in PowerShell (containing $null), and
    # $null.id silently evaluates to $null rather than erroring -- both
    # would previously slip a JSON `null` into a field .NET expects as a
    # non-nullable int. Guard against every step of that explicitly and
    # always hand back a real integer.
    param([string]$BaseUrl, [string]$ApiKey, [string]$Path)
    try {
        $list = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $ApiKey -Path $Path
        if ($list) {
            $first = @($list) | Select-Object -First 1
            if ($first -and $null -ne $first.id) { return [int]$first.id }
        }
    } catch {}
    return 1
}

foreach ($app in $appsToInstall | Where-Object { $_.MediaFolder }) {
    $apiKey = $state["$($app.Name)_ApiKey"]
    $baseUrl = $state["$($app.Name)_BaseUrl"]
    if (-not $apiKey) { Log "Skipping config for $($app.Name) (no API key captured)." "WARN"; continue }

    $rootPath = Join-Path $paths.Media $app.MediaFolder
    $existingRoots = Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "rootfolder"
    if (-not ($existingRoots | Where-Object { $_.path -eq $rootPath })) {
        $rootBody = @{ path = $rootPath }
        if (@("Lidarr", "Readarr") -contains $app.Name) {
            # Unlike Sonarr/Radarr, Lidarr/Readarr's RootFolder validator also
            # requires a name plus non-zero default quality/metadata profile IDs.
            $rootBody["name"] = $app.MediaFolder
            $rootBody["defaultQualityProfileId"] = Get-FirstRecordId -BaseUrl $baseUrl -ApiKey $apiKey -Path "qualityprofile"
            $rootBody["defaultMetadataProfileId"] = Get-FirstRecordId -BaseUrl $baseUrl -ApiKey $apiKey -Path "metadataprofile"
        }
        Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "rootfolder" -Method Post -Body $rootBody | Out-Null
        Log "$($app.Name): root folder set to $rootPath"
    }

    $dlClients = Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient"
    $existingSab = $dlClients | Where-Object { $_.name -eq "SABnzbd" }
    if ($existingSab) {
        # Re-running must be able to fix a download client that's already
        # there but wired up wrong (e.g. Whisparr's category field name bug,
        # below) -- "already exists" isn't "already configured correctly".
        Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient/$($existingSab.id)" -Method Delete | Out-Null
    }
    if ($state["SABnzbd_ApiKey"]) {
        $dlBody = @{
            enable = $true
            protocol = "usenet"
            implementation = "Sabnzbd"
            configContract = "SabnzbdSettings"
            name = "SABnzbd"
            # Radarr/Lidarr/Readarr reject a missing/zero Priority (must be
            # 1-50); Sonarr/Whisparr don't seem to require it, but setting it
            # everywhere is simpler than tracking which apps care. Lower
            # number = more preferred -- this is also how Sonarr/Radarr break
            # ties between an equally-good Usenet release and torrent release
            # for the same content, so SABnzbd at 1 / qBittorrent at 2 below
            # is what makes Usenet the real first choice with torrent as a
            # genuine fallback, not just "both enabled, whichever."
            priority = 1
            fields = @(
                @{ name = "host"; value = "localhost" }
                @{ name = "port"; value = 8080 }
                @{ name = "apiKey"; value = $state["SABnzbd_ApiKey"] }
                @{ name = $app.CategoryField; value = $app.Category }
            )
        }
        # forceSave=true: confirmed by reading the shared ProviderControllerBase
        # source (identical across Sonarr/Radarr/Lidarr/Readarr/Whisparr) that
        # every download-client POST runs a live connection test unless this
        # is set -- Readarr's and Whisparr's own test implementation was
        # deterministically failing (every single run, always those two)
        # with a generic "Authentication failure" even with byte-identical
        # credentials to Sonarr/Radarr/Lidarr's passing runs. Rather than
        # chase whatever's specific to their test path, skip it -- we
        # already independently confirm SABnzbd/qBittorrent are up and
        # logged-in earlier in this script, so this redundant test buys
        # nothing and was the actual cause of the wiring failures.
        $result = Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient?forceSave=true" -Method Post -Body $dlBody
        if ($result) { Log "$($app.Name): SABnzbd wired up as download client (category '$($app.Category)')." }
    }

    $existingQbt = $dlClients | Where-Object { $_.name -eq "qBittorrent" }
    if ($existingQbt) {
        Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient/$($existingQbt.id)" -Method Delete | Out-Null
    }
    if ($state["QBittorrent_Ready"]) {
        # Confirmed live from Readarr's own debug log + its actual source
        # (QBittorrentProxyV2.cs): forceSave=true on the POST doesn't skip the
        # connection test at all for Create -- only for Update. The failure
        # itself is a real bug in Readarr's (and apparently Whisparr's) own
        # qBittorrent client, not anything on our end: it checks
        # `response.Content != "Ok."` on the login response to decide success,
        # but qBittorrent 5.x doesn't reliably send that exact body back
        # anymore (this is the identical fragile check we already found and
        # moved off of in our own qBittorrent login code, earlier in this
        # project) -- so a genuinely successful login gets treated as a
        # failure. Sonarr/Radarr/Lidarr clearly got this fixed upstream;
        # Readarr (still pre-1.0) and Whisparr (still beta) haven't. Can't fix
        # their code from here, but CAN avoid ever triggering it: Create only
        # runs the connection test when enable=true (unconditionally, no
        # forceSave escape), while Update genuinely skips it entirely when
        # forceSave=true. So create disabled first (no test fires at all),
        # then flip it on via Update+forceSave (test skipped for real).
        $qbtBody = @{
            enable = $false
            protocol = "torrent"
            implementation = "QBittorrent"
            configContract = "QBittorrentSettings"
            name = "qBittorrent"
            # Deliberately behind SABnzbd's priority 1 -- see the comment on
            # the SABnzbd client above. This is the actual "use SABnzbd first,
            # fall back to qBittorrent" behavior, not just both being enabled.
            priority = 2
            fields = @(
                @{ name = "host"; value = "localhost" }
                @{ name = "port"; value = 8181 }
                @{ name = "username"; value = $AdminUsername }
                @{ name = "password"; value = $AdminPassword }
                @{ name = $app.CategoryField; value = $app.Category }
            )
        }
        $created = Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient" -Method Post -Body $qbtBody
        if ($created -and $created.id) {
            $created.enable = $true
            $result = Invoke-ArrApi -BaseUrl $baseUrl -ApiKey $apiKey -Path "downloadclient/$($created.id)?forceSave=true" -Method Put -Body $created
            if ($result) { Log "$($app.Name): qBittorrent wired up as download client (category '$($app.Category)')." }
        }
    }
}

# ============================================================
# Prowlarr: register every *arr app so indexers sync automatically
# ============================================================

$prowlarrKey = $state["Prowlarr_ApiKey"]
$prowlarrUrl = $state["Prowlarr_BaseUrl"]
if ($prowlarrKey) {
    $implMap = @{ Sonarr="Sonarr"; Radarr="Radarr"; Lidarr="Lidarr"; Readarr="Readarr"; Whisparr="Whisparr" }
    $existingApps = Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path "applications"
    foreach ($app in $appsToInstall | Where-Object { $implMap.ContainsKey($_.Name) }) {
        $apiKey = $state["$($app.Name)_ApiKey"]
        if (-not $apiKey) { continue }
        if ($existingApps | Where-Object { $_.name -eq $app.Name }) { continue }
        $body = @{
            name = $app.Name
            implementation = $implMap[$app.Name]
            configContract = "$($implMap[$app.Name])Settings"
            syncLevel = "fullSync"
            fields = @(
                @{ name = "prowlarrUrl"; value = "http://localhost:9696" }
                @{ name = "baseUrl"; value = "http://localhost:$($app.Port)" }
                @{ name = "apiKey"; value = $apiKey }
            )
        }
        Invoke-ArrApi -BaseUrl $prowlarrUrl -ApiKey $prowlarrKey -Path "applications" -Method Post -Body $body | Out-Null
        Log "Prowlarr: registered $($app.Name) for indexer sync."
    }
} else {
    Log "Prowlarr API key not available, skipping app registration." "WARN"
}
Save-State

# ============================================================
# Prowlarr ships with NO indexers. Add your own (Usenet providers, private or
# public trackers of your choosing - subject to their terms and your local laws).
# ============================================================
Log "Prowlarr is installed with no indexers. Add your own at http://localhost:9696 -> Indexers; they sync to every app automatically."

# ============================================================
# Recyclarr: TRaSH-Guides quality definitions for Sonarr/Radarr
# ============================================================

if (-not $SkipRecyclarr -and $state["Sonarr_ApiKey"] -and $state["Radarr_ApiKey"]) {
    Log "---- Recyclarr (TRaSH-Guides sync) ----"
    try {
        $recyclarrDir = Join-Path $paths.Tools "recyclarr"
        $recyclarrExe = Join-Path $recyclarrDir "recyclarr.exe"
        if (-not (Test-Path $recyclarrExe)) {
            New-Item -ItemType Directory -Force -Path $recyclarrDir | Out-Null
            $asset = Resolve-GitHubAsset -Repo "recyclarr/recyclarr" -Pattern "recyclarr-win-x64\.zip$"
            $zipPath = Join-Path $paths.Tools "recyclarr.zip"
            Invoke-DownloadFile -Url $asset.Url -OutFile $zipPath
            Microsoft.PowerShell.Archive\Expand-Archive -Path $zipPath -DestinationPath $recyclarrDir -Force
            Remove-Item $zipPath -Force
            $state["Recyclarr_Version"] = $asset.Version
        }

        $recyclarrYml = @"
sonarr:
  main:
    base_url: http://localhost:8989
    api_key: $($state["Sonarr_ApiKey"])
    quality_definition:
      type: series

radarr:
  main:
    base_url: http://localhost:7878
    api_key: $($state["Radarr_ApiKey"])
    quality_definition:
      type: movie
"@
        $ymlPath = Join-Path $recyclarrDir "recyclarr.yml"
        $recyclarrYml | Set-Content -Path $ymlPath -Encoding UTF8

        Push-Location $recyclarrDir
        & $recyclarrExe sync --config $ymlPath 2>&1 | Tee-Object -FilePath (Join-Path $paths.Logs "recyclarr.log") -Append | Out-Null
        Pop-Location
        Log "Recyclarr sync complete. For the full TRaSH-Guides custom-format profiles, expand $ymlPath -- see https://recyclarr.dev" "OK"
    } catch {
        Log "Recyclarr setup failed (non-fatal): $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
# File-size caps: keep Sonarr/Radarr/Whisparr from grabbing 720p/1080p
# releases way bigger than they need to be. Deliberately runs after
# Recyclarr, not before -- Recyclarr's own quality_definition sync
# resets these to TRaSH-Guides' defaults (also considerably more
# generous than what's set here), so this has to be the last word to
# actually stick, on every run.
# ============================================================

if (-not $SkipSizeLimits) {
    $sizeCapTargets = @(
        @{ Name = "Sonarr";   BaseUrl = $state["Sonarr_BaseUrl"];   ApiKey = $state["Sonarr_ApiKey"];   MaxSizePerMin = $MaxTvEpisodeSizeMBPerMin; RuntimeMin = 45;  Label = "TV episode" }
        @{ Name = "Whisparr"; BaseUrl = $state["Whisparr_BaseUrl"]; ApiKey = $state["Whisparr_ApiKey"]; MaxSizePerMin = $MaxTvEpisodeSizeMBPerMin; RuntimeMin = 45;  Label = "episode" }
        @{ Name = "Radarr";   BaseUrl = $state["Radarr_BaseUrl"];   ApiKey = $state["Radarr_ApiKey"];   MaxSizePerMin = $MaxMovieSizeMBPerMin;     RuntimeMin = 120; Label = "movie" }
    )

    foreach ($target in $sizeCapTargets) {
        if (-not $target.ApiKey) { continue }
        Log "---- $($target.Name) file-size cap ----"
        try {
            $definitions = Invoke-ArrApi -BaseUrl $target.BaseUrl -ApiKey $target.ApiKey -Path "qualitydefinition"
            if (-not $definitions) { continue }

            $changed = 0
            foreach ($def in $definitions) {
                # Raw-HD is excluded alongside Remux -- confirmed live (crashed
                # the installer outright, aborting every step after this one)
                # that it's also a special uncapped-by-design tier: Sonarr's own
                # QualityDefinitionService ships it with MaxSize = null, and a
                # null-valued property gets OMITTED from the JSON entirely
                # rather than sent as null, so `.maxSize` doesn't exist as a
                # member on that object at all. Add-Member -Force sidesteps
                # this regardless of which quality it turns out to affect --
                # direct assignment throws on a genuinely missing property,
                # Add-Member creates-or-overwrites either way.
                if ($def.quality.resolution -in @(720, 1080) -and $def.quality.name -notlike "*Remux*" -and $def.quality.name -ne "Raw-HD") {
                    if ($def.maxSize -ne $target.MaxSizePerMin) {
                        $def | Add-Member -Force -NotePropertyName "maxSize" -NotePropertyValue $target.MaxSizePerMin
                        $changed++
                    }
                    # Confirmed live: the update was silently rejected outright
                    # (400 Bad Request) on every single run, because Sonarr/
                    # Radarr/Whisparr all enforce PreferredSize <= MaxSize (and
                    # the reverse), and Recyclarr's own TRaSH-Guides sync sets
                    # PreferredSize=95 -- above our new, lower MaxSize. The code
                    # logged "capped N ... OK" regardless, since it never
                    # checked whether the PUT actually succeeded, so every
                    # prior run silently changed nothing at all. Clamp both
                    # PreferredSize and MinSize to the new MaxSize so the
                    # update can't violate either constraint.
                    if ($def.preferredSize -gt $target.MaxSizePerMin) {
                        $def | Add-Member -Force -NotePropertyName "preferredSize" -NotePropertyValue $target.MaxSizePerMin
                    }
                    if ($def.minSize -gt $target.MaxSizePerMin) {
                        $def | Add-Member -Force -NotePropertyName "minSize" -NotePropertyValue $target.MaxSizePerMin
                    }
                }
            }
            if ($changed -gt 0) {
                $updateResult = Invoke-ArrApi -BaseUrl $target.BaseUrl -ApiKey $target.ApiKey -Path "qualitydefinition/update" -Method Put -Body $definitions
                if ($updateResult) {
                    $approxGB = [math]::Round(($target.MaxSizePerMin * $target.RuntimeMin) / 1024, 1)
                    Log "$($target.Name): capped $changed 720p/1080p quality definitions at $($target.MaxSizePerMin) MB/min (~${approxGB}GB for a typical $($target.RuntimeMin)-min $($target.Label))." "OK"
                } else {
                    Log "$($target.Name): the size-cap update was rejected -- see the API call failed line above for the real reason. Nothing changed this run." "WARN"
                }
            } else {
                Log "$($target.Name): file-size caps already set."
            }
        } catch {
            # This whole section is a nice-to-have on top of a working stack --
            # a bug in it should never be able to take down Jellyfin/Tailscale/
            # the dashboard setup that runs after it, the way it did the one
            # time this threw uncaught (every step after this one silently
            # never ran that pass, under the script's own $ErrorActionPreference
            # = Stop).
            Log "Could not set file-size caps for $($target.Name): $($_.Exception.Message)" "WARN"
        }
    }
}

# ============================================================
# Jellyfin
# ============================================================

if ($SkipApps -notcontains "Jellyfin") {
    Log "---- Jellyfin ----"
    $jfProgramDir = Join-Path $paths.Apps "Jellyfin"
    $jfDataDir    = Join-Path $paths.AppData "Jellyfin"
    $jfExe        = Join-Path $jfProgramDir "jellyfin.exe"
    $jfExeFallback = Join-Path $env:ProgramFiles "Jellyfin\Server\jellyfin.exe"

    if (-not (Test-Path $jfExe) -and -not (Test-Path $jfExeFallback)) {
        try {
            $stableIndex = Invoke-WebRequest -Uri "https://repo.jellyfin.org/files/server/windows/stable/" -UseBasicParsing
            $versions = [regex]::Matches($stableIndex.Content, 'href="v([\d\.]+)/"') | ForEach-Object { $_.Groups[1].Value }
            # Pinned to the 10.x line for now -- it's the one we've tested end to end.
            $tenXVersions = $versions | Where-Object { $_ -match '^10\.' }
            $latest = $tenXVersions | Sort-Object { [version]$_ } -ErrorAction SilentlyContinue | Select-Object -Last 1
            if (-not $latest) { $latest = $versions | Sort-Object { [version]($_ -replace '^(\d+\.\d+)$', '$1.0') } -ErrorAction SilentlyContinue | Select-Object -Last 1 }
            if (-not $latest) { $latest = $versions | Select-Object -Last 1 }
            $exeUrl = "https://repo.jellyfin.org/files/server/windows/stable/v$latest/amd64/jellyfin_${latest}_windows-x64.exe"
            $installerPath = Join-Path $paths.Apps "jellyfin-setup.exe"
            Invoke-DownloadFile -Url $exeUrl -OutFile $installerPath
            New-Item -ItemType Directory -Force -Path $jfProgramDir, $jfDataDir | Out-Null

            # Confirmed by reading the installer's actual source (it's NSIS-based
            # now, not Inno Setup -- jellyfin/jellyfin-server-windows on GitHub):
            # its "Setup Type" page defaults to "Basic Install (Recommended)"
            # (dialogs\setuptype.nsdinc pre-checks that radio button), and that
            # page's own Leave callback -- which still runs under /S, even though
            # the page itself is never shown -- is what sets $_INSTALLSERVICE_ to
            # "No". There is no command-line override for this anywhere in the
            # script (no GetOptions calls at all): Jellyfin's installer will never
            # register a JellyfinServer Windows service silently, full stop. Basic
            # Install is Jellyfin's own recommended, intended mode now -- it just
            # means "run as a plain process in a real desktop session," so we
            # drive that ourselves with a logon Scheduled Task, the same fix
            # already proven for qBittorrent and SABnzbd (both hit the same
            # Session-0 wall). /D= is NSIS's only override, for the install
            # folder only, and must be the last argument with no quotes.
            Log "Installing Jellyfin $latest silently (target: $jfProgramDir) ..."
            $jfSetupProc = Start-Process -FilePath $installerPath -ArgumentList @("/S", "/D=$jfProgramDir") -PassThru

            # Confirmed live (10.11.11): Jellyfin's NSIS installer can still pop
            # a blocking "Could not start the Jellyfin Server service" dialog
            # under /S -- harmless (this stack deliberately never runs Jellyfin
            # as a Windows service, see the logon Scheduled Task registered
            # below), but left alone it sits there forever waiting for a click
            # that will never come on an unattended box. Poll for that exact
            # dialog by title and click "Ignore" via a raw Win32 message so it
            # can't block -- no UI Automation dependency, and it works even
            # though the window never gets focus.
            if (-not ("REGTMS.Win32Dialog" -as [type])) {
                Add-Type -Namespace REGTMS -Name Win32Dialog -UsingNamespace System.Runtime.InteropServices -MemberDefinition @"
                    [DllImport("user32.dll", CharSet=CharSet.Auto)]
                    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
                    [DllImport("user32.dll")]
                    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);
                    [DllImport("user32.dll", CharSet=CharSet.Auto)]
                    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
                    [DllImport("user32.dll")]
                    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
                    public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
"@
            }
            $jfDialogTitle = "Jellyfin Server $latest Setup"
            $jfDialogDeadline = (Get-Date).AddMinutes(5)
            while (-not $jfSetupProc.HasExited -and (Get-Date) -lt $jfDialogDeadline) {
                $hDlg = [REGTMS.Win32Dialog]::FindWindow($null, $jfDialogTitle)
                if ($hDlg -ne [IntPtr]::Zero) {
                    $script:jfIgnoreBtn = [IntPtr]::Zero
                    $callback = [REGTMS.Win32Dialog+EnumChildProc]{
                        param($hWnd, $lParam)
                        $sb = New-Object System.Text.StringBuilder 256
                        [REGTMS.Win32Dialog]::GetWindowText($hWnd, $sb, 256) | Out-Null
                        if ($sb.ToString().Trim('&') -eq "Ignore") { $script:jfIgnoreBtn = $hWnd; return $false }
                        return $true
                    }
                    [REGTMS.Win32Dialog]::EnumChildWindows($hDlg, $callback, [IntPtr]::Zero) | Out-Null
                    if ($script:jfIgnoreBtn -ne [IntPtr]::Zero) {
                        [REGTMS.Win32Dialog]::SendMessage($script:jfIgnoreBtn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                        Log "Dismissed Jellyfin's 'could not start service' dialog (expected -- this stack runs Jellyfin via a Scheduled Task, not a service)." "WARN"
                    }
                }
                Start-Sleep -Milliseconds 1500
            }
            $jfSetupProc.WaitForExit()
            Remove-Item $installerPath -Force
            $state["Jellyfin_Version"] = $latest
            Save-State
        } catch {
            Log "Failed to install Jellyfin: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Log "Jellyfin already installed."
    }

    if (Test-Path $jfExe) {
        Log "Jellyfin installed under $jfProgramDir." "OK"
    } elseif (Test-Path $jfExeFallback) {
        $jfExe = $jfExeFallback
        Log "Jellyfin installed, but jellyfin.exe is at '$jfExe' -- the /D= silent switch may not have been honored (this can happen if the installer self-elevates via UAC), so it landed outside $InstallRoot. It'll still work fine from there." "WARN"
    } else {
        Log "jellyfin.exe not found after install (checked $jfProgramDir and the default Program Files location) -- the install likely failed silently. Check C:\Users\*\AppData\Local\Temp for a Jellyfin installer log, or try installing it by hand to see the real error." "ERROR"
    }

    if (Test-Path $jfExe) {
        $jfTaskName = "REGTeches Media Stack - Jellyfin"
        Get-Process -Name "jellyfin" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $jfTaskName -Confirm:$false -ErrorAction SilentlyContinue

        New-Item -ItemType Directory -Force -Path $jfDataDir | Out-Null
        # jellyfin.exe is a console-subsystem binary (unlike qBittorrent's
        # GUI subsystem, or SABnzbd, which ships a real windowless build) --
        # there's no flag that suppresses its own console window, and the
        # Scheduled Task's own -Hidden setting (below) only hides the task
        # from Task Scheduler's UI, not the window a console app allocates
        # when it runs. Route it through a hidden PowerShell wrapper instead,
        # the standard way to launch a console app with CREATE_NO_WINDOW --
        # -Wait plus re-exiting with jellyfin.exe's own exit code keeps the
        # wrapper alive for as long as jellyfin runs and makes a crash look
        # like a crash to Task Scheduler, so RestartCount/RestartInterval
        # below still actually works instead of firing off an orphaned
        # process Task Scheduler can no longer see.
        $jfAction = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -WindowStyle Hidden -Command `"`$p = Start-Process -FilePath '$jfExe' -ArgumentList @('--datadir','$jfDataDir') -WindowStyle Hidden -PassThru -Wait; exit `$p.ExitCode`"" `
            -WorkingDirectory (Split-Path $jfExe -Parent)
        $jfTrigger = New-ScheduledTaskTrigger -AtLogOn
        $jfPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $jfSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden `
            -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $jfTaskName -Action $jfAction -Trigger $jfTrigger -Principal $jfPrincipal -Settings $jfSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $jfTaskName
        Log "Jellyfin registered as a logon task (real desktop session, not a Windows service) and started."
    }

    # Two independent steps. The wizard step is gated on Jellyfin's own live
    # StartupWizardCompleted flag rather than trusting state.json blindly
    # (see below). The libraries step goes further and runs unconditionally
    # every time, verifying each library's real Locations directly --
    # cheap, idempotent, and the only way to catch a library that exists by
    # name but never actually got a real folder attached to it.
    if (Wait-ForHttpOk -Url "http://localhost:8096" -TimeoutSec 150) {
        $jfBase = "http://localhost:8096"
        Start-Sleep -Seconds 3

        if (-not (Wait-ForJellyfinApiReady -JfBase $jfBase -TimeoutSec 90)) {
            Log "Jellyfin's web server is up, but its API kept reporting 'still loading' past the timeout -- proceeding anyway; the wizard/library/plugin steps below will retry next run if it's genuinely still not ready." "WARN"
        }

        # state.json's Jellyfin_WizardDone can go stale: it's ours, but the
        # admin account it's tracking lives in Jellyfin's own database under
        # appdata\Jellyfin, which can get wiped/reinstalled independently
        # (confirmed directly -- a fresh Jellyfin DB plus a leftover "done"
        # flag made the installer skip account creation entirely and then
        # fail logging in as an account that was never created). Trust
        # Jellyfin's own unauthenticated status endpoint over our flag.
        try {
            $jfPublicInfo = Invoke-RestMethod -Uri "$jfBase/System/Info/Public" -TimeoutSec 5
            if (-not $jfPublicInfo.StartupWizardCompleted -and $state["Jellyfin_WizardDone"]) {
                Log "state.json says Jellyfin's wizard already ran, but Jellyfin itself reports it hasn't (its data folder was likely reset since) -- running it again." "WARN"
                $state["Jellyfin_WizardDone"] = $false
                $state["Jellyfin_LibrariesDone"] = $false
            }
        } catch {}

        if (-not $state["Jellyfin_WizardDone"]) {
            try {
                # POST /Startup/User 404s ("NotFound") if Jellyfin has no user
                # yet at all -- confirmed by reading StartupController.cs for
                # our exact version (10.11.11): the POST handler only updates
                # an existing "first user" (GetFirstUser(), no fallback), it
                # never creates one. Only the GET variant calls
                # _userManager.InitializeAsync() first, which is what actually
                # creates that internal first-user record. On a genuinely
                # fresh install, skipping this GET means the POST 404s as the
                # very first call in this try block, which aborts every step
                # after it too (including Startup/Complete), leaving the
                # wizard stuck incomplete and the admin account never renamed
                # to $AdminUsername -- which is exactly why the library/plugin
                # steps below then fail with 401.
                Invoke-RestMethod -Uri "$jfBase/Startup/User" -Method Get | Out-Null
                Invoke-RestMethod -Uri "$jfBase/Startup/User" -Method Post -ContentType "application/json" `
                    -Body (@{ Name = $AdminUsername; Password = $AdminPassword } | ConvertTo-Json) | Out-Null
                Invoke-RestMethod -Uri "$jfBase/Startup/Configuration" -Method Post -ContentType "application/json" `
                    -Body (@{ UICulture = "en-US"; MetadataCountryCode = "US"; PreferredMetadataLanguage = "en" } | ConvertTo-Json) | Out-Null
                Invoke-RestMethod -Uri "$jfBase/Startup/RemoteAccess" -Method Post -ContentType "application/json" `
                    -Body (@{ EnableRemoteAccess = $true; EnableAutomaticPortMapping = $false } | ConvertTo-Json) | Out-Null
                Invoke-RestMethod -Uri "$jfBase/Startup/Complete" -Method Post | Out-Null
                $state["Jellyfin_WizardDone"] = $true
                Save-State
                Log "Jellyfin first-run wizard completed automatically (user: $AdminUsername)." "OK"
                # Jellyfin restarts its web host right after Startup/Complete -- give it a moment.
                Start-Sleep -Seconds 5
                Wait-ForHttpOk -Url $jfBase -TimeoutSec 60 | Out-Null
            } catch {
                $body = Get-ErrorResponseBody $_
                $detail = if ($body) { " -- $body" } else { "" }
                Log "Jellyfin wizard automation failed -- $($_.Exception.Message)$detail" "WARN"
            }
        } else {
            Log "Jellyfin wizard already completed, skipping."
        }

        # Deliberately not gated on $state["Jellyfin_LibrariesDone"] alone --
        # confirmed live that flag can be true while a library still has no
        # real path attached (the old code treated "a library with this name
        # exists" as done, without ever checking Locations). Always verify
        # against Jellyfin's own live state instead of trusting our cached
        # flag; the per-library loop below is already a cheap no-op for
        # anything actually correct.
        try {
                $authHeader = 'MediaBrowser Client="REGTeches Media Stack", Device="Installer", DeviceId="regtms-installer", Version="1.0.0"'
                $authResp = Invoke-RestMethod -Uri "$jfBase/Users/AuthenticateByName" -Method Post -ContentType "application/json" `
                    -Headers @{ Authorization = $authHeader } -Body (@{ Username = $AdminUsername; Pw = $AdminPassword } | ConvertTo-Json)
                $jfHeaders = @{ Authorization = "$authHeader, Token=`"$($authResp.AccessToken)`"" }

                $existingLibs = @(Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders" -Headers $jfHeaders)
                $libraries = @(
                    @{ Name = "Movies"; CollectionType = "movies";  Folder = "movies" }
                    @{ Name = "TV";     CollectionType = "tvshows"; Folder = "tv" }
                    @{ Name = "Music";  CollectionType = "music";   Folder = "music" }
                    @{ Name = "Books";  CollectionType = "books";   Folder = "books" }
                    @{ Name = "Adult";  CollectionType = "movies";  Folder = "adult" }
                )
                foreach ($lib in $libraries) {
                    $libPath = Join-Path $paths.Media $lib.Folder
                    $existing = $existingLibs | Where-Object { $_.Name -eq $lib.Name }
                    $pathAlreadyAttached = $existing -and (@($existing.Locations) -contains $libPath)

                    if ($pathAlreadyAttached) {
                        # Nothing to attach -- still falls through below to make
                        # sure real-time monitoring is on for it too.
                    } elseif ($existing) {
                        # A library with this name exists but the real folder
                        # never actually attached to it -- confirmed live: this
                        # is exactly what "'Jellyfin_LibrariesDone' already true,
                        # library exists by name" was masking previously (the
                        # old code treated any same-named library as done,
                        # nothing checked Locations). Self-heal it by adding the
                        # path to the existing library instead of leaving it
                        # empty and forever skipped.
                        $pathBody = @{ Name = $lib.Name; Path = $libPath } | ConvertTo-Json
                        Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders/Paths" -Method Post -Headers $jfHeaders -ContentType "application/json" -Body $pathBody | Out-Null
                    } else {
                        $qs = "name=$([uri]::EscapeDataString($lib.Name))&collectionType=$($lib.CollectionType)&paths=$([uri]::EscapeDataString($libPath))&refreshLibrary=false"
                        # The `paths` query param alone is what Jellyfin's own
                        # web UI relies on (a custom comma-delimited binder,
                        # confirmed by reading LibraryStructureController.cs for
                        # our exact version) -- but it silently produced a
                        # library with no real path attached in practice,
                        # falling back to showing its own internal
                        # appdata\Jellyfin\root\default\<name> bookkeeping
                        # folder with nothing real inside it (found live:
                        # Sonarr's imports were landing in media\tv correctly
                        # the whole time -- this was never an import problem).
                        # Also sending the same path via the documented JSON
                        # body (LibraryOptions.PathInfos) is a plain, ordinary
                        # model bind with none of the query binder's edge
                        # cases -- belt-and-suspenders, not a replacement.
                        # EnableRealtimeMonitor: not in LibraryOptions' own
                        # explicit-defaults list (confirmed by reading its
                        # constructor), so it's C#'s bare false unless set here
                        # -- without it, Jellyfin only notices new downloads on
                        # its 12-hour scheduled scan (RefreshMediaLibraryTask's
                        # own default interval) instead of near-instantly via
                        # its file-system watcher.
                        $bodyPayload = @{ LibraryOptions = @{ PathInfos = @(@{ Path = $libPath }); EnableRealtimeMonitor = $true } } | ConvertTo-Json -Depth 5
                        Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders?$qs" -Method Post -Headers $jfHeaders -ContentType "application/json" -Body $bodyPayload | Out-Null
                    }

                    # Verify rather than assume: a 204 No Content response only
                    # means Jellyfin accepted the call, not that a real path
                    # actually got attached (exactly the failure mode above).
                    Start-Sleep -Seconds 1
                    $created = @(Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders" -Headers $jfHeaders) | Where-Object { $_.Name -eq $lib.Name }
                    if ($created -and @($created.Locations) -contains $libPath) {
                        Log "Jellyfin library '$($lib.Name)' -> $libPath" "OK"
                    } else {
                        Log "Jellyfin library '$($lib.Name)' exists, but its real path didn't attach (Locations: $(@($created.Locations) -join ', ')) -- add $libPath to it by hand from Jellyfin's Dashboard -> Libraries." "WARN"
                    }

                    # Covers the two cases the block above doesn't touch: a
                    # library that was already correctly attached before this
                    # run (never went through the create/self-heal calls, so
                    # never got EnableRealtimeMonitor set either), and a
                    # self-healed one (the Paths endpoint only attaches the
                    # path, it doesn't touch this flag). Rebuilds a fresh,
                    # minimal LibraryOptions from Locations (which is already
                    # verified correct above) instead of round-tripping
                    # whatever Jellyfin's GET returned for LibraryOptions --
                    # confirmed live that the round-trip approach silently
                    # failed to take effect (UI still showed it off after a
                    # run this shipped in), and this GET response's exact
                    # shape/nullability isn't something to keep guessing at.
                    # Anything else on the library not set here falls back to
                    # LibraryOptions' own constructor defaults, not to empty/
                    # off, so this doesn't clobber a fresh install's settings.
                    if (-not $created) {
                        Log "Jellyfin library '$($lib.Name)': couldn't re-fetch it to check real-time monitoring." "WARN"
                    } elseif (-not $created.ItemId) {
                        Log "Jellyfin library '$($lib.Name)': no ItemId came back from Jellyfin, can't target the LibraryOptions update -- turn on 'Enable Real Time Monitoring' by hand in Jellyfin -> Dashboard -> Libraries -> $($lib.Name) -> Advanced." "WARN"
                    } elseif ($created.LibraryOptions.EnableRealtimeMonitor) {
                        Log "Jellyfin library '$($lib.Name)': real-time monitoring already on."
                    } else {
                        $optionsBody = @{
                            Id = $created.ItemId
                            LibraryOptions = @{
                                PathInfos = @(@($created.Locations) | ForEach-Object { @{ Path = $_ } })
                                EnableRealtimeMonitor = $true
                            }
                        } | ConvertTo-Json -Depth 8
                        try {
                            Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders/LibraryOptions" -Method Post -Headers $jfHeaders -ContentType "application/json" -Body $optionsBody | Out-Null
                            Start-Sleep -Seconds 1
                            $reChecked = @(Invoke-RestMethod -Uri "$jfBase/Library/VirtualFolders" -Headers $jfHeaders) | Where-Object { $_.Name -eq $lib.Name }
                            if ($reChecked -and $reChecked.LibraryOptions.EnableRealtimeMonitor) {
                                Log "Jellyfin library '$($lib.Name)': enabled real-time monitoring (was off -- new downloads would otherwise only appear on the 12-hour scheduled scan)." "OK"
                            } else {
                                Log "Jellyfin library '$($lib.Name)': asked Jellyfin to enable real-time monitoring, but it still reports off after re-checking -- turn it on by hand in Jellyfin -> Dashboard -> Libraries -> $($lib.Name) -> Advanced." "WARN"
                            }
                        } catch {
                            $body = Get-ErrorResponseBody $_
                            $detail = if ($body) { " -- $body" } else { "" }
                            Log "Could not enable real-time monitoring on Jellyfin library '$($lib.Name)': $($_.Exception.Message)$detail -- it'll still show up on the next scheduled scan (every 12h by default), or turn it on by hand in Jellyfin -> Dashboard -> Libraries -> $($lib.Name) -> Advanced." "WARN"
                        }
                    }
                }
                $state["Jellyfin_LibrariesDone"] = $true
                Save-State
                Log "Jellyfin libraries provisioned under $($paths.Media)." "OK"
        } catch {
            $body = Get-ErrorResponseBody $_
            $detail = if ($body) { " -- $body" } else { "" }
            Log "Could not add Jellyfin libraries -- finish it manually at http://localhost:8096 with user '$AdminUsername', pointing libraries at $($paths.Media)\<type>: $($_.Exception.Message)$detail" "WARN"
        }

        # A curated, zero-configuration-needed set of plugins -- not the
        # full catalog. Each plugin (name + GUID) confirmed directly from its
        # own Plugin.cs / manifest.json source, not guessed: Playback
        # Reporting ships in Jellyfin's own official repo, so it needs no
        # extra repository; Intro Skipper and Jellyscrub are third-party and
        # need their own repository URLs added first (POST /Repositories
        # *replaces* the whole list, confirmed from PackageController.cs, so
        # this fetches the existing list and appends rather than over
        # writing whatever's already configured).
        if (-not $SkipJellyfinPlugins) {
            try {
                $jfRepos = @(
                    @{ Name = "intro-skipper"; Url = "https://intro-skipper.org/manifest.json" }
                    @{ Name = "jellyscrub"; Url = "https://raw.githubusercontent.com/nicknsy/jellyscrub/main/manifest.json" }
                )
                # @(...) alone turns a genuinely empty result into a 1-element
                # array containing $null, not an empty array -- confirmed live:
                # Jellyfin's own repo list came back empty, and the resulting
                # [null, {...}, {...}] got correctly rejected by ASP.NET Core
                # ("$[0] could not be converted to RepositoryInfo"). Check for
                # $null explicitly before deciding the array shape.
                $rawRepos = Invoke-RestMethod -Uri "$jfBase/Repositories" -Headers $jfHeaders
                $existingRepos = if ($null -eq $rawRepos) { @() } else { @($rawRepos) }
                $newRepoList = @($existingRepos)
                $reposChanged = $false
                foreach ($repo in $jfRepos) {
                    if (-not ($existingRepos | Where-Object { $_.Url -eq $repo.Url })) {
                        $newRepoList += @{ Name = $repo.Name; Url = $repo.Url; Enabled = $true }
                        $reposChanged = $true
                    }
                }
                if ($reposChanged) {
                    Invoke-RestMethod -Uri "$jfBase/Repositories" -Method Post -Headers $jfHeaders -ContentType "application/json" -Body ($newRepoList | ConvertTo-Json -Depth 5) | Out-Null
                    Log "Jellyfin: added Intro Skipper and Jellyscrub plugin repositories."
                    Start-Sleep -Seconds 2
                }

                $jfDesiredPlugins = @(
                    @{ Name = "Playback Reporting"; Guid = "5c534381-91a3-43cb-907a-35aa02eb9d2c" }
                    @{ Name = "Intro Skipper";      Guid = "c83d86bb-a1e0-4c35-a113-e2101cf4ee6b" }
                    @{ Name = "Jellyscrub";         Guid = "a84a949d-4b73-4099-aacb-8341b4da17ba" }
                )
                $installedPlugins = @(Invoke-RestMethod -Uri "$jfBase/Plugins" -Headers $jfHeaders)

                # Self-heal: a plugin's folder (DLL and all) can be sitting
                # on disk without Jellyfin's own /Plugins ever recognizing
                # it -- confirmed directly from Jellyfin's own server log
                # after a run that hit this: every install attempt below
                # failed with "the process cannot access the file ... because
                # it is being used by another process", immediately followed
                # by Jellyfin's own "No local manifest exists for plugin ...
                # Skipping manifest reconciliation." Jellyfin loads/locks the
                # stray DLL during its own startup scan even though it never
                # finished registering the plugin (no manifest.json ever got
                # written, so /Plugins doesn't list it) -- a leftover
                # half-install from some earlier interrupted attempt. The
                # lock is held by Jellyfin's own currently-running process,
                # so nothing short of restarting it releases the file; only
                # then can the stale folder actually be removed and a clean
                # install retried.
                $pluginsDir = Join-Path $jfDataDir "plugins"
                $orphanedFolders = @()
                foreach ($plugin in $jfDesiredPlugins) {
                    if ($installedPlugins | Where-Object { $_.Id -eq $plugin.Guid }) { continue }
                    $orphanedFolders += @(Get-ChildItem -Path $pluginsDir -Directory -Filter "$($plugin.Name)_*" -ErrorAction SilentlyContinue)
                }
                if ($orphanedFolders.Count -gt 0) {
                    Log "Found $($orphanedFolders.Count) leftover Jellyfin plugin folder(s) from a previous install that never finished ($(($orphanedFolders | ForEach-Object { $_.Name }) -join ', ')) -- Jellyfin loaded/locked their DLLs without ever registering them. Restarting Jellyfin to clear the lock, then removing them so a clean install can proceed."
                    Get-Process -Name "jellyfin" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    foreach ($folder in $orphanedFolders) {
                        Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Start-ScheduledTask -TaskName $jfTaskName
                    if (Wait-ForJellyfinApiReady -JfBase $jfBase -TimeoutSec 90) {
                        # Session tokens are stored server-side and likely
                        # survive the restart, but re-authenticate rather
                        # than assume that.
                        $authResp = Invoke-RestMethod -Uri "$jfBase/Users/AuthenticateByName" -Method Post -ContentType "application/json" `
                            -Headers @{ Authorization = $authHeader } -Body (@{ Username = $AdminUsername; Pw = $AdminPassword } | ConvertTo-Json)
                        $jfHeaders = @{ Authorization = "$authHeader, Token=`"$($authResp.AccessToken)`"" }
                        $installedPlugins = @(Invoke-RestMethod -Uri "$jfBase/Plugins" -Headers $jfHeaders)
                        Log "Jellyfin restarted after clearing stale plugin folder(s)." "OK"
                    } else {
                        Log "Jellyfin didn't come back up within 90s after clearing stale plugin folder(s) -- plugin install will be retried next run." "WARN"
                    }
                }

                $anyPluginInstalled = $false
                foreach ($plugin in $jfDesiredPlugins) {
                    if ($installedPlugins | Where-Object { $_.Id -eq $plugin.Guid }) {
                        Log "Jellyfin plugin '$($plugin.Name)' already installed."
                        continue
                    }
                    try {
                        # No version specified -- InstallPackage picks the
                        # latest version compatible with this Jellyfin build
                        # on its own (confirmed from PackageController.cs's
                        # GetCompatibleVersions call), so this doesn't need
                        # updating as new plugin versions ship.
                        Invoke-RestMethod -Uri "$jfBase/Packages/Installed/$([uri]::EscapeDataString($plugin.Name))?assemblyGuid=$($plugin.Guid)" -Method Post -Headers $jfHeaders | Out-Null
                        Log "Jellyfin plugin '$($plugin.Name)' installed -- needs a restart to load, done below." "OK"
                        $anyPluginInstalled = $true
                    } catch {
                        $body = Get-ErrorResponseBody $_
                        $detail = if ($body) { " -- $body" } else { "" }
                        Log "Could not install Jellyfin plugin '$($plugin.Name)': $($_.Exception.Message)$detail -- add it by hand from Jellyfin's Dashboard -> Plugins -> Catalog." "WARN"
                    }
                }

                if ($anyPluginInstalled) {
                    Log "Restarting Jellyfin to load the newly installed plugin(s)..."
                    Get-Process -Name "jellyfin" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    Start-ScheduledTask -TaskName $jfTaskName
                    if (Wait-ForHttpOk -Url $jfBase -TimeoutSec 90) {
                        Log "Jellyfin restarted with new plugin(s) loaded." "OK"
                    } else {
                        Log "Jellyfin didn't come back up within 90s after the plugin-install restart -- check on it manually at http://localhost:8096." "WARN"
                    }
                }
            } catch {
                $body = Get-ErrorResponseBody $_
                $detail = if ($body) { " -- $body" } else { "" }
                Log "Could not set up Jellyfin plugins: $($_.Exception.Message)$detail -- add them by hand from Jellyfin's Dashboard -> Plugins." "WARN"
            }
        }
    } else {
        Log "Jellyfin did not respond on port 8096 within timeout -- wizard/library setup skipped this run, will retry next run." "WARN"
    }
}

# ============================================================
# Seerr: free/open-source request management (the actively maintained
# successor to Jellyseerr/Overseerr -- https://docs.seerr.dev) -- lets
# people request movies/TV through a proper UI instead of poking
# Sonarr/Radarr directly, and syncs watch/availability status back from
# Jellyfin. Ships no native Windows installer or prebuilt binary at all
# (confirmed: its GitHub releases carry only source zips, no assets) --
# building it from source via Node.js + pnpm is the only non-Docker path,
# exactly matching Seerr's own documented Windows build steps
# (https://docs.seerr.dev/getting-started/buildfromsource/). Unlike
# qBittorrent/Jellyfin/SABnzbd, it's a plain headless Node server with no
# GUI subsystem of its own, so it runs as a real NSSM service (SYSTEM
# account, no desktop session needed) exactly like the *arr apps -- no
# scheduled-task workaround required here.
# ============================================================

if (-not $SkipSeerr) {
    Log "---- Seerr ----"
    $seerrRoot = Join-Path $paths.Apps "Seerr"
    $seerrConfigDir = Join-Path $paths.AppData "Seerr\config"
    $seerrDistIndex = Join-Path $seerrRoot "dist\index.js"
    $nodeExe = "C:\Program Files\nodejs\node.exe"

    try {
        # ---- Node.js 22.x (Seerr's own documented minimum) ----
        $needsNode = $true
        if (Test-Path $nodeExe) {
            $nodeVersion = & $nodeExe --version
            if ($nodeVersion -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) { $needsNode = $false }
        }
        if ($needsNode) {
            $nodeIndex = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json"
            $latestNode22 = $nodeIndex | Where-Object { $_.version -match '^v22\.' } | Select-Object -First 1
            if (-not $latestNode22) { throw "Could not find a v22.x release in Node.js's own dist index -- check https://nodejs.org/dist/index.json manually." }
            $nodeMsiName = "node-$($latestNode22.version)-x64.msi"
            $nodeMsi = Join-Path $paths.Tools $nodeMsiName
            Log "Downloading Node.js $($latestNode22.version) (Seerr needs 22.x, none found)..."
            Invoke-DownloadFile -Url "https://nodejs.org/dist/$($latestNode22.version)/$nodeMsiName" -OutFile $nodeMsi
            Log "Installing Node.js $($latestNode22.version) silently..."
            Start-Process msiexec.exe -ArgumentList "/i", "`"$nodeMsi`"", "/quiet", "/norestart", "ADDLOCAL=ALL" -Wait
            Remove-Item $nodeMsi -Force
            if (-not (Test-Path $nodeExe)) { throw "node.exe still not found at $nodeExe after installing Node.js." }
            Log "Node.js $($latestNode22.version) installed." "OK"
        } else {
            Log "Node.js $nodeVersion already installed."
        }

        # Confirmed live: npm.cmd (called below by full path, right next to
        # its own node.exe) works fine regardless of PATH, but pnpm.cmd's
        # shim lands in npm's global prefix -- a different folder than Node's
        # own install dir (see the comment right below) -- so it has no local
        # node.exe next to it and falls back to bare `node`, which needs
        # PATH. The Node MSI updates the registry's PATH, but this
        # already-running process never picks that up on its own, so pnpm.cmd
        # failed with `'"node"' is not recognized` even though Node.js was
        # installed correctly moments earlier. Add it to this process's PATH
        # explicitly instead of relying on a registry change an already-open
        # process can't see.
        $nodeDir = Split-Path $nodeExe -Parent
        if (($env:Path -split ';') -notcontains $nodeDir) {
            $env:Path = "$nodeDir;$env:Path"
        }

        $npmCmd = "C:\Program Files\nodejs\npm.cmd"
        # Confirmed live: assuming pnpm.cmd lands directly under Node's own
        # install dir (the common Windows default) was wrong on a real
        # machine -- `npm install -g` reported success (exit 0) but the
        # shim wasn't there, meaning npm's actual global prefix on that box
        # is set to something else (an .npmrc or env var override). Ask npm
        # itself where its global prefix actually is instead of assuming.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $npmGlobalPrefix = (& $npmCmd prefix -g 2>$null | Select-Object -Last 1)
        } finally {
            $ErrorActionPreference = $prevEap
        }
        # Confirmed live, second machine: npm reports its configured prefix
        # (a real, correct value) even when that directory doesn't exist on
        # disk yet -- true on a brand-new VM where nothing has ever been
        # npm-installed globally before, since npm only creates the prefix
        # folder on demand during an actual `npm install -g`. Requiring it
        # to already exist here was wrong; just take the string and let the
        # install step below (which already checks pnpm.cmd afterward) be
        # the real verification point.
        if (-not $npmGlobalPrefix) { throw "npm prefix -g returned nothing -- npm itself may not be working correctly." }
        $pnpmCmd = Join-Path $npmGlobalPrefix.Trim() "pnpm.cmd"

        # ---- Fetch source (latest release tag, not main -- reproducible) ----
        if (-not (Test-Path (Join-Path $seerrRoot "package.json"))) {
            $seerrRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/seerr-team/seerr/releases/latest" -Headers $ghHeaders
            $seerrTag = $seerrRelease.tag_name
            $seerrZip = Join-Path $paths.Apps "seerr-src.zip"
            Log "Downloading Seerr $seerrTag source..."
            Invoke-DownloadFile -Url "https://github.com/seerr-team/seerr/archive/refs/tags/$seerrTag.zip" -OutFile $seerrZip
            $seerrExtract = Join-Path $paths.Apps "seerr_extract"
            Microsoft.PowerShell.Archive\Expand-Archive -Path $seerrZip -DestinationPath $seerrExtract -Force
            $extractedRoot = Get-ChildItem -Path $seerrExtract -Directory | Select-Object -First 1
            if (Test-Path $seerrRoot) { Remove-Item $seerrRoot -Recurse -Force }
            Move-Item $extractedRoot.FullName $seerrRoot
            Remove-Item $seerrZip, $seerrExtract -Recurse -Force -ErrorAction SilentlyContinue
            $state["Seerr_Version"] = $seerrTag
            Save-State
            Log "Seerr $seerrTag source ready." "OK"
        } else {
            Log "Seerr source already present, skipping fetch."
        }

        # ---- Build. `pnpm` installed globally via npm, pinned to the exact
        # version Seerr itself declares in its own package.json
        # "packageManager" field -- confirmed live that `corepack enable`
        # (bundled with Node 22, the originally-tried route) silently didn't
        # create pnpm.cmd at all on a real run, with no error surfaced (the
        # Windows MSI installer treats Corepack as its own separate,
        # independently-selectable optional feature, confirmed from its own
        # WiX installer config -- ADDLOCAL=ALL should include it but
        # apparently didn't reliably). Installing pnpm directly via npm
        # sidesteps that whole optional-feature question and Corepack's own
        # separate first-use download-confirmation behavior. Its "start"
        # script ("NODE_ENV=production node dist/index.js") is Unix
        # inline-env syntax that doesn't work under cmd.exe anyway --
        # irrelevant here, since the service below calls node.exe on
        # dist/index.js directly and sets NODE_ENV via NSSM's own
        # environment support instead. ----
        if (-not (Test-Path $seerrDistIndex)) {
            $buildLog = Join-Path $paths.Logs "seerr-build.log"
            # npm/pnpm both write routine, harmless chatter ("npm notice",
            # "npm warn", progress lines) to stderr by their own convention,
            # not just real errors -- confirmed live: under this script's
            # global $ErrorActionPreference = "Stop", the very first such
            # stderr line from npm got promoted straight into a terminating
            # PowerShell exception (its .Message literally just "npm
            # notice", the actual npm command's own exit code never even
            # checked). Relax it for exactly these external-command calls
            # and rely on $LASTEXITCODE (checked explicitly below) as the
            # real success/failure signal instead -- same family of bug as
            # the qBittorrent 409 fix earlier, just stderr instead of HTTP
            # status this time.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                if (-not (Test-Path $pnpmCmd)) {
                    $seerrPkg = Get-Content (Join-Path $seerrRoot "package.json") -Raw | ConvertFrom-Json
                    $pnpmVersion = if ($seerrPkg.packageManager -match '^pnpm@([\d.]+)') { $Matches[1] } else { "10" }
                    Log "Installing pnpm $pnpmVersion (Seerr's own pinned version) via npm..."
                    & $npmCmd install -g "pnpm@$pnpmVersion" *>> $buildLog
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pnpmCmd)) { throw "npm install -g pnpm@$pnpmVersion didn't produce pnpm.cmd (exit $LASTEXITCODE) -- see $buildLog" }
                    Log "pnpm $pnpmVersion installed." "OK"
                }

                $env:CYPRESS_INSTALL_BINARY = "0"
                Push-Location $seerrRoot
                try {
                    Log "Installing Seerr's dependencies via pnpm (can take several minutes -- see $buildLog for progress)..."
                    & $pnpmCmd install --frozen-lockfile *>> $buildLog
                    if ($LASTEXITCODE -ne 0) { throw "pnpm install failed (exit $LASTEXITCODE) -- see $buildLog" }

                    Log "Building Seerr (can take several minutes)..."
                    & $pnpmCmd build *>> $buildLog
                    if ($LASTEXITCODE -ne 0) { throw "pnpm build failed (exit $LASTEXITCODE) -- see $buildLog" }
                } finally {
                    Pop-Location
                }
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if (-not (Test-Path $seerrDistIndex)) { throw "Build finished but $seerrDistIndex still doesn't exist -- see $buildLog" }
            Log "Seerr built successfully." "OK"
        } else {
            Log "Seerr already built, skipping."
        }

        # ---- Run as a real Windows service ----
        New-Item -ItemType Directory -Force -Path $seerrConfigDir | Out-Null
        Install-NssmService -ServiceName "REGTMS-Seerr" -DisplayName "Seerr" `
            -BinPath $nodeExe -AppArgs "`"$seerrDistIndex`"" -WorkingDir $seerrRoot `
            -ExtraEnv "NODE_ENV=production`nCONFIG_DIRECTORY=$seerrConfigDir`nPORT=5055"

        if (Wait-ForHttpOk -Url "http://localhost:5055" -TimeoutSec 90) {
            Log "Seerr is up on port 5055." "OK"

            # ---- Auto-wire to Jellyfin + Sonarr/Radarr, matching what the
            # rest of this installer already does for every other app.
            # Confirmed directly from Seerr's own source
            # (server/routes/auth.ts): POST /api/v1/auth/jellyfin both
            # creates the first admin account AND saves the Jellyfin
            # connection in the same call, on a fresh install. POST
            # /api/v1/settings/sonarr and /settings/radarr just save a plain
            # settings object (server/routes/settings/sonarr.ts) -- no
            # separate "test" call needed since these instances are already
            # confirmed working earlier in this script. CSRF protection
            # defaults to off (settings.network.csrfProtection = false,
            # confirmed from Seerr's own Settings class), so no token dance
            # needed for this one-time setup. ----
            try {
                $seerrBase = "http://localhost:5055/api/v1"
                # Confirmed directly from Seerr's own auth.ts: sending a
                # hostname when settings.jellyfin.ip is already set (i.e.
                # every run after the first successful sign-in) gets
                # rejected outright with "Jellyfin hostname already
                # configured" -- and omitting it on a genuinely fresh
                # instance gets rejected with "No hostname provided."
                # Rather than track our own state (which could drift if the
                # user reconfigures Seerr by hand), just try the plain
                # login first and only add the hostname/port/etc if Seerr
                # itself says it still needs them -- self-correcting either
                # way, matching what Seerr's own state actually is right now.
                $seerrLoginFields = @{
                    username   = $AdminUsername
                    password   = $AdminPassword
                    serverType = 2   # MediaServerType.JELLYFIN, confirmed from server/constants/server.ts
                }
                try {
                    Invoke-RestMethod -Uri "$seerrBase/auth/jellyfin" -Method Post -ContentType "application/json" `
                        -Body ($seerrLoginFields | ConvertTo-Json) -SessionVariable seerrSession | Out-Null
                } catch {
                    $firstAttemptBody = Get-ErrorResponseBody $_
                    if ($firstAttemptBody -notmatch "No hostname provided") { throw }
                    $seerrLoginFields.hostname = "localhost"
                    $seerrLoginFields.port     = 8096
                    $seerrLoginFields.urlBase  = ""
                    $seerrLoginFields.useSsl   = $false
                    Invoke-RestMethod -Uri "$seerrBase/auth/jellyfin" -Method Post -ContentType "application/json" `
                        -Body ($seerrLoginFields | ConvertTo-Json) -SessionVariable seerrSession | Out-Null
                }
                Log "Seerr: signed in with Jellyfin and saved the media-server connection." "OK"

                # Seerr auto-generates its own admin API key (settings.main.
                # apiKey, confirmed from server/middleware/auth.ts -- an
                # X-API-Key header is checked the same way Sonarr/Radarr/etc
                # already work in this script) -- capture it now so the
                # dashboard can show Seerr's request counts without needing
                # its own session cookie.
                try {
                    $seerrMainSettings = Invoke-RestMethod -Uri "$seerrBase/settings/main" -Method Get -WebSession $seerrSession
                    if ($seerrMainSettings.apiKey) {
                        $state["Seerr_ApiKey"] = $seerrMainSettings.apiKey
                        Save-State
                    }
                } catch {
                    Log "Seerr: could not capture its API key for the dashboard (not fatal -- Seerr itself is still fully configured): $($_.Exception.Message)" "WARN"
                }

                $seerrArrTargets = @(
                    @{ Name = "Sonarr"; Port = 8989; RootFolder = (Join-Path $paths.Media "tv");     Extra = @{ seriesType = "standard"; animeSeriesType = "standard"; enableSeasonFolders = $true; monitorNewItems = "all" } }
                    @{ Name = "Radarr"; Port = 7878; RootFolder = (Join-Path $paths.Media "movies"); Extra = @{ minimumAvailability = "released" } }
                )
                foreach ($target in $seerrArrTargets) {
                    $qpDebug = ""
                    try {
                        $apiKey = $state["$($target.Name)_ApiKey"]
                        if (-not $apiKey) {
                            Log "Seerr: no captured API key for $($target.Name), skipping -- add it by hand from Seerr's Settings -> Services." "WARN"
                            continue
                        }
                        $qpRaw = Invoke-ArrApi -BaseUrl "http://localhost:$($target.Port)/api/v3" -ApiKey $apiKey -Path "qualityprofile"
                        # Diagnostic only, kept out of the happy path: three
                        # rounds of source-reading and local repro (both the
                        # plain and the exact nested try/catch-wrapped
                        # function-return-through-a-pipe pattern) failed to
                        # explain why activeProfileId's cast throws
                        # "Cannot convert System.Object[] ... to
                        # System.Int32" against the real, live Sonarr/Radarr
                        # -- every mechanical reproduction works. Something
                        # about the actual live response shape must differ;
                        # capture it directly instead of theorizing further.
                        $qpDebug = "qpRaw type=$(if ($null -eq $qpRaw) { '<null>' } else { $qpRaw.GetType().FullName }), count=$(@($qpRaw).Count), raw=$(($qpRaw | Select-Object -First 2 | ConvertTo-Json -Compress -Depth 4))"
                        $qualityProfile = @($qpRaw) | Select-Object -First 1
                        if (-not $qualityProfile) {
                            Log "Seerr: $($target.Name) has no quality profiles yet, skipping -- add it by hand from Seerr's Settings -> Services." "WARN"
                            continue
                        }
                        $dvrBody = [ordered]@{
                            name              = $target.Name
                            hostname          = "localhost"
                            port              = $target.Port
                            apiKey            = $apiKey
                            useSsl            = $false
                            baseUrl           = ""
                            activeProfileId   = [int]$qualityProfile.id
                            activeProfileName = $qualityProfile.name
                            activeDirectory   = $target.RootFolder
                            tags              = @()
                            is4k              = $false
                            isDefault         = $true
                            syncEnabled       = $true
                            preventSearch     = $false
                            tagRequests       = $false
                            overrideRule      = @()
                        }
                        foreach ($k in $target.Extra.Keys) { $dvrBody[$k] = $target.Extra[$k] }
                        $lowerName = $target.Name.ToLower()
                        $dvrJson = $dvrBody | ConvertTo-Json
                        Invoke-RestMethod -Uri "$seerrBase/settings/$lowerName" -Method Post -ContentType "application/json" `
                            -Body $dvrJson -WebSession $seerrSession | Out-Null
                        Log "Seerr: $($target.Name) wired up (profile '$($qualityProfile.name)', root $($target.RootFolder))." "OK"
                    } catch {
                        $body = Get-ErrorResponseBody $_
                        $detail = if ($body) { " -- $body" } else { "" }
                        # Logged with the exact JSON sent plus $qpDebug --
                        # confirmed live that reading Seerr's/Sonarr's/
                        # Radarr's source alone wasn't enough to pin down a
                        # prior "activeProfileId must be number" failure,
                        # and every local repro of this exact PowerShell
                        # pattern (function return -> pipe -> Select-Object
                        # -First 1 -> cast) came back correct -- so whatever
                        # is different must be in the real, live qualityprofile
                        # response shape. Capture it directly instead of
                        # theorizing again if this fails once more.
                        Log "Seerr: could not wire up $($target.Name): $($_.Exception.Message)$detail -- sent: $dvrJson -- $qpDebug -- add it by hand from Seerr's Settings -> Services." "WARN"
                    }
                }

                # Sync Jellyfin's libraries into Seerr, then enable only
                # Movies/TV -- confirmed from Seerr's own source
                # (settings/jellyfin/library route): ?sync=true discovers
                # libraries fresh from Jellyfin, ?enable=<ids> is a SEPARATE
                # call that turns specific ones on (anything left out ends
                # up disabled). Deliberately not enabling Music/Books/Adult:
                # Seerr only ever requests movies/TV, and there's no
                # library-type signal to tell "Adult" apart from "Movies"
                # (this stack sets both to Jellyfin's "movies"
                # CollectionType) -- matching by the exact names this
                # installer itself gave those libraries is the only
                # reliable way to leave Adult out by default.
                try {
                    $syncedLibs = @(Invoke-RestMethod -Uri "$seerrBase/settings/jellyfin/library?sync=true" -Method Get -WebSession $seerrSession)
                    $wantedLibs = @($syncedLibs | Where-Object { $_.name -in @("Movies", "TV") })
                    if ($wantedLibs.Count -gt 0) {
                        $enableParam = ($wantedLibs | ForEach-Object { $_.id }) -join ","
                        Invoke-RestMethod -Uri "$seerrBase/settings/jellyfin/library?enable=$enableParam" -Method Get -WebSession $seerrSession | Out-Null
                        Log "Seerr: enabled Jellyfin libraries for scanning ($(($wantedLibs | ForEach-Object { $_.name }) -join ', '))." "OK"
                    } else {
                        Log "Seerr: synced Jellyfin libraries, but found none named 'Movies'/'TV' to enable -- pick them by hand from Seerr's Settings -> Jellyfin." "WARN"
                    }
                } catch {
                    $body = Get-ErrorResponseBody $_
                    $detail = if ($body) { " -- $body" } else { "" }
                    Log "Seerr: could not sync/enable Jellyfin libraries: $($_.Exception.Message)$detail -- click 'Sync Libraries' by hand from Seerr's Settings -> Jellyfin." "WARN"
                }

                # Confirmed from Seerr's own source (settings route
                # '/initialize'): saving settings via the API directly (as
                # done above) does NOT mark its first-run setup wizard as
                # complete -- that's a separate flag (settings.public.
                # initialized), only set by this dedicated call. Without
                # it, opening Seerr in a browser keeps dropping back into
                # the wizard on "Configure Media Server" even though every
                # setting it asks for is already correctly saved.
                try {
                    Invoke-RestMethod -Uri "$seerrBase/settings/initialize" -Method Post -WebSession $seerrSession | Out-Null
                    Log "Seerr: setup wizard marked complete." "OK"
                } catch {
                    $body = Get-ErrorResponseBody $_
                    $detail = if ($body) { " -- $body" } else { "" }
                    Log "Seerr: could not mark setup complete: $($_.Exception.Message)$detail -- everything is configured, but opening Seerr may still show its setup wizard; click through it once at http://localhost:5055." "WARN"
                }
            } catch {
                $body = Get-ErrorResponseBody $_
                $detail = if ($body) { " -- $body" } else { "" }
                Log "Seerr: could not sign in with Jellyfin: $($_.Exception.Message)$detail -- finish it by hand at http://localhost:5055 (sign in with your Jellyfin account, then add Sonarr/Radarr from Settings -> Services)." "WARN"
            }
        } else {
            Log "Seerr did not respond on port 5055 within timeout -- check $(Join-Path $paths.Logs 'REGTMS-Seerr.err.log')." "WARN"
        }
    } catch {
        Log "Failed to set up Seerr: $($_.Exception.Message)" "ERROR"
    }
}

# ============================================================
# Tailscale: reach the stack from anywhere without opening ports to the
# whole internet. Installing it is fully automatable; joining your tailnet
# isn't -- that's an account-login step only Ron can complete (either by
# supplying his own pre-generated auth key, or approving the browser prompt
# this opens once).
# ============================================================

if (-not $SkipTailscale) {
    Log "---- Tailscale ----"
    $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (-not (Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue)) {
        try {
            $tsInfo = Invoke-RestMethod -Uri "https://pkgs.tailscale.com/stable/?mode=json"
            $tsMsiName = $tsInfo.MSIs.amd64
            $tsInstaller = Join-Path $paths.Apps $tsMsiName
            Invoke-DownloadFile -Url "https://pkgs.tailscale.com/stable/$tsMsiName" -OutFile $tsInstaller
            Log "Installing Tailscale $($tsInfo.MSIsVersion) silently..."
            Start-Process msiexec.exe -ArgumentList "/i", "`"$tsInstaller`"", "/quiet", "/norestart" -Wait
            Remove-Item $tsInstaller -Force
            $state["Tailscale_Version"] = $tsInfo.MSIsVersion
            Save-State
            Log "Tailscale installed." "OK"
        } catch {
            Log "Failed to install Tailscale: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Log "Tailscale already installed."
    }

    Start-Sleep -Seconds 3
    if (Test-Path $tsExe) {
        $tsStatus = & $tsExe status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($tsStatus -and $tsStatus.BackendState -eq "Running") {
            Log "Already joined this tailnet." "OK"
        } elseif ($TailscaleAuthKey) {
            Log "Joining tailnet with the supplied auth key..."
            & $tsExe up --authkey=$TailscaleAuthKey --hostname="regteches-mediastack" --accept-routes 2>&1 |
                Tee-Object -FilePath (Join-Path $paths.Logs "tailscale.log") | Out-Null
            Log "Tailscale join requested -- check 'tailscale status' if it doesn't show connected shortly." "OK"
        } else {
            Log "No -TailscaleAuthKey supplied. Opening 'tailscale up' now -- approve the login link it prints/opens in your browser to finish joining." "WARN"
            Start-Process -FilePath $tsExe -ArgumentList "up", "--hostname=regteches-mediastack"
        }

        # Reach the stack over the tailnet only (100.64.0.0/10) -- independent of
        # -OpenFirewallPorts, and safer than exposing it to the whole LAN/subnet.
        $allPorts = 9696,8989,7878,8686,8787,6969,8080,8181,8090,8096,5055
        foreach ($p in $allPorts) {
            $ruleName = "REGTeches Media Stack - Tailscale TCP $p"
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $p -RemoteAddress "100.64.0.0/10" -Action Allow | Out-Null
            }
        }
        Log "Firewall opened for the whole stack over your tailnet (100.64.0.0/10 only)." "OK"
    } else {
        Log "tailscale.exe not found after install -- skipping tailnet join and firewall rules." "WARN"
    }
}

# ============================================================
# Dashboard (its own persistent NSSM service, not a background job --
# a Start-Job dies the moment this installer process exits)
# ============================================================

$dashScript = @'
param([string]$Prefix = "http://localhost:8090/", [string]$Root = "REPLACE_ROOT")

$indexPath = Join-Path $Root "dashboard\index.html"
$gettingStartedPath = Join-Path $Root "dashboard\getting-started.html"
$logPath   = Join-Path $Root "logs\dashboard.log"
$statePath = Join-Path $Root "config\state.json"
function DLog($m) { "$(Get-Date -Format s)`t$m" | Add-Content -Path $logPath }

$services = @("REGTMS-Prowlarr","REGTMS-Sonarr","REGTMS-Radarr","REGTMS-Lidarr","REGTMS-Readarr","REGTMS-Whisparr","REGTMS-SABnzbd","REGTMS-qBittorrent","REGTMS-Jellyfin","REGTMS-Seerr")
$ports = @{ "REGTMS-Prowlarr"=9696; "REGTMS-Sonarr"=8989; "REGTMS-Radarr"=7878; "REGTMS-Lidarr"=8686; "REGTMS-Readarr"=8787; "REGTMS-Whisparr"=6969; "REGTMS-SABnzbd"=8080; "REGTMS-qBittorrent"=8181; "REGTMS-Jellyfin"=8096; "REGTMS-Seerr"=5055 }
$arrAppNames = @("Sonarr","Radarr","Lidarr","Readarr","Whisparr")

function Get-StackState {
    if (Test-Path $statePath) {
        try { return (Get-Content $statePath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Write-JsonResponse($response, $data) {
    # ConvertTo-Json collapses a 1-element array to a bare object (a classic
    # PowerShell 5.1 footgun, no -AsArray here) -- force it back into a JSON
    # array so the frontend's .forEach() calls never break on exactly one row.
    $arr = @($data)
    if ($arr.Count -eq 0) {
        $json = "[]"
    } else {
        $json = $arr | ConvertTo-Json -Depth 6 -Compress
        if ($arr.Count -eq 1 -and $json -notmatch '^\[') { $json = "[$json]" }
    }
    $buffer = [Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentType = "application/json"
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
}

function Get-DiskStats {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $total = [int64]$_.Size
        $free = [int64]$_.FreeSpace
        $used = $total - $free
        [pscustomobject]@{
            drive = $_.DeviceID
            label = $(if ($_.VolumeName) { $_.VolumeName } else { "Local Disk" })
            totalBytes = $total
            usedBytes = $used
            freeBytes = $free
            percentUsed = $(if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 })
        }
    }
}

# The HttpListener loop below handles one request at a time, and confirmed
# live: even calls with their own -TimeoutSec (every one already has one)
# can still hang indefinitely instead of honoring it -- reproduced with
# EVERY endpoint wedged at once, including /api/status, which makes zero
# outbound calls, proving one stuck call blocks all others forever (the loop
# never gets back to GetContext()). Per-call timeouts alone aren't
# trustworthy, and a single "run the whole 9-app batch in one background
# runspace with one shared deadline" wrapper isn't enough either -- one slow
# app (not even hung, just slow) can still eat the whole deadline and throw
# away results that already came back fine from the fast ones (Radarr/Sonarr
# et al). So fan every app's own lookup out to its own runspace and collect
# whichever finish inside the shared deadline -- a dead/slow app only ever
# costs its own slot, never blocks or discards anyone else's result.
# $dashboardIss itself is built further down, right after the five
# Get-*Stat functions it captures are actually defined -- Get-Item
# "function:Name" only finds a function once its "function Name {}"
# statement has actually run, so building this any earlier silently
# captured nothing and every dispatched task was a no-op that returned
# instantly with nothing (confirmed live: an empty {} response in under a
# quarter of a second is the signature, not a real, slower empty result).
function Invoke-ParallelWithDeadline {
    # $Tasks: array of @{ Key; Script (scriptblock); Args (array) }. Returns
    # a hashtable of Key -> raw PSDataCollection for whichever tasks finished
    # before the shared deadline; slower ones are stopped and simply absent
    # from the result rather than blocking or failing the rest.
    param([array]$Tasks, [int]$DeadlineSec = 8)
    $jobs = foreach ($t in $Tasks) {
        $ps = [powershell]::Create($dashboardIss)
        [void]$ps.AddScript($t.Script)
        foreach ($a in $t.Args) { [void]$ps.AddArgument($a) }
        [pscustomobject]@{ Key = $t.Key; Ps = $ps; Handle = $ps.BeginInvoke() }
    }
    $deadline = (Get-Date).AddSeconds($DeadlineSec)
    $results = @{}
    foreach ($job in $jobs) {
        $remainingMs = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalMilliseconds)
        if ($job.Handle.AsyncWaitHandle.WaitOne($remainingMs)) {
            try {
                $r = $job.Ps.EndInvoke($job.Handle)
                if ($r -and $r.Count -gt 0) { $results[$job.Key] = $r }
            } catch { DLog "$($job.Key) lookup failed: $($_.Exception.Message)" }
        } else {
            DLog "$($job.Key) lookup exceeded the shared ${DeadlineSec}s deadline -- skipped this cycle, not blocking the rest."
            $job.Ps.Stop() | Out-Null
        }
        $job.Ps.Dispose()
    }
    return $results
}

function Get-RecentActivity {
    $state = Get-StackState
    if (-not $state) { return @() }

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($name in $arrAppNames) {
        $apiKey = $state."$($name)_ApiKey"; $baseUrl = $state."$($name)_BaseUrl"
        if (-not $apiKey) { continue }
        $tasks.Add(@{
            Key = $name
            Args = @($baseUrl, $apiKey, $name)
            Script = {
                param($u, $k, $n)
                $hist = Invoke-RestMethod -Uri "$u/history?pageSize=8&sortKey=date&sortDirection=descending" -Headers @{ "X-Api-Key" = $k } -TimeoutSec 5
                foreach ($rec in $hist.records) {
                    [pscustomobject]@{ app = $n; title = $rec.sourceTitle; event = $rec.eventType; date = $rec.date }
                }
            }
        })
    }
    if ($state.SABnzbd_ApiKey) {
        $tasks.Add(@{
            Key = "SABnzbd"
            Args = @($state.SABnzbd_ApiKey)
            Script = {
                param($k)
                $sabHist = Invoke-RestMethod -Uri "http://localhost:8080/sabnzbd/api?mode=history&limit=8&apikey=$k&output=json" -TimeoutSec 5
                foreach ($rec in $sabHist.history.slots) {
                    [pscustomobject]@{
                        app = "SABnzbd"; title = $rec.name; event = $rec.status
                        date = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$rec.completed)).LocalDateTime.ToString("o")
                    }
                }
            }
        })
    }
    if ($state.QBittorrent_Ready -and $state.AdminUsername) {
        $tasks.Add(@{
            Key = "qBittorrent"
            Args = @($state.AdminUsername, $state.AdminPassword)
            Script = {
                param($u, $p)
                # -UseBasicParsing matters here specifically: this dashboard
                # runs as a LocalSystem service (no desktop session, no
                # initialized IE profile), and Invoke-WebRequest without it
                # uses IE's engine to parse the response -- which doesn't
                # fail under LocalSystem, it hangs indefinitely with no
                # exception and nothing logged. Confirmed as the original
                # cause of a live "stats never load, no error anywhere"
                # report. The shared-deadline fan-out above is what actually
                # keeps that from taking the rest of the dashboard down now.
                Invoke-WebRequest -Uri "http://localhost:8181/api/v2/auth/login" -Method Post -UseBasicParsing `
                    -Body @{ username = $u; password = $p } -SessionVariable qsess -TimeoutSec 5 | Out-Null
                $torrents = Invoke-RestMethod -Uri "http://localhost:8181/api/v2/torrents/info?sort=completion_on&reverse=true&limit=8" -WebSession $qsess -TimeoutSec 5
                foreach ($t in $torrents) {
                    if (-not $t.completion_on -or $t.completion_on -le 0) { continue }
                    [pscustomobject]@{
                        app = "qBittorrent"; title = $t.name; event = "downloaded"
                        date = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$t.completion_on)).LocalDateTime.ToString("o")
                    }
                }
            }
        })
    }

    $raw = Invoke-ParallelWithDeadline -Tasks $tasks -DeadlineSec 8
    $items = foreach ($key in $raw.Keys) { $raw[$key] }
    @($items) | Sort-Object { [datetime]$_.date } -Descending | Select-Object -First 12
}

$script:activityCache = $null
$script:activityCacheAt = [datetime]::MinValue
function Get-RecentActivityCached {
    if ($script:activityCache -and ((Get-Date) - $script:activityCacheAt).TotalSeconds -lt 8) { return $script:activityCache }
    $script:activityCache = @(Get-RecentActivity)
    $script:activityCacheAt = Get-Date
    return $script:activityCache
}

# Every Get-*Stat function below returns a structured [pscustomobject], not
# a pre-formatted string -- the dashboard's cards show individual numbered
# stat tiles (not one line of text), so the frontend needs named fields to
# bind to, not prose it has to already trust the formatting of.
function Get-ArrStat($BaseUrl, $ApiKey, $CountPath) {
    try {
        $headers = @{ "X-Api-Key" = $ApiKey }
        $queue = Invoke-RestMethod -Uri "$BaseUrl/queue?pageSize=1" -Headers $headers -TimeoutSec 3
        $missing = Invoke-RestMethod -Uri "$BaseUrl/wanted/missing?pageSize=1" -Headers $headers -TimeoutSec 3
        # CountPath is the app-specific "list everything" resource (Sonarr's
        # own "series", Radarr's "movie", etc. -- there's no shared
        # cross-app endpoint for this, unlike queue/wanted-missing) -- best
        # effort only, the rest of the card still renders without it.
        $total = $null
        try { $total = @(Invoke-RestMethod -Uri "$BaseUrl/$CountPath" -Headers $headers -TimeoutSec 3).Count } catch {}
        return [pscustomobject]@{ total = $total; missing = $missing.totalRecords; queued = $queue.totalRecords }
    } catch { return $null }
}

function Get-ProwlarrStat($BaseUrl, $ApiKey) {
    try {
        $idx = @(Invoke-RestMethod -Uri "$BaseUrl/indexer" -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 3)
        $enabled = @($idx | Where-Object { $_.enable }).Count
        return [pscustomobject]@{ enabled = $enabled; total = $idx.Count }
    } catch { return $null }
}

function Get-SabStat($ApiKey) {
    try {
        $q = Invoke-RestMethod -Uri "http://localhost:8080/sabnzbd/api?mode=queue&apikey=$ApiKey&output=json" -TimeoutSec 3
        $mbps = [math]::Round([double]$q.queue.kbpersec / 1024, 1)
        return [pscustomobject]@{ mbps = $mbps; queued = [int]$q.queue.noofslots; timeLeft = $q.queue.timeleft }
    } catch { return $null }
}

function Get-QbtStat($State) {
    if (-not $State.QBittorrent_Ready) { return $null }
    try {
        # -UseBasicParsing: see the matching call in Get-RecentActivity above --
        # without it, this hangs forever under the LocalSystem service account
        # instead of throwing, wedging the whole single-threaded dashboard.
        $login = Invoke-WebRequest -Uri "http://localhost:8181/api/v2/auth/login" -Method Post -UseBasicParsing `
            -Body @{ username = $State.AdminUsername; password = $State.AdminPassword } -SessionVariable qsess -TimeoutSec 3
        if ($login.Content -ne "Ok.") { return $null }
        $info = Invoke-RestMethod -Uri "http://localhost:8181/api/v2/transfer/info" -WebSession $qsess -TimeoutSec 3
        $active = @(Invoke-RestMethod -Uri "http://localhost:8181/api/v2/torrents/info?filter=downloading" -WebSession $qsess -TimeoutSec 3)
        return [pscustomobject]@{ downMbps = [math]::Round($info.dl_info_speed / 1MB, 1); upMbps = [math]::Round($info.up_info_speed / 1MB, 1); active = $active.Count }
    } catch { return $null }
}

function Get-JellyfinStat($State) {
    try {
        $authHeader = 'MediaBrowser Client="REGTeches Dashboard", Device="Dashboard", DeviceId="regtms-dashboard", Version="1.0.0"'
        $login = Invoke-RestMethod -Uri "http://localhost:8096/Users/AuthenticateByName" -Method Post -ContentType "application/json" `
            -Headers @{ Authorization = $authHeader } -Body (@{ Username = $State.AdminUsername; Pw = $State.AdminPassword } | ConvertTo-Json) -TimeoutSec 3
        $headers = @{ Authorization = "$authHeader, Token=`"$($login.AccessToken)`"" }
        $sessions = @(Invoke-RestMethod -Uri "http://localhost:8096/Sessions" -Headers $headers -TimeoutSec 3)
        $playing = @($sessions | Where-Object { $_.NowPlayingItem }).Count
        $counts = Invoke-RestMethod -Uri "http://localhost:8096/Items/Counts" -Headers $headers -TimeoutSec 3
        return [pscustomobject]@{ streaming = $playing; movies = $counts.MovieCount; series = $counts.SeriesCount }
    } catch { return $null }
}

function Get-SeerrStat($ApiKey) {
    try {
        $counts = Invoke-RestMethod -Uri "http://localhost:5055/api/v1/request/count" -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 3
        return [pscustomobject]@{ pending = $counts.pending; total = $counts.total; available = $counts.available }
    } catch { return $null }
}

# Not part of the per-app parallel dispatch below -- a local CIM query, not
# a network call, so it runs synchronously in the request handler with its
# own short cache instead.
function Get-HostStats {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $totalMemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedMemPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
        $uptime = (Get-Date) - $os.LastBootUpTime
        return [pscustomobject]@{
            cpuPercent = [math]::Round($cpu, 0)
            memPercent = $usedMemPct
            totalMemGB = $totalMemGB
            uptimeText = "$([int]$uptime.TotalDays)d $($uptime.Hours)h"
        }
    } catch { return $null }
}

# Built here, not earlier -- Get-Item "function:Name" only finds a function
# once its "function Name {}" statement has actually executed, so this has
# to come after all five functions above are defined, or every dispatched
# task in Invoke-ParallelWithDeadline silently captures nothing.
$dashboardIss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fnName in @("Get-ArrStat", "Get-ProwlarrStat", "Get-SabStat", "Get-QbtStat", "Get-JellyfinStat", "Get-SeerrStat")) {
    $dashboardIss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry $fnName, (Get-Item "function:$fnName").ScriptBlock))
}

# Each *arr app's own "list everything" resource -- confirmed from each
# project's own API (no shared endpoint for this like queue/wanted-missing
# have); Whisparr shares Sonarr's shape since it's forked from it.
$arrCountPaths = @{ Sonarr = "series"; Radarr = "movie"; Lidarr = "artist"; Readarr = "author"; Whisparr = "series" }

function Get-AllAppStats {
    $state = Get-StackState
    if (-not $state) { return @{} }

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($name in $arrAppNames) {
        $apiKey = $state."$($name)_ApiKey"; $baseUrl = $state."$($name)_BaseUrl"
        if ($apiKey) { $tasks.Add(@{ Key = $name; Args = @($baseUrl, $apiKey, $arrCountPaths[$name]); Script = { param($u, $k, $c) Get-ArrStat -BaseUrl $u -ApiKey $k -CountPath $c } }) }
    }
    if ($state.Prowlarr_ApiKey) { $tasks.Add(@{ Key = "Prowlarr"; Args = @($state.Prowlarr_BaseUrl, $state.Prowlarr_ApiKey); Script = { param($u, $k) Get-ProwlarrStat -BaseUrl $u -ApiKey $k } }) }
    if ($state.SABnzbd_ApiKey) { $tasks.Add(@{ Key = "SABnzbd"; Args = @($state.SABnzbd_ApiKey); Script = { param($k) Get-SabStat -ApiKey $k } }) }
    if ($state.QBittorrent_Ready) { $tasks.Add(@{ Key = "qBittorrent"; Args = @($state); Script = { param($s) Get-QbtStat -State $s } }) }
    if ($state.AdminUsername) { $tasks.Add(@{ Key = "Jellyfin"; Args = @($state); Script = { param($s) Get-JellyfinStat -State $s } }) }
    if ($state.Seerr_ApiKey) { $tasks.Add(@{ Key = "Seerr"; Args = @($state.Seerr_ApiKey); Script = { param($k) Get-SeerrStat -ApiKey $k } }) }

    $raw = Invoke-ParallelWithDeadline -Tasks $tasks -DeadlineSec 8
    $stats = @{}
    foreach ($key in $raw.Keys) {
        $val = $raw[$key]
        if ($val -and $val.Count -gt 0 -and $null -ne $val[0]) { $stats[$key] = $val[0] }
    }
    return $stats
}

$script:appStatsCache = $null
$script:appStatsCacheAt = [datetime]::MinValue
function Get-AllAppStatsCached {
    if ($script:appStatsCache -and ((Get-Date) - $script:appStatsCacheAt).TotalSeconds -lt 8) { return $script:appStatsCache }
    $script:appStatsCache = Get-AllAppStats
    $script:appStatsCacheAt = Get-Date
    return $script:appStatsCache
}

$script:hostStatsCache = $null
$script:hostStatsCacheAt = [datetime]::MinValue
function Get-HostStatsCached {
    if ($script:hostStatsCache -and ((Get-Date) - $script:hostStatsCacheAt).TotalSeconds -lt 8) { return $script:hostStatsCache }
    $script:hostStatsCache = Get-HostStats
    $script:hostStatsCacheAt = Get-Date
    return $script:hostStatsCache
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
DLog "Dashboard listening on $Prefix"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath

        if ($path -eq "/api/status") {
            $status = foreach ($svc in $services) {
                if (@("REGTMS-qBittorrent", "REGTMS-SABnzbd", "REGTMS-Jellyfin") -contains $svc) {
                    # All three run as logon Scheduled Tasks, not Windows
                    # services (see install log) -- check by whether they're
                    # actually listening instead of a service that no longer exists.
                    $isUp = [bool](Get-NetTCPConnection -LocalPort $ports[$svc] -State Listen -ErrorAction SilentlyContinue)
                    [pscustomobject]@{ name = $svc; running = $isUp; port = $ports[$svc] }
                } else {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    [pscustomobject]@{ name = $svc; running = ($s -and $s.Status -eq "Running"); port = $ports[$svc] }
                }
            }
            Write-JsonResponse $response $status
        } elseif ($path -eq "/api/disks") {
            Write-JsonResponse $response @(Get-DiskStats)
        } elseif ($path -eq "/api/activity") {
            Write-JsonResponse $response @(Get-RecentActivityCached)
        } elseif ($path -eq "/api/appstats") {
            $json = (Get-AllAppStatsCached) | ConvertTo-Json -Depth 4 -Compress
            if ($json -eq "" -or $null -eq $json) { $json = "{}" }
            $buffer = [Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        } elseif ($path -eq "/api/hoststats") {
            $json = (Get-HostStatsCached) | ConvertTo-Json -Depth 3 -Compress
            if ($json -eq "" -or $null -eq $json) { $json = "{}" }
            $buffer = [Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        } elseif ($path -eq "/getting-started") {
            $html = Get-Content -Path $gettingStartedPath -Raw
            $buffer = [Text.Encoding]::UTF8.GetBytes($html)
            $response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")
            $response.ContentType = "text/html; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        } else {
            $html = Get-Content -Path $indexPath -Raw
            $buffer = [Text.Encoding]::UTF8.GetBytes($html)
            # No Cache-Control meant browsers were free to keep serving an old
            # cached copy of this page indefinitely -- exactly the kind of
            # "dashboard shows something that doesn't match the actual source"
            # report we've hit more than once. This page is generated fresh by
            # the installer every run and is cheap to re-fetch, so just tell
            # the browser never to cache it.
            $response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")
            $response.ContentType = "text/html; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        $response.OutputStream.Close()
    } catch { DLog "Request error: $($_.Exception.Message)" }
}
'@
$dashScript = $dashScript.Replace("REPLACE_ROOT", $InstallRoot)
$dashScriptPath = Join-Path $paths.Dashboard "Dashboard-Server.ps1"
$dashScript | Set-Content -Path $dashScriptPath -Encoding UTF8

$indexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>REGTeches Media Stack</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg:#0a0d14; --panel-solid:#131826; --panel-hover:#171d2d;
      --line:#222939; --line-soft:#1a2030;
      --ink:#e7ebf5; --ink-dim:#8791a8; --ink-faint:#5b6478;
      --accent:#7c6cf6; --accent-soft:#7c6cf61a; --accent-glow:#7c6cf655; --accent2:#2dd4e8;
      --good:#33d69f; --good-soft:#33d69f1a;
      --warn:#f5b942; --warn-soft:#f5b9421a;
      --bad:#f9576b; --bad-soft:#f9576b1a;
      --radius:14px; --mono:'JetBrains Mono',ui-monospace,Consolas,monospace; --sans:'Inter',system-ui,-apple-system,sans-serif;
    }
    * { box-sizing:border-box; }
    html,body { margin:0; }
    body {
      background:
        radial-gradient(1200px 500px at 15% -10%, #1c1440 0%, transparent 60%),
        radial-gradient(900px 500px at 100% 0%, #0a2a3a 0%, transparent 55%),
        var(--bg);
      color:var(--ink); font-family:var(--sans); min-height:100vh;
    }
    a { color:inherit; }
    header {
      padding:20px 32px; display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:16px;
      border-bottom:1px solid var(--line-soft); position:sticky; top:0; z-index:10;
      background:#0a0d14cc; backdrop-filter:blur(10px);
    }
    .brand { display:flex; align-items:center; gap:12px; }
    .brand-mark {
      width:38px; height:38px; border-radius:10px; flex:none;
      background:linear-gradient(145deg, var(--accent), var(--accent2));
      display:flex; align-items:center; justify-content:center;
      font-family:var(--mono); font-weight:700; font-size:15px; color:#0a0d14;
      box-shadow:0 0 24px var(--accent-glow);
    }
    .brand h1 { margin:0; font-size:18px; font-weight:700; letter-spacing:-.01em; }
    .brand .sub { font-size:11.5px; color:var(--ink-faint); font-family:var(--mono); margin-top:1px; }
    .header-right { display:flex; align-items:center; gap:22px; }
    .guide-link {
      font-family:var(--mono); font-size:12px; font-weight:600; letter-spacing:.03em; color:var(--ink-dim);
      text-decoration:none; padding:7px 12px; border:1px solid var(--line); border-radius:8px; transition:color .15s ease, border-color .15s ease;
    }
    .guide-link:hover { color:var(--accent2); border-color:#333d52; }
    .clock { text-align:right; }
    .clock .time { font-family:var(--mono); font-size:15px; font-weight:600; font-variant-numeric:tabular-nums; }
    .clock .date { font-size:11px; color:var(--ink-dim); }
    .health-chip {
      display:flex; align-items:center; gap:8px; padding:7px 14px; border-radius:999px;
      background:var(--good-soft); border:1px solid #33d69f33;
      font-family:var(--mono); font-size:12.5px; font-weight:600; color:var(--good);
    }
    .health-chip.warn { background:var(--warn-soft); border-color:#f5b94233; color:var(--warn); }
    .health-chip .pulse-dot { width:7px; height:7px; border-radius:50%; background:currentColor; box-shadow:0 0 8px currentColor; animation:pulse 2s ease-in-out infinite; }
    @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
    main { max-width:1360px; margin:0 auto; padding:28px 32px 50px; }
    .section { margin-bottom:34px; }
    .section-head { display:flex; align-items:center; gap:10px; margin-bottom:14px; }
    .section-head .ico { font-size:8px; color:var(--accent); }
    .section-head h2 { margin:0; font-size:12px; font-weight:700; letter-spacing:.14em; text-transform:uppercase; color:var(--ink-dim); font-family:var(--mono); }
    .section-head .rule { flex:1; height:1px; background:linear-gradient(90deg, var(--line), transparent); }
    .grid { display:grid; gap:14px; grid-template-columns:repeat(auto-fill, minmax(250px, 1fr)); }
    .card {
      background:var(--panel-solid); border:1px solid var(--line); border-radius:var(--radius);
      padding:18px 20px; position:relative; overflow:hidden;
      transition:border-color .18s ease, transform .18s ease, box-shadow .18s ease;
      text-decoration:none; color:inherit; display:block;
    }
    .card::before { content:''; position:absolute; inset:0 0 auto 0; height:2px; background:linear-gradient(90deg, var(--card-accent, var(--accent)), transparent); opacity:.8; }
    .card:hover { border-color:#333d52; transform:translateY(-2px); box-shadow:0 10px 30px -12px #000a; background:var(--panel-hover); }
    .card-top { display:flex; align-items:flex-start; justify-content:space-between; gap:10px; margin-bottom:14px; }
    .card-id { display:flex; align-items:center; gap:11px; min-width:0; }
    .card-icon {
      width:34px; height:34px; border-radius:9px; flex:none; display:flex; align-items:center; justify-content:center;
      font-family:var(--mono); font-weight:700; font-size:13px;
      background:var(--icon-bg, var(--accent-soft)); color:var(--icon-fg, var(--accent));
    }
    .card-name { min-width:0; }
    .card-name .n { font-size:14.5px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .card-name .t { font-size:11px; color:var(--ink-faint); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .status { display:flex; align-items:center; gap:6px; flex:none; }
    .status .dot { width:8px; height:8px; border-radius:50%; background:var(--ink-faint); }
    .status.up .dot { background:var(--good); box-shadow:0 0 7px var(--good); }
    .status.down .dot { background:var(--bad); box-shadow:0 0 7px var(--bad); }
    .stat-row { display:grid; gap:8px; grid-template-columns:repeat(var(--cols,3),1fr); }
    .stat { background:#0000002e; border:1px solid var(--line-soft); border-radius:9px; padding:9px 10px; }
    .stat .v { font-family:var(--mono); font-size:16px; font-weight:700; font-variant-numeric:tabular-nums; line-height:1.15; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .stat .v .u { font-size:11px; font-weight:500; color:var(--ink-dim); margin-left:2px; }
    .stat .l { font-size:9.5px; letter-spacing:.06em; text-transform:uppercase; color:var(--ink-faint); margin-top:3px; font-weight:600; }
    .stat.accent-warn .v { color:var(--warn); }
    .stat.accent-good .v { color:var(--good); }
    .stat.accent-bad .v { color:var(--bad); }
    .mini-note { margin-top:12px; font-size:11.5px; color:var(--ink-faint); font-family:var(--mono); }
    .gauge-wrap { display:flex; align-items:center; gap:10px; }
    .gauge { position:relative; width:52px; height:52px; flex:none; }
    .gauge svg { transform:rotate(-90deg); }
    .gauge circle { fill:none; stroke-width:5; }
    .gauge .track { stroke:var(--line-soft); }
    .gauge .val { stroke:var(--gauge-color, var(--accent)); stroke-linecap:round; transition:stroke-dashoffset .6s ease; }
    .gauge .pct { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; font-family:var(--mono); font-size:12px; font-weight:700; }
    .gauge-label { font-size:11px; color:var(--ink-dim); font-family:var(--mono); }
    .panel { background:var(--panel-solid); border:1px solid var(--line); border-radius:var(--radius); padding:20px 22px; }
    .cols-2-panel { display:grid; grid-template-columns:1.1fr 1.4fr; gap:16px; }
    @media (max-width:860px) { .cols-2-panel { grid-template-columns:1fr; } }
    .disk-row + .disk-row { margin-top:16px; }
    .disk-head { display:flex; align-items:baseline; gap:8px; margin-bottom:7px; font-size:13px; }
    .disk-letter { font-family:var(--mono); font-weight:700; }
    .disk-label { color:var(--ink-dim); flex:1; }
    .disk-figures { font-family:var(--mono); font-size:11.5px; color:var(--ink-faint); font-variant-numeric:tabular-nums; }
    .disk-track { height:7px; border-radius:4px; background:var(--line-soft); overflow:hidden; }
    .disk-fill { height:100%; border-radius:4px; background:linear-gradient(90deg, var(--good), #22d3ee); transition:width .4s ease; }
    .disk-fill.warn { background:linear-gradient(90deg, var(--warn), #f97316); }
    .disk-fill.bad { background:linear-gradient(90deg, var(--bad), #ef4444); }
    .empty { color:var(--ink-faint); font-size:13px; padding:6px 0; }
    .activity-row { display:grid; grid-template-columns:88px 1fr auto auto; gap:12px; align-items:center; padding:9px 0; border-bottom:1px solid var(--line-soft); font-size:13px; }
    .activity-row:last-child { border-bottom:none; }
    .app-badge { font-family:var(--mono); font-size:10px; letter-spacing:.05em; color:var(--accent2); text-transform:uppercase; font-weight:700; }
    .activity-title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .ev-badge { font-size:10px; padding:3px 8px; border-radius:5px; font-family:var(--mono); font-weight:600; white-space:nowrap; }
    .ev-ok { background:var(--good-soft); color:var(--good); }
    .ev-grab { background:var(--accent-soft); color:var(--accent2); }
    .ev-bad { background:var(--bad-soft); color:var(--bad); }
    .activity-time { color:var(--ink-faint); font-size:11px; font-family:var(--mono); white-space:nowrap; }
    .footer { text-align:center; padding:26px; font-size:11.5px; color:var(--ink-faint); font-family:var(--mono); }
  </style>
</head>
<body>

  <header>
    <div class="brand">
      <div class="brand-mark">RT</div>
      <div>
        <h1>REGTeches Media Stack</h1>
        <div class="sub">Developed by Ronald Goodchild &middot; Windows-native, no Docker</div>
      </div>
    </div>
    <div class="header-right">
      <a class="guide-link" href="/getting-started">Getting Started Guide</a>
      <div class="health-chip" id="healthChip"><span class="pulse-dot"></span><span id="healthText">Checking&hellip;</span></div>
      <div class="clock"><div class="time" id="clockTime"></div><div class="date" id="clockDate"></div></div>
    </div>
  </header>

  <main>

    <div class="section">
      <div class="section-head"><span class="ico">&#9679;</span><h2>System</h2><span class="rule"></span></div>
      <div class="grid">
        <div class="card" style="--card-accent:#7c6cf6">
          <div class="card-top">
            <div class="card-id">
              <div class="card-icon" style="--icon-bg:#7c6cf61a;--icon-fg:#a99bff">OS</div>
              <div class="card-name"><div class="n">Host</div><div class="t">This machine</div></div>
            </div>
            <div class="status" data-service="__host__"><span class="dot"></span></div>
          </div>
          <div class="gauge-wrap">
            <div class="gauge"><svg width="52" height="52" viewBox="0 0 56 56"><circle class="track" cx="28" cy="28" r="23"></circle><circle class="val" id="cpuGaugeCircle" cx="28" cy="28" r="23" stroke-dasharray="144.5" stroke-dashoffset="144.5"></circle></svg><div class="pct" id="cpuPct">&ndash;</div></div>
            <div class="gauge-label">CPU</div>
            <div class="gauge"><svg width="52" height="52" viewBox="0 0 56 56"><circle class="track" cx="28" cy="28" r="23"></circle><circle class="val" id="memGaugeCircle" cx="28" cy="28" r="23" stroke-dasharray="144.5" stroke-dashoffset="144.5"></circle></svg><div class="pct" id="memPct">&ndash;</div></div>
            <div class="gauge-label">RAM</div>
          </div>
          <div class="mini-note" id="hostUptimeNote">&nbsp;</div>
        </div>

        <a class="card" style="--card-accent:#f5b942" href="http://localhost:9696" target="_blank" rel="noopener">
          <div class="card-top">
            <div class="card-id"><div class="card-icon" style="--icon-bg:#f5b9421a;--icon-fg:#f5b942">PR</div>
              <div class="card-name"><div class="n">Prowlarr</div><div class="t">Indexer manager</div></div></div>
            <div class="status" data-service="REGTMS-Prowlarr"><span class="dot"></span></div>
          </div>
          <div class="stat-row" style="--cols:2">
            <div class="stat" data-app="Prowlarr" data-field="enabled"><div class="v">&ndash;</div><div class="l">Enabled</div></div>
            <div class="stat" data-app="Prowlarr" data-field="total"><div class="v">&ndash;</div><div class="l">Indexers</div></div>
          </div>
        </a>
      </div>
    </div>

    <div class="section">
      <div class="section-head"><span class="ico">&#9679;</span><h2>Media &amp; Requests</h2><span class="rule"></span></div>
      <div class="grid">
        <a class="card" style="--card-accent:#8a5cf6" href="http://localhost:8096" target="_blank" rel="noopener">
          <div class="card-top">
            <div class="card-id"><div class="card-icon" style="--icon-bg:#8a5cf61a;--icon-fg:#b79dff">JF</div>
              <div class="card-name"><div class="n">Jellyfin</div><div class="t">Media server</div></div></div>
            <div class="status" data-service="REGTMS-Jellyfin"><span class="dot"></span></div>
          </div>
          <div class="stat-row" style="--cols:3">
            <div class="stat accent-good" data-app="Jellyfin" data-field="streaming"><div class="v">&ndash;</div><div class="l">Streaming</div></div>
            <div class="stat" data-app="Jellyfin" data-field="movies"><div class="v">&ndash;</div><div class="l">Movies</div></div>
            <div class="stat" data-app="Jellyfin" data-field="series"><div class="v">&ndash;</div><div class="l">TV shows</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#f97362" href="http://localhost:5055" target="_blank" rel="noopener">
          <div class="card-top">
            <div class="card-id"><div class="card-icon" style="--icon-bg:#f973621a;--icon-fg:#f97362">SR</div>
              <div class="card-name"><div class="n">Seerr</div><div class="t">Request management</div></div></div>
            <div class="status" data-service="REGTMS-Seerr"><span class="dot"></span></div>
          </div>
          <div class="stat-row" style="--cols:3">
            <div class="stat accent-warn" data-app="Seerr" data-field="pending"><div class="v">&ndash;</div><div class="l">Pending</div></div>
            <div class="stat" data-app="Seerr" data-field="total"><div class="v">&ndash;</div><div class="l">Total</div></div>
            <div class="stat accent-good" data-app="Seerr" data-field="available"><div class="v">&ndash;</div><div class="l">Available</div></div>
          </div>
        </a>
      </div>
    </div>

    <div class="section">
      <div class="section-head"><span class="ico">&#9679;</span><h2>Automation</h2><span class="rule"></span></div>
      <div class="grid">
        <a class="card" style="--card-accent:#2dd4e8" href="http://localhost:8989" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#2dd4e81a;--icon-fg:#2dd4e8">SO</div>
            <div class="card-name"><div class="n">Sonarr</div><div class="t">TV series</div></div></div>
            <div class="status" data-service="REGTMS-Sonarr"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat" data-app="Sonarr" data-field="total"><div class="v">&ndash;</div><div class="l">Series</div></div>
            <div class="stat accent-warn" data-app="Sonarr" data-field="missing"><div class="v">&ndash;</div><div class="l">Missing</div></div>
            <div class="stat accent-good" data-app="Sonarr" data-field="queued"><div class="v">&ndash;</div><div class="l">Queued</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#ffb454" href="http://localhost:7878" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#ffb4541a;--icon-fg:#ffb454">RA</div>
            <div class="card-name"><div class="n">Radarr</div><div class="t">Movies</div></div></div>
            <div class="status" data-service="REGTMS-Radarr"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat" data-app="Radarr" data-field="total"><div class="v">&ndash;</div><div class="l">Movies</div></div>
            <div class="stat accent-warn" data-app="Radarr" data-field="missing"><div class="v">&ndash;</div><div class="l">Missing</div></div>
            <div class="stat accent-good" data-app="Radarr" data-field="queued"><div class="v">&ndash;</div><div class="l">Queued</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#33d69f" href="http://localhost:8686" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#33d69f1a;--icon-fg:#33d69f">LI</div>
            <div class="card-name"><div class="n">Lidarr</div><div class="t">Music</div></div></div>
            <div class="status" data-service="REGTMS-Lidarr"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat" data-app="Lidarr" data-field="total"><div class="v">&ndash;</div><div class="l">Artists</div></div>
            <div class="stat accent-warn" data-app="Lidarr" data-field="missing"><div class="v">&ndash;</div><div class="l">Wanted</div></div>
            <div class="stat accent-good" data-app="Lidarr" data-field="queued"><div class="v">&ndash;</div><div class="l">Queued</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#f9576b" href="http://localhost:8787" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#f9576b1a;--icon-fg:#f9576b">RE</div>
            <div class="card-name"><div class="n">Readarr</div><div class="t">Books</div></div></div>
            <div class="status" data-service="REGTMS-Readarr"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat" data-app="Readarr" data-field="total"><div class="v">&ndash;</div><div class="l">Authors</div></div>
            <div class="stat accent-warn" data-app="Readarr" data-field="missing"><div class="v">&ndash;</div><div class="l">Wanted</div></div>
            <div class="stat accent-good" data-app="Readarr" data-field="queued"><div class="v">&ndash;</div><div class="l">Queued</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#7c6cf6" href="http://localhost:6969" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#7c6cf61a;--icon-fg:#a99bff">WH</div>
            <div class="card-name"><div class="n">Whisparr</div><div class="t">Adult</div></div></div>
            <div class="status" data-service="REGTMS-Whisparr"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat" data-app="Whisparr" data-field="total"><div class="v">&ndash;</div><div class="l">Series</div></div>
            <div class="stat accent-warn" data-app="Whisparr" data-field="missing"><div class="v">&ndash;</div><div class="l">Missing</div></div>
            <div class="stat accent-good" data-app="Whisparr" data-field="queued"><div class="v">&ndash;</div><div class="l">Queued</div></div>
          </div>
        </a>
      </div>
    </div>

    <div class="section">
      <div class="section-head"><span class="ico">&#9679;</span><h2>Downloads</h2><span class="rule"></span></div>
      <div class="grid">
        <a class="card" style="--card-accent:#33d69f" href="http://localhost:8080" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#33d69f1a;--icon-fg:#33d69f">SA</div>
            <div class="card-name"><div class="n">SABnzbd</div><div class="t">Usenet</div></div></div>
            <div class="status" data-service="REGTMS-SABnzbd"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat accent-good" data-app="SABnzbd" data-field="mbps" data-unit="MB/s"><div class="v">&ndash;</div><div class="l">Rate</div></div>
            <div class="stat" data-app="SABnzbd" data-field="queued"><div class="v">&ndash;</div><div class="l">Queue</div></div>
            <div class="stat" data-app="SABnzbd" data-field="timeLeft"><div class="v">&ndash;</div><div class="l">Left</div></div>
          </div>
        </a>
        <a class="card" style="--card-accent:#2dd4e8" href="http://localhost:8181" target="_blank" rel="noopener">
          <div class="card-top"><div class="card-id"><div class="card-icon" style="--icon-bg:#2dd4e81a;--icon-fg:#2dd4e8">QB</div>
            <div class="card-name"><div class="n">qBittorrent</div><div class="t">Torrents</div></div></div>
            <div class="status" data-service="REGTMS-qBittorrent"><span class="dot"></span></div></div>
          <div class="stat-row" style="--cols:3">
            <div class="stat accent-good" data-app="qBittorrent" data-field="downMbps" data-unit="MB/s"><div class="v">&ndash;</div><div class="l">Down</div></div>
            <div class="stat" data-app="qBittorrent" data-field="upMbps" data-unit="MB/s"><div class="v">&ndash;</div><div class="l">Up</div></div>
            <div class="stat" data-app="qBittorrent" data-field="active"><div class="v">&ndash;</div><div class="l">Active</div></div>
          </div>
        </a>
      </div>
    </div>

    <div class="cols-2-panel">
      <div class="panel">
        <div class="section-head" style="margin-bottom:16px;"><span class="ico">&#9679;</span><h2>Storage</h2><span class="rule"></span></div>
        <div id="disks" class="empty">Loading&hellip;</div>
      </div>
      <div class="panel">
        <div class="section-head" style="margin-bottom:12px;"><span class="ico">&#9679;</span><h2>Recent Activity</h2><span class="rule"></span></div>
        <div id="activity" class="empty">Loading&hellip;</div>
      </div>
    </div>

  </main>

  <div class="footer">REGTeches Media Stack &bull; Technician-grade Windows media automation</div>

  <script>
    function formatBytes(bytes) {
      if (!bytes || bytes <= 0) return '0 B';
      var units = ['B','KB','MB','GB','TB','PB'];
      var i = Math.floor(Math.log(bytes) / Math.log(1024));
      var val = bytes / Math.pow(1024, i);
      return val.toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
    }

    function timeAgo(dateStr) {
      var then = new Date(dateStr).getTime();
      if (isNaN(then)) return '';
      var diff = Math.max(0, Math.floor((Date.now() - then) / 1000));
      if (diff < 60) return diff + 's ago';
      if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
      if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
      return Math.floor(diff / 86400) + 'd ago';
    }

    function diskColor(pct) {
      if (pct >= 90) return 'var(--bad)';
      if (pct >= 75) return 'var(--warn)';
      return 'var(--good)';
    }

    var eventLabels = { grabbed:'Grabbed', downloadFolderImported:'Imported', episodeFileImported:'Imported', movieFileImported:'Imported', trackImported:'Imported', bookImported:'Imported', downloadFailed:'Failed', Completed:'Completed', Failed:'Failed', downloaded:'Downloaded' };
    function eventLabel(ev) { return eventLabels[ev] || ev; }
    function eventClass(ev) {
      var s = (ev || '').toLowerCase();
      if (s.indexOf('fail') !== -1) return 'ev-bad';
      if (s.indexOf('grab') !== -1) return 'ev-grab';
      return 'ev-ok';
    }
    function escapeHtml(s) { var d = document.createElement('div'); d.innerText = s; return d.innerHTML; }

    function tickClock() {
      var now = new Date();
      document.getElementById('clockTime').textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
      document.getElementById('clockDate').textContent = now.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
    }

    function loadStatus() {
      fetch('/api/status').then(function (r) { return r.json(); }).then(function (list) {
        var downCount = 0;
        list.forEach(function (s) {
          var el = document.querySelector('.status[data-service="' + s.name + '"]');
          if (!el) return;
          el.classList.toggle('up', !!s.running);
          el.classList.toggle('down', !s.running);
          if (!s.running) downCount++;
        });
        var chip = document.getElementById('healthChip');
        var text = document.getElementById('healthText');
        if (downCount === 0) {
          chip.classList.remove('warn');
          text.textContent = 'All systems normal';
        } else {
          chip.classList.add('warn');
          text.textContent = downCount + ' service' + (downCount === 1 ? '' : 's') + ' down';
        }
      }).catch(function () {});
    }

    var hostStatus = document.querySelector('.status[data-service="__host__"]');
    if (hostStatus) hostStatus.classList.add('up');

    var GAUGE_CIRC = 144.5;
    function setGauge(circleId, pctElId, pct) {
      var circle = document.getElementById(circleId);
      var pctEl = document.getElementById(pctElId);
      if (pct === null || pct === undefined || isNaN(pct)) {
        pctEl.textContent = '–';
        return;
      }
      pct = Math.max(0, Math.min(100, pct));
      circle.style.strokeDashoffset = GAUGE_CIRC * (1 - pct / 100);
      circle.style.setProperty('--gauge-color', pct >= 90 ? 'var(--bad)' : (pct >= 75 ? 'var(--warn)' : 'var(--accent)'));
      pctEl.textContent = Math.round(pct) + '%';
    }

    function loadHostStats() {
      fetch('/api/hoststats').then(function (r) { return r.json(); }).then(function (h) {
        if (!h) return;
        setGauge('cpuGaugeCircle', 'cpuPct', h.cpuPercent);
        setGauge('memGaugeCircle', 'memPct', h.memPercent);
        var note = document.getElementById('hostUptimeNote');
        if (note) note.textContent = (h.uptimeText ? 'Up ' + h.uptimeText : ' ') + (h.totalMemGB ? ' · ' + h.totalMemGB + ' GB RAM' : '');
      }).catch(function () {});
    }

    function loadDisks() {
      fetch('/api/disks').then(function (r) { return r.json(); }).then(function (disks) {
        var el = document.getElementById('disks');
        if (!disks || disks.length === 0) { el.className = 'empty'; el.innerHTML = 'No fixed drives found.'; return; }
        el.className = '';
        el.innerHTML = disks.map(function (d) {
          return '<div class="disk-row">' +
            '<div class="disk-head"><span class="disk-letter">' + d.drive + '</span>' +
            '<span class="disk-label">' + escapeHtml(d.label) + '</span>' +
            '<span class="disk-figures">' + formatBytes(d.usedBytes) + ' / ' + formatBytes(d.totalBytes) + ' (' + d.percentUsed + '%)</span></div>' +
            '<div class="disk-track"><div class="disk-fill" style="width:' + d.percentUsed + '%;background:' + diskColor(d.percentUsed) + '"></div></div>' +
            '</div>';
        }).join('');
      }).catch(function () {});
    }

    function loadActivity() {
      fetch('/api/activity').then(function (r) { return r.json(); }).then(function (items) {
        var el = document.getElementById('activity');
        if (!items || items.length === 0) { el.className = 'empty'; el.innerHTML = 'Nothing downloaded yet.'; return; }
        el.className = '';
        el.innerHTML = items.map(function (it) {
          var title = escapeHtml(it.title || '');
          return '<div class="activity-row">' +
            '<span class="app-badge">' + escapeHtml(it.app) + '</span>' +
            '<span class="activity-title" title="' + title + '">' + title + '</span>' +
            '<span class="ev-badge ' + eventClass(it.event) + '">' + escapeHtml(eventLabel(it.event)) + '</span>' +
            '<span class="activity-time">' + timeAgo(it.date) + '</span>' +
            '</div>';
        }).join('');
      }).catch(function () {});
    }

    function loadAppStats() {
      fetch('/api/appstats').then(function (r) { return r.json(); }).then(function (stats) {
        document.querySelectorAll('.stat[data-app]').forEach(function (el) {
          var app = el.getAttribute('data-app');
          var field = el.getAttribute('data-field');
          var unit = el.getAttribute('data-unit');
          var appStats = stats[app];
          var val = appStats ? appStats[field] : null;
          var vEl = el.querySelector('.v');
          if (val === null || val === undefined || val === '') {
            vEl.innerHTML = '&ndash;';
          } else {
            vEl.innerHTML = escapeHtml(String(val)) + (unit ? ' <span class="u">' + escapeHtml(unit) + '</span>' : '');
          }
        });
      }).catch(function () {});
    }

    tickClock(); loadStatus(); loadDisks(); loadActivity(); loadAppStats(); loadHostStats();
    setInterval(tickClock, 1000);
    setInterval(loadStatus, 15000);
    setInterval(loadDisks, 30000);
    setInterval(loadActivity, 20000);
    setInterval(loadAppStats, 20000);
    setInterval(loadHostStats, 10000);
  </script>
</body>
</html>
'@
$indexHtml | Set-Content -Path (Join-Path $paths.Dashboard "index.html") -Encoding UTF8

# ============================================================
# "Getting Started" guide -- opens automatically once the installer
# finishes. Covers the things every fresh install still needs a human
# decision on: a VPN for torrent traffic, a Usenet provider for
# SABnzbd, optionally spreading libraries across other drives, and
# reaching Jellyfin from a TV/phone/tablet instead of just this PC.
# None of this can be auto-wired the way the apps themselves are --
# it all depends on accounts/hardware/network only the user has.
# ============================================================

# Best-effort LAN IPv4 for this PC -- lets the guide print a real,
# clickable "http://<ip>:8096" instead of telling people to go run
# ipconfig themselves. Falls back to plain instructions if detection
# comes up empty (e.g. no active network route yet).
function Get-LanIPv4Address {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne "0.0.0.0" } | Sort-Object -Property RouteMetric | Select-Object -First 1
        if ($route) {
            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1
            if ($ip) { return $ip.IPAddress }
        }
    } catch {}
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch {}
    return $null
}
$lanIp = Get-LanIPv4Address
$lanAddrText = if ($lanIp) { "http://$($lanIp):8096" } else { "this PC's LAN IP address (run <code>ipconfig</code> here and look for &ldquo;IPv4 Address&rdquo;), followed by <code>:8096</code>" }

$firewallCallout = if ($OpenFirewallPorts) { @"
      <div class="callout good">
        <span class="lbl">Firewall &mdash; already open</span>
        This install already opened Windows Firewall for every app's port (<code>-OpenFirewallPorts</code> was used), so other devices on this network can already reach Jellyfin &mdash; no extra step needed.
      </div>
"@ } else { @"
      <div class="callout">
        <span class="lbl">Firewall &mdash; not open yet</span>
        By default this install only listens on this PC itself. Either re-run the installer with <code>-OpenFirewallPorts</code> to open every app's port to your home network, or allow just Jellyfin: <strong>Windows Security &rarr; Firewall &amp; network protection &rarr; Advanced settings &rarr; Inbound Rules &rarr; New Rule &rarr; Port &rarr; TCP 8096 &rarr; Allow</strong>.
      </div>
"@ }

$remoteCallout = if (-not $SkipTailscale) { @"
      <div class="callout tip">
        <span class="lbl">Away from home</span>
        Tailscale is already installed and joined on this PC. Install the Tailscale app on your phone or another device, sign into the same tailnet, then use this PC's tailnet address instead of the one above (check the Tailscale admin console, or run <code>tailscale ip -4</code> on this PC) &mdash; works from anywhere, no port-forwarding or public exposure required.
      </div>
"@ } else { @"
      <div class="callout">
        <span class="lbl">Away from home</span>
        Tailscale wasn't installed this run (<code>-SkipTailscale</code> was used) &mdash; it's the easiest safe way to reach Jellyfin outside your home network without exposing anything to the public internet. Re-run the installer without that flag, or install Tailscale yourself and add this PC and your phone to the same tailnet.
      </div>
"@ }

$welcomeHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Getting Started &mdash; REGTeches Media Stack</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg:#0a0d14; --panel-solid:#131826; --panel-hover:#171d2d;
      --line:#222939; --line-soft:#1a2030;
      --ink:#e7ebf5; --ink-dim:#8791a8; --ink-faint:#5b6478;
      --accent:#7c6cf6; --accent-soft:#7c6cf61a; --accent-glow:#7c6cf655; --accent2:#2dd4e8;
      --good:#33d69f; --good-soft:#33d69f1a;
      --warn:#f5b942; --warn-soft:#f5b9421a;
      --bad:#f9576b; --bad-soft:#f9576b1a;
      --radius:14px; --mono:'JetBrains Mono',ui-monospace,Consolas,monospace; --sans:'Inter',system-ui,-apple-system,sans-serif;
    }
    * { box-sizing:border-box; }
    html,body { margin:0; }
    body {
      background:
        radial-gradient(1200px 500px at 15% -10%, #1c1440 0%, transparent 60%),
        radial-gradient(900px 500px at 100% 0%, #0a2a3a 0%, transparent 55%),
        var(--bg);
      color:var(--ink); font-family:var(--sans); min-height:100vh; line-height:1.6;
    }
    a { color:inherit; }
    header {
      padding:20px 32px; display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:16px;
      border-bottom:1px solid var(--line-soft); position:sticky; top:0; z-index:10;
      background:#0a0d14cc; backdrop-filter:blur(10px);
    }
    .brand { display:flex; align-items:center; gap:12px; }
    .brand-mark {
      width:38px; height:38px; border-radius:10px; flex:none;
      background:linear-gradient(145deg, var(--accent), var(--accent2));
      display:flex; align-items:center; justify-content:center;
      font-family:var(--mono); font-weight:700; font-size:15px; color:#0a0d14;
      box-shadow:0 0 24px var(--accent-glow);
    }
    header h1 { margin:0; font-size:17px; font-weight:700; letter-spacing:-.01em; }
    header .sub { font-size:11.5px; color:var(--ink-faint); font-family:var(--mono); margin-top:1px; }
    .dash-link {
      font-family:var(--mono); font-size:12.5px; font-weight:600; color:#0a0d14;
      background:linear-gradient(120deg, var(--accent), var(--accent2));
      text-decoration:none; padding:9px 16px; border-radius:8px;
    }
    main { max-width:900px; margin:0 auto; padding:40px 28px 70px; }
    .lede {
      font-size:15px; color:var(--ink-dim); background:var(--panel-solid); border:1px solid var(--line);
      border-radius:var(--radius); padding:18px 22px; margin-bottom:44px;
    }
    .lede strong { color:var(--ink); }
    h1.page-title { font-size:clamp(30px,5vw,42px); font-weight:800; margin:0 0 10px; text-wrap:balance; }
    .page-sub { color:var(--ink-dim); font-size:16px; margin:0 0 8px; max-width:64ch; }

    section.topic { padding:44px 0; border-top:1px solid var(--line-soft); }
    section.topic:first-of-type { border-top:none; }
    .topic-kicker { font-family:var(--mono); font-size:12px; letter-spacing:.12em; color:var(--accent2); margin:0 0 8px; }
    .topic h2 { font-size:clamp(22px,3.4vw,28px); font-weight:700; margin:0 0 14px; }
    .topic > p { color:var(--ink-dim); font-size:15px; max-width:70ch; margin:0 0 22px; }

    .provider-grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill, minmax(220px,1fr)); margin-bottom:20px; }
    .provider {
      background:var(--panel-solid); border:1px solid var(--line); border-radius:12px; padding:16px 18px;
      display:flex; flex-direction:column; gap:6px; position:relative; overflow:hidden;
    }
    .provider::before { content:''; position:absolute; inset:0 0 auto 0; height:2px; background:linear-gradient(90deg, var(--card-accent, var(--accent)), transparent); opacity:.85; }
    .provider .name { font-weight:700; font-size:15px; display:flex; align-items:center; gap:8px; }
    .provider .badge { font-family:var(--mono); font-size:9.5px; letter-spacing:.05em; color:var(--good); background:var(--good-soft); border:1px solid #33d69f33; padding:2px 7px; border-radius:999px; }
    .provider .note { color:var(--ink-dim); font-size:13px; flex:1; }
    .provider a.visit { font-family:var(--mono); font-size:12px; color:var(--accent2); text-decoration:none; margin-top:4px; }
    .provider a.visit:hover { text-decoration:underline; }

    .callout {
      background:var(--panel-solid); border:1px solid var(--line); border-left:3px solid var(--warn);
      border-radius:10px; padding:16px 20px; font-size:14px; color:var(--ink-dim); margin-bottom:20px;
    }
    .callout strong { color:var(--ink); }
    .callout.tip { border-left-color:var(--accent2); }
    .callout.good { border-left-color:var(--good); }
    .callout .lbl { font-family:var(--mono); font-size:10.5px; letter-spacing:.08em; text-transform:uppercase; display:block; margin-bottom:6px; }
    .callout.tip .lbl { color:var(--accent2); }
    .callout.good .lbl { color:var(--good); }
    .callout:not(.tip):not(.good) .lbl { color:var(--warn); }

    .steps { display:flex; flex-direction:column; margin-bottom:22px; }
    .step { display:grid; grid-template-columns:40px 1fr; gap:16px; padding:16px 0; border-top:1px solid var(--line-soft); }
    .step:first-child { border-top:none; }
    .step .n { font-family:var(--mono); font-weight:700; font-size:20px; color:var(--accent); line-height:1.3; }
    .step h3 { margin:0 0 5px; font-size:15px; font-weight:700; }
    .step p { margin:0; color:var(--ink-dim); font-size:14px; max-width:66ch; }
    .step code { font-family:var(--mono); font-size:12.5px; color:var(--accent2); background:var(--accent-soft); padding:1px 6px; border-radius:4px; }

    .drive-grid { display:grid; gap:12px; grid-template-columns:repeat(3, 1fr); margin-top:8px; }
    .drive-card { background:var(--panel-solid); border:1px solid var(--line); border-radius:12px; padding:16px 18px; }
    .drive-card .h { font-weight:700; font-size:14.5px; margin-bottom:6px; }
    .drive-card .verdict { font-family:var(--mono); font-size:10px; letter-spacing:.06em; text-transform:uppercase; padding:2px 8px; border-radius:999px; display:inline-block; margin-bottom:8px; }
    .drive-card .verdict.ok { color:var(--good); background:var(--good-soft); }
    .drive-card .verdict.caution { color:var(--warn); background:var(--warn-soft); }
    .drive-card p { margin:0; font-size:13px; color:var(--ink-dim); }

    /* app link table */
    .linktable { border:1px solid var(--line); border-radius:var(--radius); overflow:hidden; background:var(--panel-solid); overflow-x:auto; }
    .linktable table { width:100%; border-collapse:collapse; font-size:14px; min-width:520px; }
    .linktable thead th { text-align:left; font-family:var(--mono); font-size:10.5px; letter-spacing:.08em; text-transform:uppercase; color:var(--ink-faint); padding:12px 16px; border-bottom:1px solid var(--line-soft); background:#0000002e; }
    .linktable td { padding:12px 16px; border-bottom:1px solid var(--line-soft); vertical-align:middle; }
    .linktable tr:last-child td { border-bottom:none; }
    .linktable .appcell { display:flex; align-items:center; gap:10px; font-weight:600; white-space:nowrap; }
    .linktable .appicon { width:26px; height:26px; border-radius:7px; display:flex; align-items:center; justify-content:center; font-family:var(--mono); font-weight:700; font-size:10.5px; background:var(--icon-bg, var(--accent-soft)); color:var(--icon-fg, var(--accent)); flex:none; }
    .linktable .role { color:var(--ink-dim); font-size:13px; }
    .linktable a.linkbtn { font-family:var(--mono); font-size:12px; color:var(--accent2); text-decoration:none; white-space:nowrap; }
    .linktable a.linkbtn:hover { text-decoration:underline; }
    .linktable a.linkbtn + a.linkbtn { margin-left:16px; }

    /* maintenance checklist cards */
    .maint-grid { display:grid; gap:14px; grid-template-columns:repeat(2, 1fr); margin-top:6px; }
    .maint-card { background:var(--panel-solid); border:1px solid var(--line); border-radius:12px; padding:18px 20px; }
    .maint-card .h { display:flex; align-items:center; gap:9px; margin-bottom:4px; }
    .maint-card .h strong { font-size:15px; }
    .maint-card .cadence { font-family:var(--mono); font-size:10px; letter-spacing:.06em; text-transform:uppercase; color:var(--accent2); background:var(--accent-soft); padding:2px 8px; border-radius:999px; }
    .maint-card ul { margin:12px 0 0; padding-left:18px; color:var(--ink-dim); font-size:13.5px; }
    .maint-card li { margin-bottom:8px; }
    .maint-card li:last-child { margin-bottom:0; }

    footer.page-footer { padding:40px 28px 60px; text-align:center; }
    footer.page-footer p { color:var(--ink-faint); font-size:12.5px; max-width:70ch; margin:0 auto 20px; }

    @media (max-width:640px) { .drive-grid { grid-template-columns:1fr; } .maint-grid { grid-template-columns:1fr; } }
  </style>
</head>
<body>

  <header>
    <div class="brand">
      <div class="brand-mark">RT</div>
      <div>
        <h1>Getting Started</h1>
        <div class="sub">A few things worth doing before you queue up a download</div>
      </div>
    </div>
    <a class="dash-link" href="/">Open Dashboard &rarr;</a>
  </header>

  <main>
    <h1 class="page-title">Before you run anything</h1>
    <p class="page-sub">Every app is installed, wired together, and running. The things below are the pieces that depend on accounts, hardware, and network only you have -- nothing here could be automated for you.</p>

    <div class="lede">This page doesn't pop back up on its own after today &mdash; find it again any time from the <strong>Getting Started Guide</strong> link in the Dashboard's header.</div>

    <section class="topic">
      <p class="topic-kicker">01 &middot; BEFORE YOU TORRENT</p>
      <h2>Get a VPN before qBittorrent downloads anything</h2>
      <p>Torrent swarms are public -- anyone in the swarm, including your ISP, can see the IP address of everyone else downloading that file. That's how automated cease-and-desist letters and throttling happen, copyrighted or not. A VPN puts a different IP address between you and the swarm. Usenet (the next section) works differently and doesn't have this specific problem, but qBittorrent traffic really shouldn't go out unprotected.</p>

      <div class="provider-grid">
        <div class="provider" style="--card-accent:#7c6cf6">
          <div class="name">NordVPN</div>
          <div class="note">Large server network, a dedicated port-forwarding option that helps torrent speeds, and its own kill-switch.</div>
          <a class="visit" href="https://nordvpn.com" target="_blank" rel="noopener">nordvpn.com &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#2dd4e8">
          <div class="name">Surfshark</div>
          <div class="note">Unlimited simultaneous devices on one plan, usually the cheapest of this group, kill-switch built in.</div>
          <a class="visit" href="https://surfshark.com" target="_blank" rel="noopener">surfshark.com &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#33d69f">
          <div class="name">ExpressVPN</div>
          <div class="note">Consistently fast, simple Windows app, a longer track record than most of this list.</div>
          <a class="visit" href="https://expressvpn.com" target="_blank" rel="noopener">expressvpn.com &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#f5b942">
          <div class="name">Private Internet Access</div>
          <div class="note">Very configurable, port forwarding available, been in the torrenting community for a long time.</div>
          <a class="visit" href="https://www.privateinternetaccess.com" target="_blank" rel="noopener">privateinternetaccess.com &rarr;</a>
        </div>
      </div>

      <div class="callout tip">
        <span class="lbl">Technician's tip &mdash; a real kill-switch for qBittorrent</span>
        Install your VPN provider's Windows app first and connect it. Then in qBittorrent go to <strong>Options &rarr; Advanced &rarr; Network Interface</strong> and pick the VPN's own adapter (something like &ldquo;NordLynx&rdquo; or &ldquo;Surfshark VPN&rdquo;) instead of &ldquo;Any interface&rdquo;. If the VPN ever drops, qBittorrent has no route out at all instead of quietly falling back to your real IP.
      </div>
    </section>

    <section class="topic">
      <p class="topic-kicker">02 &middot; SABNZBD NEEDS A USENET PROVIDER</p>
      <h2>Pick a Usenet (newsgroup) provider</h2>
      <p>Usenet works differently from torrents -- you're downloading from one provider's servers over an encrypted (SSL/TLS) connection, not from a public swarm of strangers, so your ISP only sees that you connected to a Usenet server, not what you downloaded. A provider is just the pipe, though -- you'll also want a separate indexer to actually search for things (a couple are linked below).</p>

      <div class="provider-grid">
        <div class="provider" style="--card-accent:#33d69f">
          <div class="name">Newshosting <span class="badge">WHAT WE USE</span></div>
          <div class="note">SSL by default, a built-in search tool, and a long retention window. This is the one running behind the scenes here.</div>
          <a class="visit" href="https://www.newshosting.com" target="_blank" rel="noopener">newshosting.com &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#7c6cf6">
          <div class="name">Eweka</div>
          <div class="note">EU-based, well regarded for completion rates and speed in Europe specifically.</div>
          <a class="visit" href="https://www.eweka.nl" target="_blank" rel="noopener">eweka.nl &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#2dd4e8">
          <div class="name">UsenetServer</div>
          <div class="note">Been around since the early Usenet-provider days, straightforward plans, SSL included.</div>
          <a class="visit" href="https://www.usenetserver.com" target="_blank" rel="noopener">usenetserver.com &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#f5b942">
          <div class="name">Tweaknews</div>
          <div class="note">Bundles a block-account style plan with its own indexer/search access included.</div>
          <a class="visit" href="https://www.tweaknews.eu" target="_blank" rel="noopener">tweaknews.eu &rarr;</a>
        </div>
        <div class="provider" style="--card-accent:#f9576b">
          <div class="name">Frugal Usenet</div>
          <div class="note">Usually the least expensive of this list for a similar retention window -- a good starting point.</div>
          <a class="visit" href="https://www.frugalusenet.com" target="_blank" rel="noopener">frugalusenet.com &rarr;</a>
        </div>
      </div>

      <div class="callout good">
        <span class="lbl">Also worth having &mdash; an indexer</span>
        Your Usenet provider is the download pipe; an indexer is the search engine that finds the files in the first place. <a href="https://nzbgeek.info" target="_blank" rel="noopener">NZBgeek</a> and <a href="https://www.drunkenslug.com" target="_blank" rel="noopener">DrunkenSlug</a> are two common ones with paid plans (and occasional free trials/invites) &mdash; add whichever you pick in Prowlarr under Indexers so it syncs to every app automatically.
      </div>

      <div class="callout">
        <span class="lbl">Wiring it in</span>
        Re-run the installer with <code>-UsenetHost</code>, <code>-UsenetUsername</code> and <code>-UsenetPassword</code> once you've signed up and it'll configure SABnzbd for you. Or just add the server by hand in SABnzbd under <strong>Config &rarr; Servers</strong> &mdash; use port <strong>563</strong> with SSL enabled.
      </div>
    </section>

    <section class="topic">
      <p class="topic-kicker">03 &middot; OPTIONAL</p>
      <h2>Putting Movies, TV, or Adult on a different drive</h2>
      <p>Everything defaults to one folder on this machine's system drive. That's completely fine to leave as-is -- but if you've got another drive, a NAS, or want a library backed up through OneDrive, here's what actually has to change to keep it all still wired together.</p>

      <div class="steps">
        <div class="step">
          <div class="n">01</div>
          <div><h3>Decide where it's going</h3><p>A different local drive letter, a NAS share, or a folder inside OneDrive all work. See the three verdicts below before picking OneDrive specifically.</p></div>
        </div>
        <div class="step">
          <div class="n">02</div>
          <div><h3>Add it as a root folder in the matching app</h3><p>Sonarr for TV, Radarr for Movies, Whisparr for Adult &mdash; <code>Settings &rarr; Media Management &rarr; Root Folders &rarr; Add</code>. The app will use it for anything new; existing items stay where they are until you move them.</p></div>
        </div>
        <div class="step">
          <div class="n">03</div>
          <div><h3>Fix permissions if it's outside this install</h3><p>These apps run as Windows services, which by default run as the SYSTEM account -- not your own login. A folder under your own user profile (OneDrive included) often isn't shared with SYSTEM. Right-click the folder &rarr; <code>Properties &rarr; Security &rarr; Edit</code> &rarr; add <code>SYSTEM</code> with Full Control. For a NAS, use its full UNC path (<code>\\nas\media</code>) rather than a mapped drive letter -- SYSTEM can't see drive letters mapped under your own login.</p></div>
        </div>
        <div class="step">
          <div class="n">04</div>
          <div><h3>Same drive as \downloads when you can</h3><p>This stack's default layout keeps downloads and the finished library on one volume so finished files can be instantly hardlinked into place instead of copied. A root folder on a different drive still works, just falls back to a slower copy every time.</p></div>
        </div>
        <div class="step">
          <div class="n">05</div>
          <div><h3>Point Jellyfin at it too</h3><p>Jellyfin's dashboard &rarr; <code>Libraries</code> &rarr; add or edit the matching library so playback picks up the new location.</p></div>
        </div>
        <div class="step">
          <div class="n">06</div>
          <div><h3>Re-sync in Seerr</h3><p>Settings &rarr; Jellyfin &amp; Emby &rarr; Library Scan, so requests know about the (re)organized libraries too.</p></div>
        </div>
      </div>

      <div class="drive-grid">
        <div class="drive-card">
          <div class="h">OneDrive for Movies</div>
          <div class="verdict caution">Think twice</div>
          <p>Movie libraries get huge fast, especially at higher quality. OneDrive has to sync every byte, and its Files On-Demand feature can make Jellyfin stutter mid-playback if a file isn't fully downloaded locally yet.</p>
        </div>
        <div class="drive-card">
          <div class="h">OneDrive for TV</div>
          <div class="verdict ok">Reasonable</div>
          <p>Smaller per-episode file sizes make this a lot more manageable than movies -- a fine option if you want a synced backup of a modest TV library.</p>
        </div>
        <div class="drive-card">
          <div class="h">OneDrive for Adult</div>
          <div class="verdict ok">Good fit</div>
          <p>Usually the smallest of the three libraries by total size, and keeping it in its own separate, differently-permissioned folder is a reasonable privacy habit on a shared machine.</p>
        </div>
      </div>
    </section>

    <section class="topic">
      <p class="topic-kicker">04 &middot; WATCHING AWAY FROM THIS PC</p>
      <h2>Watch on your TV, phone, or tablet</h2>
      <p>Jellyfin doesn't care what screen you're on -- there's a client for almost everything. Getting to it from another device just needs the right address, and Windows letting the connection through.</p>

      <div class="callout good">
        <span class="lbl">On your home WiFi</span>
        From any device on the same network as this PC, point a Jellyfin app (or just a browser) at <code>REPLACE_LAN_ADDR</code> and sign in with the same login as everything else here.
      </div>

REPLACE_LAN_FIREWALL_CALLOUT
REPLACE_REMOTE_CALLOUT

      <div class="steps">
        <div class="step">
          <div class="n">TV</div>
          <div><h3>Smart TVs &amp; streaming boxes</h3><p>Official or community Jellyfin apps exist for Android TV/Google TV, Fire TV, Roku, and Nvidia Shield; Samsung and Apple TV support varies by model, so casting from a phone or laptop is the reliable fallback there. Full client list: <a href="https://jellyfin.org/downloads/clients" target="_blank" rel="noopener">jellyfin.org/downloads/clients</a>.</p></div>
        </div>
        <div class="step">
          <div class="n">&#128241;</div>
          <div><h3>Phones &amp; tablets</h3><p>The official Jellyfin app is on the Google Play Store and the Apple App Store. Add this PC as a server using the address above (or your tailnet address once you're away from home).</p></div>
        </div>
        <div class="step">
          <div class="n">&#128421;</div>
          <div><h3>Any browser</h3><p>No app needed &mdash; open the address above directly in a browser on any laptop, desktop, or Chromebook.</p></div>
        </div>
      </div>
    </section>

    <section class="topic">
      <p class="topic-kicker">05 &middot; EVERY APP, LINKED</p>
      <h2>Your apps, and how to actually use them</h2>
      <p>Each app has its own real interface and its own learning curve. Here's a straight line to both: this install's address, and that project's own documentation for when you want to go deeper than what this guide covers.</p>
      <div class="linktable">
        <table>
          <thead><tr><th>App</th><th>What it's for</th><th>Links</th></tr></thead>
          <tbody>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#f5b9421a;--icon-fg:#f5b942">PR</span>Prowlarr</div></td>
              <td class="role">Indexer manager &mdash; syncs indexers out to every app below</td>
              <td><a class="linkbtn" href="http://localhost:9696" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/prowlarr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#2dd4e81a;--icon-fg:#2dd4e8">SO</span>Sonarr</div></td>
              <td class="role">TV library automation</td>
              <td><a class="linkbtn" href="http://localhost:8989" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/sonarr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#ffb4541a;--icon-fg:#ffb454">RA</span>Radarr</div></td>
              <td class="role">Movie library automation</td>
              <td><a class="linkbtn" href="http://localhost:7878" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/radarr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#33d69f1a;--icon-fg:#33d69f">LI</span>Lidarr</div></td>
              <td class="role">Music library automation</td>
              <td><a class="linkbtn" href="http://localhost:8686" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/lidarr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#f9576b1a;--icon-fg:#f9576b">RE</span>Readarr</div></td>
              <td class="role">Book library automation</td>
              <td><a class="linkbtn" href="http://localhost:8787" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/readarr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#7c6cf61a;--icon-fg:#a99bff">WH</span>Whisparr</div></td>
              <td class="role">Adult library automation</td>
              <td><a class="linkbtn" href="http://localhost:6969" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://wiki.servarr.com/whisparr" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#33d69f1a;--icon-fg:#33d69f">SA</span>SABnzbd</div></td>
              <td class="role">Usenet download client</td>
              <td><a class="linkbtn" href="http://localhost:8080" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://sabnzbd.org/wiki/" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#2dd4e81a;--icon-fg:#2dd4e8">QB</span>qBittorrent</div></td>
              <td class="role">Torrent download client</td>
              <td><a class="linkbtn" href="http://localhost:8181" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://github.com/qbittorrent/qBittorrent/wiki" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#8a5cf61a;--icon-fg:#b79dff">JF</span>Jellyfin</div></td>
              <td class="role">Media server &mdash; streams your library</td>
              <td><a class="linkbtn" href="http://localhost:8096" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://jellyfin.org/docs/" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
            <tr>
              <td><div class="appcell"><span class="appicon" style="--icon-bg:#f973621a;--icon-fg:#f97362">SR</span>Seerr</div></td>
              <td class="role">Request management &mdash; lets others ask for titles</td>
              <td><a class="linkbtn" href="http://localhost:5055" target="_blank" rel="noopener">Open &rarr;</a><a class="linkbtn" href="https://docs.seerr.dev" target="_blank" rel="noopener">Docs &rarr;</a></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="topic">
      <p class="topic-kicker">06 &middot; ONGOING CARE</p>
      <h2>Keeping it running well</h2>
      <p>A media server doesn't need much day-to-day attention, but a few habits keep storage from quietly filling up and keep every app doing useful work instead of chasing things you don't actually want anymore.</p>

      <div class="callout tip">
        <span class="lbl">Deciding what to keep</span>
        In Sonarr/Radarr/Lidarr, <strong>Unmonitor</strong> a show, movie, or artist (right-click it, or the toggle on its own page) to stop it from being searched for or upgraded, without touching the files already on disk. Only checking <strong>Delete Files</strong> when you remove something actually deletes it &mdash; unmonitoring alone is the "keep it, just stop hunting for it" option.
      </div>

      <div class="callout">
        <span class="lbl">Archiving instead of deleting</span>
        Each app supports more than one root folder (see the drive-planning section above). A common pattern: keep an "active" root folder for what you're still watching, and a second, slower or cheaper "Archive" root folder for what you want to keep long-term. Move the files on disk, then point that item at the new root folder (or trigger a rescan) so the app's records match reality.
      </div>

      <div class="steps">
        <div class="step">
          <div class="n">&#8635;</div>
          <div><h3>Downloads pile up if you let them</h3><p>qBittorrent: set a seeding limit under <strong>Options &rarr; BitTorrent &rarr; Seeding Limits</strong> (a ratio like 2.0, or a number of days) so torrents stop seeding themselves automatically, then periodically clear finished ones from the list. SABnzbd: its <strong>History</strong> tab fills up with completed and failed jobs over time &mdash; clear it out occasionally, and check failed jobs for a pattern (a bad indexer, a connection limit) rather than letting them silently pile up.</p></div>
        </div>
        <div class="step">
          <div class="n">&#9881;</div>
          <div><h3>Jellyfin stays healthy with a light touch</h3><p>Library scans usually run on their own schedule (Jellyfin's dashboard &rarr; <strong>Scheduled Tasks</strong>), but a manual scan after a big import batch doesn't hurt. If playback stutters with more than one stream going, check the Dashboard's Host CPU gauge &mdash; that's usually transcoding load, and Jellyfin's <strong>Playback &rarr; Transcoding</strong> settings are where hardware acceleration gets turned on if your CPU or GPU supports it.</p></div>
        </div>
        <div class="step">
          <div class="n">&#128230;</div>
          <div><h3>Keep the apps themselves current</h3><p>Run <code>Update-REGTechesMediaStack.ps1</code> from an elevated PowerShell every so often &mdash; it only touches what's actually out of date, config and API keys included. Windows Update, and the VPN/Jellyfin apps on your other devices, are worth keeping current too.</p></div>
        </div>
      </div>

      <div class="maint-grid">
        <div class="maint-card">
          <div class="h"><strong>Weekly</strong><span class="cadence">~5 minutes</span></div>
          <ul>
            <li>Glance at the Dashboard's Storage panel &mdash; anything creeping toward that amber/red line?</li>
            <li>Clear finished jobs out of SABnzbd's History and qBittorrent's torrent list.</li>
            <li>Check Recent Activity on the Dashboard for repeated failures on one indexer or app.</li>
          </ul>
        </div>
        <div class="maint-card">
          <div class="h"><strong>Monthly</strong><span class="cadence">~15 minutes</span></div>
          <ul>
            <li>Go through anything you've finished watching &mdash; unmonitor it, archive it, or delete it on purpose instead of by accident of neglect.</li>
            <li>Run <code>Update-REGTechesMediaStack.ps1</code> to pull current app versions.</li>
            <li>Confirm qBittorrent's seeding limits are actually doing their job &mdash; nothing seeding forever at a 40:1 ratio.</li>
          </ul>
        </div>
      </div>
    </section>
  </main>

  <footer class="page-footer">
    <p>You're responsible for what you point these apps at and for complying with your provider's terms and local laws. A VPN and an encrypted Usenet connection protect your traffic in transit &mdash; they don't change what's legal to download.</p>
    <a class="dash-link" href="/">Open Dashboard &rarr;</a>
  </footer>

</body>
</html>
'@
$welcomeHtml = $welcomeHtml.Replace("REPLACE_LAN_ADDR", $lanAddrText)
$welcomeHtml = $welcomeHtml.Replace("REPLACE_LAN_FIREWALL_CALLOUT", $firewallCallout)
$welcomeHtml = $welcomeHtml.Replace("REPLACE_REMOTE_CALLOUT", $remoteCallout)
$welcomeHtml | Set-Content -Path (Join-Path $paths.Dashboard "getting-started.html") -Encoding UTF8

$psExe = (Get-Command powershell.exe).Source
Install-NssmService -ServiceName "REGTMS-Dashboard" -DisplayName "Dashboard" `
    -BinPath $psExe -AppArgs "-NoProfile -ExecutionPolicy Bypass -File `"$dashScriptPath`"" `
    -WorkingDir $paths.Dashboard

Save-State

# ============================================================
# Edge favorites + desktop shortcut -- so every app's port is a click
# away instead of something to remember or hunt for after closing a tab.
# ============================================================

Log "---- Edge favorites & desktop shortcut ----"
try {
    # ManagedFavorites (https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/managedfavorites)
    # -- Edge's own purpose-built mechanism for exactly this: a
    # locked folder in the favorites bar driven entirely by registry
    # policy. Deliberately not hand-editing Edge's live Bookmarks JSON
    # file directly -- that would risk corrupting the user's own
    # bookmarks if the file's shape is ever slightly off, needs Edge
    # closed to avoid a race with its own writes, and isn't an
    # officially supported surface. This policy touches none of that:
    # it's a separate folder the user's own bookmarks never see, reads
    # dynamically (no browser restart required per Microsoft's own
    # policy docs), and is the same mechanism IT departments already
    # use at scale via Group Policy/Intune.
    $edgeFavorites = @(
        @{ toplevel_name = $stackName }
        @{ name = "Dashboard";   url = "http://localhost:8090" }
        @{ name = "Getting Started"; url = "http://localhost:8090/getting-started" }
        @{ name = "Prowlarr";    url = "http://localhost:9696" }
        @{ name = "Sonarr";      url = "http://localhost:8989" }
        @{ name = "Radarr";      url = "http://localhost:7878" }
        @{ name = "Lidarr";     url = "http://localhost:8686" }
        @{ name = "Readarr";     url = "http://localhost:8787" }
        @{ name = "Whisparr";    url = "http://localhost:6969" }
        @{ name = "SABnzbd";     url = "http://localhost:8080" }
        @{ name = "qBittorrent"; url = "http://localhost:8181" }
        @{ name = "Jellyfin";    url = "http://localhost:8096" }
        @{ name = "Seerr";       url = "http://localhost:5055" }
    )
    $edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    # Confirmed live: New-Item -Force on an ALREADY-EXISTING registry key
    # deletes and recreates it, silently wiping every other value under it
    # (including this same ManagedFavorites value on a re-run, and any other
    # Edge policy someone else set on this key) -- only create it when it's
    # genuinely missing.
    if (-not (Test-Path $edgePolicyPath)) { New-Item -Path $edgePolicyPath -Force | Out-Null }
    Set-ItemProperty -Path $edgePolicyPath -Name "ManagedFavorites" -Value ($edgeFavorites | ConvertTo-Json -Depth 5 -Compress)
    # FavoritesBarEnabled=1 (https://learn.microsoft.com/deployedge/microsoft-edge-policies/favoritesbarenabled)
    # forces the favorites bar always visible on every page (not just new
    # tabs) and locks the Settings toggle to On so it can't get turned back
    # off -- otherwise the folder above exists but stays hidden until the
    # user manually flips "Show favorites bar" themselves.
    Set-ItemProperty -Path $edgePolicyPath -Name "FavoritesBarEnabled" -Value 1 -Type DWord
    Log "Added a '$stackName' favorites folder in Edge's favorites bar and set it to always show (restart Edge if it's already open to see it)." "OK"
} catch {
    Log "Could not add Edge favorites: $($_.Exception.Message)" "WARN"
}

try {
    # The dashboard already *is* "one page with all of them" -- a
    # desktop shortcut to it is the most direct way to make that
    # unmissable, on top of the Edge favorites folder above.
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$stackName.url"
    @"
[InternetShortcut]
URL=http://localhost:8090
"@ | Set-Content -Path $shortcutPath -Encoding ASCII
    Log "Added a '$stackName' shortcut to the Dashboard on the Desktop." "OK"
} catch {
    Log "Could not add a Desktop shortcut: $($_.Exception.Message)" "WARN"
}

# ============================================================
# Optional: LAN firewall access
# ============================================================

if ($OpenFirewallPorts) {
    $allPorts = 9696,8989,7878,8686,8787,6969,8080,8181,8090,8096,5055
    foreach ($p in $allPorts) {
        $ruleName = "REGTeches Media Stack - TCP $p"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow | Out-Null
        }
    }
    Log "Firewall rules added for LAN access on all stack ports." "OK"
}

# ============================================================
# Summary
# ============================================================

Start-Process "http://localhost:8090/getting-started"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " $stackName installation complete." -ForegroundColor Green
Write-Host " Dashboard: http://localhost:8090" -ForegroundColor Green
Write-Host " Getting Started guide: http://localhost:8090/getting-started (just opened)" -ForegroundColor Green
Write-Host " Developed by Ronald Goodchild for your pleasure" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Login (all apps): $AdminUsername / $AdminPassword" -ForegroundColor Green
if ($GeneratedPassword) { Write-Host " (password generated for you - save it now; it is also stored in $statePath)" -ForegroundColor Green }
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "MANUAL STEPS STILL NEEDED:" -ForegroundColor Yellow
Write-Host " 1. Prowlarr has no indexers yet. Add your own in Prowlarr -> Indexers (Usenet," -ForegroundColor Yellow
Write-Host "    private or public trackers of your choosing) -- they sync to every app automatically." -ForegroundColor Yellow
Write-Host "    Usenet indexers (for SABnzbd) are account-based, so they cannot be pre-added --" -ForegroundColor Yellow
Write-Host "    that's normal for Usenet, not a gap here. Sign up with one (NZBgeek etc.," -ForegroundColor Yellow
Write-Host "    a free trial is enough), then add it in Prowlarr -> Indexers by name or as" -ForegroundColor Yellow
Write-Host "    a generic Newznab entry -- see the Getting Started guide for provider picks," -ForegroundColor Yellow
Write-Host "    or the README for the full explanation." -ForegroundColor Yellow
Write-Host " 2. Jellyfin (http://localhost:8096) -> log in with $AdminUsername / $AdminPassword" -ForegroundColor Yellow
Write-Host "    Libraries were added automatically; if that failed, the log says so." -ForegroundColor Yellow
Write-Host " 3. Review quality profiles in Sonarr/Radarr -- Recyclarr synced quality" -ForegroundColor Yellow
Write-Host "    definitions; custom formats can be added via $($paths.Tools)\recyclarr\recyclarr.yml" -ForegroundColor Yellow
if (-not $UsenetHost) {
    Write-Host " 4. No Usenet server configured yet -- re-run with -UsenetHost/-UsenetUsername/" -ForegroundColor Yellow
    Write-Host "    -UsenetPassword once you've got one (even a free trial proves the chain works)." -ForegroundColor Yellow
}
if (-not $SkipTailscale) {
    Write-Host " 5. Tailscale: if no -TailscaleAuthKey was given, approve the login prompt" -ForegroundColor Yellow
    Write-Host "    that just opened to finish joining your tailnet." -ForegroundColor Yellow
}
Write-Host ""
Log "Installer finished."
