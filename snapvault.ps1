<#
.SYNOPSIS
    SnapVault (snapvault.ps1) - Backs up photos/videos from an Android phone (MTP) to
    a removable drive (pendrive / external SSD / SD card) on Windows.

.DESCRIPTION
    - Auto-detects your removable drive and phone folders on first run.
    - Remembers your choice in a config file so future runs are one command.
    - Only copies NEW files since the last backup (no duplicates, no re-copying).
    - Asks for confirmation before starting each time.

    HOW IT WORKS:
    Windows doesn't expose MTP phones as a normal file path the way Linux
    does, so this script talks to the phone through the same Shell COM
    interface Windows Explorer uses ("This PC" > your phone). For each file,
    it checks whether a file of the same name already exists in the
    destination folder, and only copies it if not - the same "no duplicates"
    idea as the Linux version's `rsync --ignore-existing`.

.PARAMETER DryRun
    Preview what would be copied without actually copying anything.

.PARAMETER Setup
    Re-run setup (pick a different drive/folders).

.NOTES
    Run this with Windows PowerShell (powershell.exe), not PowerShell 7+
    (pwsh.exe) - the Shell.Application COM object used to browse the phone
    is most reliable there.

    Known limitation: copying is driven by Windows Explorer's Shell COM
    interface, which doesn't give a clean "copy finished" signal for large
    files. The script polls for the file to appear as a basic safeguard.
    If you hit issues with large videos, please open an issue / PR.
#>

param(
    [switch]$DryRun,
    [switch]$Setup
)

$ErrorActionPreference = "Stop"

$ConfigDir  = Join-Path $env:USERPROFILE ".config\snapvault"
$ConfigFile = Join-Path $ConfigDir "config.json"

function Write-Log($msg) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
}

# ------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-Warning "You're running PowerShell 7+ (pwsh). The phone-browsing COM interface"
    Write-Warning "is most reliable on Windows PowerShell 5.1 (powershell.exe). If phone"
    Write-Warning "detection fails below, try re-running from powershell.exe instead."
    Write-Host ""
}

# ------------------------------------------------------------------
# 1. Detect the phone via the Shell "This PC" namespace
# ------------------------------------------------------------------
function Get-ShellApp {
    New-Object -ComObject Shell.Application
}

function Get-PortableDevices {
    $shell = Get-ShellApp
    $thisPC = $shell.NameSpace(0x11)  # "This PC"
    $devices = @()
    foreach ($item in $thisPC.Items()) {
        # Drive letters look like "C:\" - anything else browsable is a
        # portable device (phone, camera, etc.)
        if ($item.IsFolder -and $item.Path -notmatch '^[A-Za-z]:\\?$') {
            $devices += $item
        }
    }
    return $devices
}

function Select-Phone {
    Write-Host "Looking for your Android phone..."
    $devices = Get-PortableDevices

    if ($devices.Count -eq 0) {
        Write-Host "Couldn't detect your phone."
        Write-Host "Try: unlock your phone screen, set USB mode to 'File Transfer (MTP)',"
        Write-Host "then open File Explorer once so Windows detects it, and re-run this script."
        return $null
    }

    if ($devices.Count -eq 1) {
        Write-Host "Phone found: $($devices[0].Name)"
        return $devices[0]
    }

    Write-Host "Multiple devices found:"
    for ($i = 0; $i -lt $devices.Count; $i++) {
        Write-Host "  $($i+1)) $($devices[$i].Name)"
    }
    $choice = Read-Host "Which one is your phone? [1-$($devices.Count)]"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $devices.Count) {
        return $devices[[int]$choice - 1]
    }
    return $null
}

function Get-StorageRoot($phoneItem) {
    # Phones usually expose one top-level folder, e.g. "Internal shared storage"
    $folder = $phoneItem.GetFolder()
    foreach ($item in $folder.Items()) {
        if ($item.IsFolder) { return $item }
    }
    return $null
}

function Find-SubFolder($rootItem, [string]$relativePath) {
    $current = $rootItem
    foreach ($part in $relativePath -split '[\\/]') {
        if (-not $current) { return $null }
        $folder = $current.GetFolder()
        $next = $null
        foreach ($item in $folder.Items()) {
            if ($item.Name -eq $part) { $next = $item; break }
        }
        $current = $next
    }
    return $current
}

# ------------------------------------------------------------------
# 2. Detect removable drives
# ------------------------------------------------------------------
function Get-RemovableDrives {
    Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } |
        ForEach-Object { "$($_.DriveLetter):\" }
}

function Select-Drive {
    $drives = @(Get-RemovableDrives)

    if ($drives.Count -eq 0) {
        Write-Host "No removable drive detected."
        $manual = Read-Host "Type a folder path to use instead (e.g. D:\)"
        if ($manual -and (Test-Path $manual)) { return $manual }
        return $null
    }

    if ($drives.Count -eq 1) {
        Write-Host "Found drive: $($drives[0])"
        return $drives[0]
    }

    Write-Host "Multiple removable drives found:"
    for ($i = 0; $i -lt $drives.Count; $i++) {
        Write-Host "  $($i+1)) $($drives[$i])"
    }
    $choice = Read-Host "Which one is your backup drive? [1-$($drives.Count)]"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $drives.Count) {
        return $drives[[int]$choice - 1]
    }
    return $null
}

# ------------------------------------------------------------------
# 3. Detect phone subfolders worth offering
# ------------------------------------------------------------------
function Select-Subfolders($storageRoot) {
    $common = @("DCIM\Camera", "DCIM\Screenshots", "Pictures", "Movies", "Download")
    $found = @()
    foreach ($f in $common) {
        if (Find-SubFolder -rootItem $storageRoot -relativePath $f) {
            $found += $f
        }
    }

    if ($found.Count -eq 0) {
        Write-Host "Couldn't find common folders (DCIM\Camera, Pictures, ...) on the phone."
        $manual = Read-Host "Enter folder(s) to back up, comma-separated, relative to phone storage root"
        return ($manual -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    Write-Host "Found these folders on your phone:"
    for ($i = 0; $i -lt $found.Count; $i++) {
        Write-Host "  $($i+1)) $($found[$i])"
    }
    Write-Host ""
    $sel = Read-Host "Back up which ones? (e.g. 1,2 or 'all') [all]"
    if (-not $sel) { $sel = "all" }

    if ($sel -eq "all") { return $found }

    $picked = @()
    foreach ($idx in ($sel -split ',')) {
        $idx = $idx.Trim()
        if ($idx -match '^\d+$' -and [int]$idx -ge 1 -and [int]$idx -le $found.Count) {
            $picked += $found[[int]$idx - 1]
        }
    }
    return $picked
}

# ------------------------------------------------------------------
# 4. Setup (first run, or -Setup)
# ------------------------------------------------------------------
function Run-Setup {
    Write-Host "=== First-time setup ==="
    Write-Host ""

    $drive = Select-Drive
    if (-not $drive) { Write-Host "No drive selected. Aborting."; exit 1 }

    $backupDir = Join-Path $drive "PhoneBackup"

    $phone = Select-Phone
    if (-not $phone) { Write-Host "No phone detected. Aborting."; exit 1 }

    $storageRoot = Get-StorageRoot $phone
    if (-not $storageRoot) { Write-Host "Couldn't open phone storage. Aborting."; exit 1 }

    Write-Host ""
    $subfolders = @(Select-Subfolders $storageRoot)
    if ($subfolders.Count -eq 0) { Write-Host "No folders selected. Aborting."; exit 1 }

    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $config = @{
        BackupDrive      = $drive
        BackupDir        = $backupDir
        PhoneSubfolders  = $subfolders
    }
    $config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8

    Write-Host ""
    Write-Host "Setup saved to $ConfigFile"
    Write-Host "  Drive:   $drive"
    Write-Host "  Backups: $backupDir"
    Write-Host "  Folders: $($subfolders -join ', ')"
    Write-Host ""
    Write-Host "Run this script again anytime - it'll reuse this config."
    Write-Host "Use -Setup to change these choices later."
}

if ($Setup -or -not (Test-Path $ConfigFile)) {
    Run-Setup
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# ------------------------------------------------------------------
# 5. Verify the configured drive is still there
# ------------------------------------------------------------------
if (-not (Test-Path $config.BackupDrive)) {
    Write-Host "Can't find your configured drive at: $($config.BackupDrive)"
    Write-Host "Is it plugged in? Or run '.\snapvault.ps1 -Setup' to pick a different one."
    exit 1
}

New-Item -ItemType Directory -Force -Path $config.BackupDir | Out-Null

if ($DryRun) {
    Write-Host "*** DRY RUN MODE: no files will actually be copied ***"
    Write-Host ""
}

Write-Host "Backup destination: $($config.BackupDir)"
Write-Host "Folders to back up: $($config.PhoneSubfolders -join ', ')"
Write-Host ""

# Re-detect the phone (COM handles/paths don't persist across runs)
$phone = Select-Phone
if (-not $phone) { exit 1 }
$storageRoot = Get-StorageRoot $phone
if (-not $storageRoot) {
    Write-Host "Phone detected but its storage folder couldn't be opened."
    Write-Host "Make sure the phone is unlocked and set to File Transfer mode."
    exit 1
}
Write-Host ""

# ------------------------------------------------------------------
# 6. Confirm
# ------------------------------------------------------------------
$confirm = Read-Host "Do you want to backup now? (y/n)"
if ($confirm -notmatch '^(y|yes)$') {
    Write-Host "Backup cancelled."
    exit 0
}
Write-Host ""

# ------------------------------------------------------------------
# 7. Copy new files (recursively), skipping anything already present
# ------------------------------------------------------------------
function Copy-FolderNew {
    param($SrcItem, [string]$DestPath, [switch]$DryRun)

    New-Item -ItemType Directory -Force -Path $DestPath | Out-Null
    $srcFolder = $SrcItem.GetFolder()
    $shell = Get-ShellApp
    $newCount = 0

    foreach ($child in $srcFolder.Items()) {
        if ($child.IsFolder) {
            $childDest = Join-Path $DestPath $child.Name
            $newCount += Copy-FolderNew -SrcItem $child -DestPath $childDest -DryRun:$DryRun
            continue
        }

        $destFile = Join-Path $DestPath $child.Name
        if (Test-Path $destFile) { continue }

        if (-not $DryRun) {
            $destFolderObj = $shell.NameSpace($DestPath)
            # 4 = no progress dialog, 16 = respond "yes to all", 512 = no overwrite confirm
            $destFolderObj.CopyHere($child, 4 + 16 + 512)

            $waited = 0
            while (-not (Test-Path $destFile) -and $waited -lt 60) {
                Start-Sleep -Milliseconds 500
                $waited++
            }
        }

        Write-Host "    + $destFile"
        $newCount++
    }

    return $newCount
}

$totalNew = 0
foreach ($sub in $config.PhoneSubfolders) {
    $srcItem = Find-SubFolder -rootItem $storageRoot -relativePath $sub
    $destPath = Join-Path $config.BackupDir $sub

    if (-not $srcItem) {
        Write-Log "Skipping '$sub' (not found on phone)"
        continue
    }

    Write-Log "Syncing '$sub' ..."
    $count = Copy-FolderNew -SrcItem $srcItem -DestPath $destPath -DryRun:$DryRun
    $totalNew += $count
    Write-Log "'$sub': $count new file(s) copied"
}

Write-Host ""
Write-Log "Backup finished. Total new files copied: $totalNew"
Write-Host "Done. $totalNew new file(s) backed up to $($config.BackupDir)"
