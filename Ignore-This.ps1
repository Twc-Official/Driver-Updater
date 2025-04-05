# Ignore this - Since I can't find a way for Github to show the language charts for the Releases, I have to resort to this :(
## This is a really old version of the script (I think)

param (
    [switch]$VerboseLog
)

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Restarting script with administrator privileges..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

if ((Get-ExecutionPolicy -Scope Process) -ne "Bypass") {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Initialize the log content as an array
$LogContent = @()


function Log {
    param (
        [string]$Message,
        [ConsoleColor]$Color = "Gray",
        [switch]$Silent
    )
    # Append the message to the global log content
    $global:LogContent += $Message
    if (-not $Silent) {
        Write-Host $Message -ForegroundColor $Color
    }
}


function Ensure-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Log "[ERROR] This script requires administrator privileges to run." Red
        Write-Host "Please re-run this script as an administrator." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit
    }
}

function Create-SystemRestorePoint {
    Log "`n[INFO] Creating a system restore point..." Cyan
    try {
        $restorePointName = "Driver Update Script - $(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
        $restorePointResult = Checkpoint-Computer -Description $restorePointName -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Log "[SUCCESS] System restore point created: $restorePointName" Green
    } catch {
        Log "[ERROR] Failed to create a system restore point." Red
        if ($VerboseLog) { Log $_.Exception.Message DarkRed }
    }
}

function Get-InstalledDrivers {
    Log "`n[INFO] Scanning installed drivers..." Cyan
    $drivers = Get-WmiObject Win32_PnPSignedDriver | Select-Object DeviceName, DriverVersion, Manufacturer, InfName

    foreach ($driver in $drivers) {
        if (-not $driver.DeviceName) { continue }
        $manufacturer = if ($driver.Manufacturer) { $driver.Manufacturer } else { "Unknown Manufacturer" }
        $device = if ($driver.DeviceName) { $driver.DeviceName } else { "Unknown Device" }
        Log "[SCANNED] $manufacturer // $device" DarkGray
    }

    return $drivers
}

function Get-DriverUpdates {
    Log "`n[INFO] Checking for available driver updates..." Cyan
    $updateResults = @()
    $driverStorePath = "$env:SystemRoot\System32\DriverStore\FileRepository"

    foreach ($driver in Get-WmiObject Win32_PnPSignedDriver) {
        if (-not $driver.InfName -or -not $driver.DeviceName) { continue }

        $driverInfo = [PSCustomObject]@{
            Device        = $driver.DeviceName
            CurrentVer    = $driver.DriverVersion
            INFName       = $driver.InfName
            Manufacturer  = if ($driver.Manufacturer) { $driver.Manufacturer } else { "Unknown Manufacturer" }
            AvailableVer  = $null
            INFPath       = $null
            NeedsUpdate   = $false
        }

        if ($VerboseLog) {
            Log "[SCANNED] $($driverInfo.Manufacturer) // $($driverInfo.Device)" DarkGray
        }

        try {
            $infFolder = Get-ChildItem -Directory -Path $driverStorePath | Where-Object {
                $_.Name -like "$($driverInfo.INFName.Split('.')[0])*"
            } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if ($infFolder) {
                $infFullPath = Join-Path $infFolder.FullName $driverInfo.INFName
                if (Test-Path $infFullPath) {
                    $driverInfo.INFPath = $infFullPath

                    $infVersionLine = Select-String -Path $infFullPath -Pattern "DriverVer\s*=" | Select-Object -First 1
                    $version = $infVersionLine -replace ".*,", ""
                    $parsedNewVer = [version]$version
                    $parsedCurrentVer = [version]$driver.DriverVersion

                    if ($parsedNewVer -gt $parsedCurrentVer) {
                        $driverInfo.AvailableVer = $parsedNewVer
                        $driverInfo.NeedsUpdate = $true
                        $updateResults += $driverInfo
                    }
                }
            }
        } catch {
            Log "[ERROR] Failed to process driver: $($driver.DeviceName)" Red
            if ($VerboseLog) { Log $_.Exception.Message DarkRed }
        }
    }

    return $updateResults
}

function Get-DriversFromWindowsUpdate {
    Log "`n[INFO] Checking for driver updates via Windows Update..." Cyan

    try {
        # Ensure the PSWindowsUpdate module is installed
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser
        }

        Import-Module PSWindowsUpdate

        # Get available updates
        $updates = Get-WindowsUpdate -MicrosoftUpdate -Category Drivers -ErrorAction Stop

        if ($updates.Count -eq 0) {
            Log "[INFO] No driver updates found via Windows Update." Green
            return @()
        }

        $driverUpdates = @()
        foreach ($update in $updates) {
            $driverUpdates += [PSCustomObject]@{
                Device        = $update.Title
                Manufacturer  = "Windows Update"
                CurrentVer    = "Unknown"
                AvailableVer  = $update.KBArticleIDs -join ", "
                INFPath       = "Windows Update"
                NeedsUpdate   = $true
            }
        }

        Log "[INFO] Found $($driverUpdates.Count) driver updates via Windows Update." Yellow
        return $driverUpdates
    } catch {
        Log "[ERROR] Failed to fetch updates from Windows Update." Red
        if ($VerboseLog) { Log $_.Exception.Message DarkRed }
        return @()
    }
}

function Write-LogToFile {
    # Debugging: Print the current log content
    Log "`n[DEBUG] Current log content before saving: $($global:LogContent -join "`n")" Cyan

    # Ensure the log content is not empty
    if (-not $global:LogContent -or $global:LogContent.Count -eq 0) {
        Log "[WARNING] No log content to save." Yellow
        return
    }

    # Generate a timestamped log file path
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logFolder = Join-Path $env:USERPROFILE "Documents\DriverUpdateLogs"
    if (-not (Test-Path $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder | Out-Null
    }

    $logPath = Join-Path $logFolder "UpdateCheck_$timestamp.log"

    try {
        # Write the log content to the file
        $global:LogContent | Out-File -FilePath $logPath -Encoding UTF8
        Log "`n[LOG] Log saved to: $logPath" Green
    } catch {
        Log "[ERROR] Failed to save the log file." Red
        if ($VerboseLog) { Log $_.Exception.Message DarkRed }
    }
}

function Ask-To-Save-Log {
    $save = Read-Host "`nDo you want to save a .log file in Documents\DriverUpdateLogs? (Y/N)"
    if ($save -match "^[Yy]$") {
        Write-LogToFile
    } else {
        Log "[INFO] Log file skipped." Red
        $openLog = Read-Host "`nDo you want to open the log in the console instead? (Y/N)"
        if ($openLog -match "^[Yy]$") {
            Log "`n[INFO] Displaying log content in the console:" Cyan
            $global:LogContent | ForEach-Object { Write-Host $_ }
        }
        Start-Sleep -Seconds 2
    }
}

function Update-Drivers {
    param ($driversToUpdate)

    if (-not $driversToUpdate -or $driversToUpdate.Count -eq 0) {
        Log "`n[INFO] No driver updates available." Green
        $choice = Read-Host "`nNo updates found. Quit process? (Y/N)"
        if ($choice -match "^[Yy]$") {
            Ask-To-Save-Log
            Log "[EXIT] Ending script as requested." Cyan
            exit
        } else {
            Log "[CONTINUE] Proceeding with script..." Yellow
            Ask-To-Save-Log
            return
        }
    }

    Log "`n[INFO] The following drivers have updates available:" Yellow
    $driversToUpdate | Format-Table Device, Manufacturer, CurrentVer, AvailableVer, INFPath -AutoSize | Out-String | ForEach-Object { Log $_ }

    $choice = Read-Host "`nDo you want to update these drivers? (Y/N)"
    if ($choice -match "^[Yy]$") {
        foreach ($driver in $driversToUpdate) {
            if ($driver.INFPath -eq "Windows Update") {
                Log "`n[UPDATING] $($driver.Device) via Windows Update..." Yellow
                try {
                    Install-WindowsUpdate -KBArticleID $driver.AvailableVer -AcceptAll -ErrorAction Stop
                    Log "[SUCCESS] Updated $($driver.Device) via Windows Update" Green
                } catch {
                    Log "[FAILURE] Could not update $($driver.Device) via Windows Update." Red
                    if ($VerboseLog) { Log $_.Exception.Message DarkRed }
                }
            } else {
                Log "`n[UPDATING] $($driver.Device) (From $($driver.CurrentVer) to $($driver.AvailableVer))..." Yellow
                $updateResult = pnputil /add-driver "`"$($driver.INFPath)`"" /install

                if ($LASTEXITCODE -eq 0) {
                    Log "[SUCCESS] Updated $($driver.Device) to version $($driver.AvailableVer)" Green
                } else {
                    Log "[FAILURE] Could not update $($driver.Device). INF install may not be supported." Red
                    if ($VerboseLog) {
                        Log $updateResult DarkRed
                    }
                }
            }
        }

        Log "`n[INFO] Driver update process completed!" Green
        Ask-To-Save-Log
    } else {
        Log "`n[INFO] Driver update skipped." Red
        Ask-To-Save-Log
    }
}

# MAIN
Ensure-Admin

# Ask for verbose logging ONLY in PowerShell (not IDEs like VSCode)
if (-not $VerboseLog -and $Host.Name -eq "ConsoleHost") {
    $enableVerbose = Read-Host "Enable verbose logging? (Y/N)"
    if ($enableVerbose -match "^[Yy]$") {
        $VerboseLog = $true
    }
}
Log "[INFO] Script started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" DarkMagenta
# Create a system restore point
Create-SystemRestorePoint

$installedDrivers = Get-InstalledDrivers
$updatesFromINF = Get-DriverUpdates
$updatesFromWU = Get-DriversFromWindowsUpdate

$allUpdates = $updatesFromINF + $updatesFromWU
Update-Drivers -driversToUpdate $allUpdates

# Made by @Twc-Official on Github.
