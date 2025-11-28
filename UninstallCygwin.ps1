<#
.SYNOPSIS
  Completely removes Cygwin from this Windows installation.

.DESCRIPTION
  Stops Cygwin-related services and processes, deletes Cygwin installation
  directories and caches, cleans environment variables, removes registry keys,
  and deletes common shortcuts.

  This script is intentionally conservative about what it deletes:
  - It only deletes directories that exist, are not a drive root, and whose path contains "cygwin".
  - Cygwin package cache directories are removed only if they look like Cygwin-related paths.

.NOTES
  Run this script from an elevated PowerShell session (Run as administrator).
#>

#-----------------------------
# Helper: Check for elevation
#-----------------------------
function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
    exit 1
}

Write-Host "=== Cygwin uninstall started ===" -ForegroundColor Cyan

#-----------------------------
# 1. Stop and remove Cygwin services
#-----------------------------
Write-Host "`n[1/7] Stopping and removing Cygwin-related services (if any)..." -ForegroundColor Yellow

try {
    # Find services whose executable path references "cygwin"
    $cygwinServices = Get-WmiObject Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -and $_.PathName -match '(?i)cygwin' }

    if ($cygwinServices) {
        foreach ($svc in $cygwinServices) {
            Write-Host "  Found service: $($svc.Name) ($($svc.DisplayName))"

            if ($svc.State -ne 'Stopped') {
                Write-Host "    Stopping service..."
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Warning ("    Failed to stop service {0}: {1}" -f $svc.Name, $_.Exception.Message)
                }
            }

            Write-Host "    Deleting service..."
            try {
                & sc.exe delete $svc.Name | Out-Null
            } catch {
                Write-Warning ("    Failed to delete service {0}: {1}" -f $svc.Name, $_.Exception.Message)
            }
        }
    } else {
        Write-Host "  No Cygwin-related services found."
    }
} catch {
    Write-Warning ("  Error while querying services: {0}" -f $_.Exception.Message)
}

#-----------------------------
# 2. Kill Cygwin processes
#-----------------------------
Write-Host "`n[2/7] Terminating Cygwin-related processes..." -ForegroundColor Yellow

$knownProcNames = @(
    'bash', 'sh', 'mintty', 'XWin', 'xterm', 'rxvt', 'cygserver'
)

foreach ($name in $knownProcNames) {
    try {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            Write-Host "  Stopping process: $($p.ProcessName) (PID $($p.Id))"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning ("  Error while stopping process '{0}': {1}" -f $name, $_.Exception.Message)
    }
}

# Extra safeguard: any process whose path contains "cygwin"
try {
    $allProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -ne $null }
    $cygProcs = $allProcs | Where-Object { $_.Path -match '(?i)cygwin' }
    foreach ($p in $cygProcs) {
        Write-Host "  Stopping process by path: $($p.ProcessName) (PID $($p.Id)) Path: $($p.Path)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning ("  Error while scanning for Cygwin processes by path: {0}" -f $_.Exception.Message)
}

#-----------------------------
# 3. Discover Cygwin install roots & caches
#-----------------------------
Write-Host "`n[3/7] Detecting Cygwin installation directories and caches..." -ForegroundColor Yellow

$installRoots = @()
$cacheDirs    = @()

$regSetupPaths = @(
    'HKLM:\SOFTWARE\Cygwin\setup',
    'HKLM:\SOFTWARE\WOW6432Node\Cygwin\setup',
    'HKCU:\Software\Cygwin\setup'
)

foreach ($regPath in $regSetupPaths) {
    if (Test-Path $regPath) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

            if ($props.rootdir) {
                $root = $props.rootdir.Trim()
                if ($root -and (Test-Path $root)) {
                    $installRoots += $root
                    Write-Host "  Found install root from registry: $root"
                }
            }

            if ($props.'last-cache') {
                $cache = $props.'last-cache'.Trim()
                if ($cache) {
                    $cacheDirs += $cache
                    Write-Host "  Found cache path from registry: $cache"
                }
            }
        } catch {
            Write-Warning ("  Error reading registry path {0}: {1}" -f $regPath, $_.Exception.Message)
        }
    }
}

# Add common default install locations for completeness
$defaultRoots = @('C:\cygwin64', 'C:\cygwin')
foreach ($r in $defaultRoots) {
    if (Test-Path $r) {
        $installRoots += $r
        Write-Host "  Discovered existing Cygwin directory: $r"
    }
}

$installRoots = $installRoots | Sort-Object -Unique

# De-duplicate and sanity-check cache directories
$cacheDirs = $cacheDirs | Sort-Object -Unique

#-----------------------------
# 4. Delete Cygwin installation directories
#-----------------------------
Write-Host "`n[4/7] Removing Cygwin installation directories..." -ForegroundColor Yellow

function Remove-CygwinDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) {
        Write-Host "  Skipping $Path (does not exist)."
        return
    }

    # Avoid deleting drive roots by mistake
    $rootOfDrive = [System.IO.Path]::GetPathRoot($Path)
    if ($rootOfDrive -eq $Path.TrimEnd('\')) {
        Write-Warning "  Skipping $Path (appears to be a drive root)."
        return
    }

    # Require "cygwin" in the path to reduce the chance of accidental deletion
    if ($Path -notmatch '(?i)cygwin') {
        Write-Warning "  Skipping $Path (path does not contain 'cygwin')."
        return
    }

    Write-Host "  Taking ownership and adjusting permissions for: $Path"
    try {
        & takeown.exe /F "$Path" /R /D Y | Out-Null
        & icacls.exe "$Path" /T /grant Administrators:F /grant "$env:USERNAME":F /inheritance:e | Out-Null
    } catch {
        Write-Warning ("    Failed to set permissions on {0}: {1}" -f $Path, $_.Exception.Message)
    }

    Write-Host "  Deleting directory: $Path"
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Continue
    } catch {
        Write-Warning ("    Failed to delete {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

if ($installRoots.Count -eq 0) {
    Write-Host "  No Cygwin installation directories found."
} else {
    foreach ($root in $installRoots) {
        Remove-CygwinDirectory -Path $root
    }
}

#-----------------------------
# 5. Remove Cygwin package cache directories (optional)
#-----------------------------
Write-Host "`n[5/7] Removing Cygwin package cache directories (if any and safe)..." -ForegroundColor Yellow

foreach ($cache in $cacheDirs) {
    if (-not (Test-Path $cache)) {
        Write-Host "  Skipping cache $cache (does not exist)."
        continue
    }

    $rootOfDrive = [System.IO.Path]::GetPathRoot($cache)
    if ($rootOfDrive -eq $cache.TrimEnd('\')) {
        Write-Warning "  Skipping cache $cache (appears to be a drive root)."
        continue
    }

    # Require 'cygwin' in the path somewhere to be safe
    if ($cache -notmatch '(?i)cygwin') {
        Write-Warning "  Skipping cache $cache (path does not contain 'cygwin')."
        continue
    }

    Write-Host "  Deleting cache directory: $cache"
    try {
        & takeown.exe /F "$cache" /R /D Y | Out-Null
        & icacls.exe "$cache" /T /grant Administrators:F /grant "$env:USERNAME":F /inheritance:e | Out-Null
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Continue
    } catch {
        Write-Warning ("    Failed to delete cache {0}: {1}" -f $cache, $_.Exception.Message)
    }
}

#-----------------------------
# 6. Clean environment variables (PATH, CYGWIN)
#-----------------------------
Write-Host "`n[6/7] Cleaning PATH and CYGWIN environment variables..." -ForegroundColor Yellow

function Remove-CygwinFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Machine', 'User')]
        [string] $Scope
    )

    try {
        $pathValue = [Environment]::GetEnvironmentVariable('PATH', $Scope)
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            return
        }

        $entries = $pathValue -split ';'

        # Remove entries that reference cygwin in any way
        $filtered = $entries | Where-Object { $_ -and ($_ -notmatch '(?i)cygwin') }

        $newPath = ($filtered -join ';')

        if ($newPath -ne $pathValue) {
            Write-Host "  Updating PATH for scope '$Scope' to remove Cygwin entries."
            [Environment]::SetEnvironmentVariable('PATH', $newPath, $Scope)
        } else {
            Write-Host "  No Cygwin entries found in PATH for scope '$Scope'."
        }

        # Remove CYGWIN var if present
        $cygwinVar = [Environment]::GetEnvironmentVariable('CYGWIN', $Scope)
        if ($cygwinVar) {
            Write-Host "  Removing CYGWIN variable from scope '$Scope'."
            [Environment]::SetEnvironmentVariable('CYGWIN', $null, $Scope)
        }
    } catch {
        Write-Warning ("  Error cleaning PATH/CYGWIN for scope '{0}': {1}" -f $Scope, $_.Exception.Message)
    }
}

Remove-CygwinFromPath -Scope 'Machine'
Remove-CygwinFromPath -Scope 'User'

#-----------------------------
# 7. Registry cleanup and shortcuts
#-----------------------------
Write-Host "`n[7/7] Cleaning registry keys and shortcuts..." -ForegroundColor Yellow

# Registry keys to remove
$regKeysToRemove = @(
    'HKLM:\SOFTWARE\Cygwin',
    'HKCU:\Software\Cygwin',
    'HKLM:\SOFTWARE\WOW6432Node\Cygwin',
    'HKCU:\Software\Cygnus Solutions',
    'HKLM:\SOFTWARE\Cygnus Solutions',
    'HKLM:\SOFTWARE\WOW6432Node\Cygnus Solutions'
)

foreach ($key in $regKeysToRemove) {
    if (Test-Path $key) {
        Write-Host "  Removing registry key: $key"
        try {
            Remove-Item -Path $key -Recurse -Force -ErrorAction Continue
        } catch {
            Write-Warning ("    Failed to remove registry key {0}: {1}" -f $key, $_.Exception.Message)
        }
    }
}

# Remove Start menu and Desktop shortcuts
Write-Host "  Removing Cygwin shortcuts from Desktop and Start Menu..."

$shortcutPatterns = @('Cygwin*.lnk', 'Cygwin*Terminal*.lnk')

$desktopPaths = @(
    "$env:PUBLIC\Desktop",
    [Environment]::GetFolderPath('Desktop')
)

$startMenuPaths = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
)

$allShortcutRoots = $desktopPaths + $startMenuPaths

foreach ($base in $allShortcutRoots) {
    if (-not (Test-Path $base)) { continue }

    foreach ($pattern in $shortcutPatterns) {
        try {
            Get-Item -Path (Join-Path $base $pattern) -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Write-Host "    Deleting shortcut: $($_.FullName)"
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
        } catch {
            Write-Warning ("    Error while removing shortcuts in {0}: {1}" -f $base, $_.Exception.Message)
        }
    }

    # Remove any Cygwin-specific folders in these locations
    try {
        Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Cygwin*' } |
            ForEach-Object {
                Write-Host "    Deleting folder: $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
    } catch {
        Write-Warning ("    Error while removing Cygwin folders in {0}: {1}" -f $base, $_.Exception.Message)
    }
}

Write-Host "`n=== Cygwin uninstall completed. A reboot is recommended to fully clear loaded DLLs and stale handles. ===" -ForegroundColor Green
