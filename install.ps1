<#
.SYNOPSIS
    Install myssh (Python edition) on Windows.

.DESCRIPTION
    Copies myssh.py into a per-user bin directory, creates a `myssh.cmd`
    shim that calls Python from a dedicated venv, and adds the bin
    directory to PATH (User scope by default, System scope with -System).

    For the pure-bash edition (myssh.sh), use Git Bash or WSL and run:
        ./install.sh --shell

.PARAMETER System
    Install for all users by appending to the System PATH. Falls back to
    User PATH if elevation is unavailable.

.PARAMETER Force
    Overwrite an existing installation without prompting.

.PARAMETER InstallDir
    Override the install directory. Defaults to %USERPROFILE%\.local\bin.
#>

[CmdletBinding()]
param(
    [switch]$System,
    [switch]$Force,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'

function Write-Info  { param([string]$Msg) Write-Host $Msg }
function Write-Step  { param([string]$Msg) Write-Host "  $Msg" }
function Write-OK    { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "Error: $Msg" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- locate source -------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source    = Join-Path $ScriptDir 'myssh.py'
if (-not (Test-Path $Source)) {
    Write-Err "myssh.py not found next to install.ps1 ($Source)."
    exit 1
}

# ---- target directory ----------------------------------------------------
if (-not $InstallDir -or $InstallDir.Trim() -eq '') {
    $InstallDir = Join-Path $env:USERPROFILE '.local\bin'
}
$TargetPy  = Join-Path $InstallDir 'myssh.py'
$TargetCmd = Join-Path $InstallDir 'myssh.cmd'

Write-Info "myssh installer (Windows)"
Write-Step "Install location: $InstallDir"

# ---- python --------------------------------------------------------------
$python = $null
foreach ($name in @('python', 'py', 'python3')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    try {
        $args = @()
        if ($name -eq 'py') { $args = @('-3') }
        $version = & $cmd.Source @args -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) {
            $parts = $version.Trim().Split('.')
            if ([int]$parts[0] -ge 3 -and [int]$parts[1] -ge 8) {
                $python = @{ Path = $cmd.Source; Args = $args; Version = $version.Trim() }
                break
            }
        }
    } catch { }
}
if (-not $python) {
    Write-Err "Python 3.8+ is required but was not found on PATH."
    Write-Step "Install from https://python.org or via 'winget install Python.Python.3'."
    exit 1
}
Write-Step "Python:  $($python.Path) ($($python.Version))"

# ---- ssh client ----------------------------------------------------------
$ssh    = Get-Command ssh -ErrorAction SilentlyContinue
$keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $ssh -or -not $keygen) {
    Write-Err "OpenSSH client is missing (ssh / ssh-keygen)."
    Write-Step "Install via: Settings > Apps > Optional features > 'OpenSSH Client'."
    Write-Step "Or run (admin): Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    exit 1
}
Write-Step "ssh:     $($ssh.Source)"
Write-Step "keygen:  $($keygen.Source)"

# ---- bundled venv for paramiko ------------------------------------------
$VenvDir = Join-Path $env:USERPROFILE '.local\share\myssh\venv'
$VenvPy  = Join-Path $VenvDir 'Scripts\python.exe'

Write-Info ""
Write-Step "Preparing virtualenv at $VenvDir..."
$venvParent = Split-Path -Parent $VenvDir
if (-not (Test-Path $venvParent)) { New-Item -ItemType Directory -Path $venvParent -Force | Out-Null }

if (-not (Test-Path $VenvPy)) {
    & $python.Path @($python.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $VenvPy)) {
        Write-Err "Could not create virtualenv at $VenvDir."
        exit 1
    }
}

& $VenvPy -c 'import paramiko' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Installing paramiko into venv (required for 'myssh register')..."
    & $VenvPy -m pip install --quiet --upgrade pip 2>$null | Out-Null
    & $VenvPy -m pip install --quiet paramiko
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Quiet install failed. Retrying with verbose output:"
        & $VenvPy -m pip install paramiko
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not install paramiko into $VenvDir."
            exit 1
        }
    }
}

# Use the venv interpreter for the shim so the tool is self-contained.
$python = @{ Path = $VenvPy; Args = @(); Version = (& $VenvPy -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])').Trim() }
Write-Step "Using interpreter: $($python.Path) ($($python.Version))"

# ---- install dir ---------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ---- existing install ----------------------------------------------------
if ((Test-Path $TargetPy) -and -not $Force) {
    $sourceHash = (Get-FileHash $Source).Hash
    $existHash  = (Get-FileHash $TargetPy).Hash
    if ($sourceHash -ne $existHash) {
        $reply = Read-Host "A different myssh is already installed at $TargetPy. Overwrite? [y/N]"
        if ($reply -notin @('y','Y','yes','YES')) {
            Write-Info "Cancelled."
            exit 1
        }
    }
}

Copy-Item -Path $Source -Destination $TargetPy -Force

# ---- shim ----------------------------------------------------------------
$pyArgsString = if ($python.Args.Count -gt 0) { ($python.Args -join ' ') + ' ' } else { '' }
$shimContent = @"
@echo off
"$($python.Path)" $pyArgsString"$TargetPy" %*
"@
Set-Content -Path $TargetCmd -Value $shimContent -Encoding ASCII

# ---- PATH ----------------------------------------------------------------
function Add-ToPath {
    param([string]$Scope, [string]$Dir)
    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if (-not $current) { $current = '' }
    $entries = $current.Split(';') | Where-Object { $_ -ne '' }
    if ($entries -contains $Dir) { return $false }
    $new = if ($current -and -not $current.EndsWith(';')) { "$current;$Dir" } else { "$current$Dir" }
    [Environment]::SetEnvironmentVariable('Path', $new, $Scope)
    return $true
}

$scope = 'User'
$pathChanged = $false

if ($System) {
    if (Test-Admin) {
        try {
            $pathChanged = Add-ToPath -Scope 'Machine' -Dir $InstallDir
            $scope = 'Machine'
        } catch {
            Write-Warn2 "Could not modify System PATH ($($_.Exception.Message)). Falling back to User PATH."
            $pathChanged = Add-ToPath -Scope 'User' -Dir $InstallDir
        }
    } else {
        Write-Warn2 "Not running as Administrator. Falling back to User PATH."
        $pathChanged = Add-ToPath -Scope 'User' -Dir $InstallDir
    }
} else {
    $pathChanged = Add-ToPath -Scope 'User' -Dir $InstallDir
}

# Refresh current session PATH so verification works immediately.
if ($env:Path -notlike "*$InstallDir*") {
    $env:Path = "$InstallDir;$env:Path"
}

# ---- verify --------------------------------------------------------------
Write-Info ""
Write-Step "Running myssh help..."
& $TargetCmd help | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "myssh failed to run. Inspect $TargetPy."
    exit 1
}

Write-Info ""
Write-OK "myssh installed successfully."
Write-Info ""
if ($pathChanged) {
    Write-Info "Added $InstallDir to $scope PATH."
    Write-Info "Restart your terminal so the new PATH takes effect."
} else {
    Write-Info "$InstallDir is already on PATH."
}
Write-Info ""
Write-Info "Usage:"
Write-Info "  myssh register <server-address> <alias>"
Write-Info "  myssh <alias>"
