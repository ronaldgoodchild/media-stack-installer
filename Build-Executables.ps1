<#
    REGTeches Media Stack -- Build Executables
    Developed by Ronald Goodchild for your pleasure

    Compiles the GUI setup wrapper and the real installer into standalone
    .exe files using the ps2exe module, so either can be double-clicked
    directly -- no "right-click -> Run with PowerShell", no execution-policy
    prompts, and the installer gets a real UAC shield icon instead of our
    own manual admin check.

    Run this yourself, on your own machine, from this folder:
        powershell -ExecutionPolicy Bypass -File .\Build-Executables.ps1

    Output (next to this script, same folder the GUI already expects the
    installer to live in):
        Install-REGTechesMediaStack.exe   (requires admin -- native UAC prompt)
        REGTechesMediaStack-Setup.exe     (runs unelevated, launches the exe above)

    Only compiles what changed since the last build (source .ps1 newer than
    the existing .exe) unless -Force is passed.
#>

param([switch]$Force)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "ps2exe module not found -- installing it for the current user..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force -Repository PSGallery
}
Import-Module ps2exe -Force

$version = "1.0.0.0"
$company = "REGTeches"
$copyright = "Developed by Ronald Goodchild for your pleasure"

function Build-Exe {
    param(
        [string]$SourcePs1,
        [string]$OutputExe,
        [string]$Title,
        [string]$Description,
        [switch]$RequireAdmin,
        [switch]$NoConsole,
        [switch]$Sta
    )

    $src = Join-Path $root $SourcePs1
    $dst = Join-Path $root $OutputExe

    if (-not (Test-Path $src)) {
        Write-Host "Skipping $OutputExe -- $SourcePs1 not found next to this script." -ForegroundColor Yellow
        return
    }

    if (-not $Force -and (Test-Path $dst) -and (Get-Item $dst).LastWriteTime -gt (Get-Item $src).LastWriteTime) {
        Write-Host "$OutputExe is already up to date (pass -Force to rebuild anyway)." -ForegroundColor DarkGray
        return
    }

    Write-Host "Building $OutputExe ..." -ForegroundColor Cyan
    $ps2exeArgs = @{
        inputFile    = $src
        outputFile   = $dst
        title        = $Title
        description  = $Description
        company      = $company
        product      = "REGTeches Media Stack"
        copyright    = $copyright
        version      = $version
        noConsole    = [bool]$NoConsole
        requireAdmin = [bool]$RequireAdmin
        STA          = [bool]$Sta
    }
    Invoke-ps2exe @ps2exeArgs
    Write-Host "Built $dst" -ForegroundColor Green
}

# The real installer -- keep its console visible (it's Log/Write-Host driven,
# you're meant to watch it run), and requireAdmin gives it a native UAC
# shield icon + elevation prompt instead of our own "run this elevated"
# message-and-exit.
Build-Exe -SourcePs1 "Install-REGTechesMediaStack.ps1" -OutputExe "Install-REGTechesMediaStack.exe" `
    -Title "REGTeches Media Stack Installer" `
    -Description "Installs and wires up the REGTeches Media Stack" `
    -RequireAdmin

# The GUI wrapper -- WPF needs STA threading, and hides the console since
# there's no console output to show (it's a window, not a script).
Build-Exe -SourcePs1 "REGTechesMediaStack-Setup.ps1" -OutputExe "REGTechesMediaStack-Setup.exe" `
    -Title "REGTeches Media Stack Setup" `
    -Description "Friendly setup wizard for the REGTeches Media Stack" `
    -NoConsole -Sta

Write-Host ""
Write-Host "Done. Double-click REGTechesMediaStack-Setup.exe to install." -ForegroundColor Green
