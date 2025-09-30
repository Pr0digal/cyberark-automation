<# 
.SYNOPSIS
  Shadow account/profile cleanup (users + profiles) with junction-safe deletes.

.PARAMETER IncludeAD
  Also remove domain shadow users with SamAccountName like '<prefix>-*' (requires RSAT/AD module).

.PARAMETER RebootWhenDone
  Reboot the server after successful cleanup.

.PARAMETER ProfileRoot
  Root path for user profiles. Default: C:\Users

.PARAMETER ShadowPrefix
  Prefix of shadow accounts. Default: SHDW-

.PARAMETER LogPath
  Path to write a transcript log. Default: %TEMP%\ShadowCleanup-<timestamp>.log

.EXAMPLE
  .\ShadowCleanup.ps1

.EXAMPLE
  .\ShadowCleanup.ps1 -IncludeAD -RebootWhenDone
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$IncludeAD,
  [switch]$RebootWhenDone,
  [string]$ProfileRoot = "C:\Users",
  [string]$ShadowPrefix = "SHDW-",
  [string]$LogPath = ("$env:TEMP\ShadowCleanup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
)

#----- Safety & Setup ---------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
  Write-Error "Run this script in an elevated PowerShell session (Admin)."
  return
}

Start-Transcript -Path $LogPath -ErrorAction SilentlyContinue | Out-Null
Write-Host "Logging to: $LogPath"

$shadowPattern = "$ShadowPrefix*"

function Normalize-ShadowName {
  param([string]$Name)
  if (-not $Name) { return $null }
  # Example: 'SHDW-XYZ.NODE-01' -> 'SHDW-XYZ'
  return ($Name -replace '\..*$','')
}

#----- 1) Discover 'active' shadow identities --------------------------------
$activeInteractive = @()
try {
  $quser = (& quser 2>$null)
  if ($quser) {
    $activeInteractive = $quser |
      Select-Object -Skip 1 |
      ForEach-Object {
        # remove leading '>' and split
        ($_ -replace '^\>','') -split '\s+' | Select-Object -First 1
      } |
      Where-Object { $_ -and $_ -ne 'USERNAME' } |
      Sort-Object -Unique
  }
} catch { }

$loadedProfiles = @()
try {
  $loadedProfiles = Get-CimInstance Win32_UserProfile |
    Where-Object { $_.Loaded -eq $true -and $_.LocalPath -like (Join-Path $ProfileRoot $shadowPattern) } |
    ForEach-Object { Split-Path $_.LocalPath -Leaf }
} catch { }

$activeNormalized = New-Object System.Collections.Generic.HashSet[string]
foreach ($u in $activeInteractive)       { [void]$activeNormalized.Add((Normalize-ShadowName $u)) }
foreach ($lp in $loadedProfiles)         { [void]$activeNormalized.Add((Normalize-ShadowName $lp)) }

if ($activeNormalized.Count -gt 0) {
  Write-Host "Active/loaded shadow profiles (normalized): $($activeNormalized -join ', ')"
} else {
  Write-Host "No active interactive sessions or loaded shadow profiles detected."
}

#----- Helpers ----------------------------------------------------------------
function Remove-ProfileFolder {
  param([Parameter(Mandatory)][string]$Path)

  # Attempt to delete via WMI provider first (unloads hives if applicable)
  try {
    $wmi = Get-CimInstance Win32_UserProfile -Filter "LocalPath='$($Path.Replace('\','\\'))'" -ErrorAction SilentlyContinue
    if ($wmi -and -not $wmi.Loaded) {
      Remove-CimInstance -InputObject $wmi -ErrorAction SilentlyContinue
    }
  } catch { }

  # Junction-safe delete: skip "Application Data" junction; if blocked, use robocopy mirror trick
  try {
    if (Test-Path -LiteralPath $Path) {
      # Take ownership/permissions just in case
      try { & takeown.exe /F $Path /R /D Y > $null } catch {}
      try { & icacls.exe $Path /grant "*S-1-5-32-544:(OI)(CI)F" /T > $null } catch {}

      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop -Exclude 'Application Data'
      Write-Output "Removed profile folder: $Path"
      return
    }
  } catch {
    Write-Warning "Standard delete blocked for: $Path — trying robocopy mirror method..."
  }

  # Fallback: robocopy an empty folder to mirror-delete contents, then remove the root
  try {
    $empty = Join-Path $env:TEMP "empty_dir_shadow_cleanup"
    if (-not (Test-Path $empty)) { New-Item -ItemType Directory -Path $empty | Out-Null }
    & robocopy $empty $Path /MIR | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $Path)) {
      Write-Output "Force-removed profile folder (robocopy method): $Path"
    } else {
      Write-Warning "Could not fully remove: $Path"
    }
  } catch {
    Write-Warning "Robocopy method failed for: $Path — $_"
  }
}

# Remove stale ProfileList entries that reference our shadow profiles
function Remove-StaleProfileListEntries {
  $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  if (-not (Test-Path $profileListKey)) { return }
  Get-ChildItem $profileListKey | ForEach-Object {
    try {
      $pi = Get-ItemProperty $_.PSPath -ErrorAction Stop
      $p  = $pi.ProfileImagePath
      if ($p -and ($p -like (Join-Path $ProfileRoot $shadowPattern))) {
        $base = Normalize-ShadowName (Split-Path $p -Leaf)
        if (-not $activeNormalized.Contains($base)) {
          Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
          Write-Output "Removed stale ProfileList entry for: $p"
        } else {
          Write-Output "Skipping ProfileList entry (active): $p"
        }
      }
    } catch { }
  }
}

#----- 2) Remove orphaned LOCAL shadow users ----------------------------------
try {
  $localShadows = Get-LocalUser | Where-Object { $_.Name -like $shadowPattern }
} catch {
  $localShadows = @()
}

foreach ($user in $localShadows) {
  $norm = Normalize-ShadowName $user.Name
  if ($activeNormalized.Contains($norm)) {
    Write-Output "Skipping active local shadow user: $($user.Name)"
    continue
  }
  if ($PSCmdlet.ShouldProcess($user.Name, "Remove-LocalUser")) {
    try {
      Remove-LocalUser -Name $user.Name -ErrorAction Stop
      Write-Output "Removed local shadow user: $($user.Name)"
    } catch {
      Write-Warning "Failed to remove local user $($user.Name): $_"
    }
  }
}

#----- 3) (Optional) Remove orphaned DOMAIN shadow users ----------------------
if ($IncludeAD) {
  try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $adShadows = Get-ADUser -Filter "SamAccountName -like '$shadowPattern'" -ErrorAction Stop
    foreach ($u in $adShadows) {
      $norm = Normalize-ShadowName $u.SamAccountName
      if ($activeNormalized.Contains($norm)) {
        Write-Output "Skipping active AD shadow user: $($u.SamAccountName)"
        continue
      }
      if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Remove-ADUser")) {
        try {
          Remove-ADUser -Identity $u.DistinguishedName -Confirm:$false -ErrorAction Stop
          Write-Output "Removed AD shadow user: $($u.SamAccountName)"
        } catch {
          Write-Warning "Failed to remove AD user $($u.SamAccountName): $_"
        }
      }
    }
  } catch {
    Write-Warning "ActiveDirectory module not available or query failed: $_"
  }
}

#----- 4) Clean up stale ProfileList entries ----------------------------------
Remove-StaleProfileListEntries

#----- 5) Delete orphaned profile folders (junction-safe) ---------------------
$profiles = @()
try {
  $profiles = Get-ChildItem $ProfileRoot -Directory | Where-Object { $_.Name -like $shadowPattern }
} catch { }

foreach ($profile in $profiles) {
  $norm = Normalize-ShadowName $profile.Name
  if ($activeNormalized.Contains($norm)) {
    Write-Output "Skipping active/loaded profile: $($profile.FullName)"
    continue
  }
  if ($PSCmdlet.ShouldProcess($profile.FullName, "Remove profile folder")) {
    Remove-ProfileFolder -Path $profile.FullName
  }
}

Write-Host "Cleanup complete."

Stop-Transcript | Out-Null

if ($RebootWhenDone) {
  Write-Host "Rebooting now..." 
  Restart-Computer -Force
} else {
  Write-Host "Recommend rebooting when convenient."
}
