<#
.SYNOPSIS
Validates and repairs expected mapped network drives.

.DESCRIPTION
Compares a user-maintained list of expected drive-letter-to-UNC-path mappings
against the currently active mapped drives on the local system.

For each expected mapping, the script:
1. Verifies whether the drive letter exists.
2. Verifies whether the existing mapping path matches the expected path.
3. Prompts the user to repair discrepancies (y/n).
4. If approved, removes the incorrect mapping (when present) and recreates it
   with the expected drive letter and path.

Designed for Windows 10/11 with PowerShell 7.4 or later.

.PARAMETER SkipPlatformChecks
Skips Windows and OS-version validation checks. Intended for testing only.

.PARAMETER NonInteractive
Suppresses Read-Host prompts. Repair decisions are taken from -DefaultRepairYes.

.PARAMETER DefaultRepairYes
When -NonInteractive is used, repairs are automatically approved if this switch
is set; otherwise repairs are declined.

.EXAMPLE
.\Validate-MappedDrives.ps1
Runs interactively. Prompts y/n for each missing or mismatched mapping.

.EXAMPLE
.\Validate-MappedDrives.ps1 -WhatIf
Shows what would be removed/recreated without making changes.

.EXAMPLE
.\Validate-MappedDrives.ps1 -SkipPlatformChecks -NonInteractive
Testing mode: skips platform checks and evaluates discrepancies without repairs.

.INPUTS
None. The script uses the hardcoded mapping array in this file.

.OUTPUTS
System.String. Status output is written to the host/console.

.NOTES
Update $ExpectedDriveMappings below with your actual drive letters and UNC paths.
Drive letters can be entered with or without a trailing colon.

.COMPONENT
Drive Mapping Validation

.ROLE
Workstation maintenance

.FUNCTIONALITY
Validation, remediation, and interactive repair of mapped network drives.

.LINK
https://learn.microsoft.com/powershell/module/microsoft.powershell.management/new-psdrive
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipPlatformChecks,
    [switch]$NonInteractive,
    [switch]$DefaultRepairYes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# USER CONFIGURATION: Hardcode expected mappings here.
# ---------------------------------------------------------------------------
$ExpectedDriveMappings = @(
    @{
        DriveLetter = "H"
        Path        = "\\fileserver\home"
    },
    @{
        DriveLetter = "S"
        Path        = "\\fileserver\shared"
    }
)

function Normalize-DriveLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    return $DriveLetter.Trim().TrimEnd(":").ToUpperInvariant()
}

function Normalize-MappingPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $trimmed = $Path.Trim()
    return $trimmed.TrimEnd("\", "/")
}

function Get-CurrentMappedDriveTable {
    [CmdletBinding()]
    param()

    $mappedDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        ($_.DisplayRoot -and $_.DisplayRoot -like "\\*") -or ($_.Root -like "\\*")
    }

    $result = @{}
    foreach ($drive in $mappedDrives) {
        $name = $drive.Name.ToUpperInvariant()
        $path = if ([string]::IsNullOrWhiteSpace($drive.DisplayRoot)) {
            $drive.Root
        }
        else {
            $drive.DisplayRoot
        }

        $result[$name] = $path
    }

    return $result
}

function Should-RepairMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [string]$ExpectedPath,

        [string]$CurrentPath,
        [switch]$NonInteractive,
        [switch]$DefaultRepairYes
    )

    if ($NonInteractive) {
        return [bool]$DefaultRepairYes
    }

    if ([string]::IsNullOrWhiteSpace($CurrentPath)) {
        $prompt = "Drive $DriveLetter`: is missing. Map it to '$ExpectedPath'? (y/n)"
    }
    else {
        $prompt = "Drive $DriveLetter`: is '$CurrentPath' but expected '$ExpectedPath'. Repair it? (y/n)"
    }

    while ($true) {
        $response = (Read-Host -Prompt $prompt).Trim().ToLowerInvariant()

        if ($response -in @("y", "yes")) {
            return $true
        }

        if ($response -in @("n", "no")) {
            return $false
        }

        Write-Host "Please answer y or n." -ForegroundColor Yellow
    }
}

function Repair-MappedDrive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [string]$ExpectedPath,

        [switch]$ExistsWithWrongPath
    )

    if ($ExistsWithWrongPath) {
        if ($PSCmdlet.ShouldProcess("$DriveLetter`:", "Remove existing mapping")) {
            Remove-PSDrive -Name $DriveLetter -Force -ErrorAction Stop
            Write-Host "Removed existing mapping for drive $DriveLetter`."
        }
    }

    if ($PSCmdlet.ShouldProcess("$DriveLetter`:", "Create mapping to '$ExpectedPath'")) {
        New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $ExpectedPath -Persist -Scope Global -ErrorAction Stop | Out-Null
        Write-Host "Mapped drive $DriveLetter`: to '$ExpectedPath'."
    }
}

if ($PSVersionTable.PSVersion -lt [version]"7.4.0") {
    throw "PowerShell 7.4 or later is required. Current version: $($PSVersionTable.PSVersion)"
}

if (-not $SkipPlatformChecks) {
    if (-not $IsWindows) {
        throw "This script is intended for Windows 10/11. Use -SkipPlatformChecks only for testing."
    }

    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    if ($caption -notmatch "Windows 10|Windows 11") {
        throw "Unsupported operating system detected: '$caption'. This script supports Windows 10/11."
    }
}

$currentMappings = Get-CurrentMappedDriveTable
$issuesFound = 0
$repairsPerformed = 0

foreach ($mapping in $ExpectedDriveMappings) {
    $driveLetterRaw = [string]$mapping.DriveLetter
    $expectedPathRaw = [string]$mapping.Path

    if ([string]::IsNullOrWhiteSpace($driveLetterRaw) -or [string]::IsNullOrWhiteSpace($expectedPathRaw)) {
        throw "Each mapping in `$ExpectedDriveMappings must contain non-empty DriveLetter and Path values."
    }

    $driveLetter = Normalize-DriveLetter -DriveLetter $driveLetterRaw
    $expectedPath = Normalize-MappingPath -Path $expectedPathRaw

    $exists = $currentMappings.ContainsKey($driveLetter)
    $currentPath = if ($exists) { [string]$currentMappings[$driveLetter] } else { $null }
    $matches = $exists -and ((Normalize-MappingPath -Path $currentPath) -ieq $expectedPath)

    if ($matches) {
        Write-Host "[OK] $driveLetter`: mapped correctly to '$expectedPath'."
        continue
    }

    $issuesFound++
    if (-not $exists) {
        Write-Warning "Drive $driveLetter`: is missing. Expected '$expectedPath'."
    }
    else {
        Write-Warning "Drive $driveLetter`: mismatch. Current '$currentPath' | Expected '$expectedPath'."
    }

    $repair = Should-RepairMapping -DriveLetter $driveLetter -ExpectedPath $expectedPath -CurrentPath $currentPath -NonInteractive:$NonInteractive -DefaultRepairYes:$DefaultRepairYes
    if (-not $repair) {
        Write-Host "Skipped repair for drive $driveLetter`."
        continue
    }

    Repair-MappedDrive -DriveLetter $driveLetter -ExpectedPath $expectedPath -ExistsWithWrongPath:$exists
    $repairsPerformed++
}

if ($issuesFound -eq 0) {
    Write-Host "Validation complete. No discrepancies found."
}
else {
    Write-Host "Validation complete. Discrepancies: $issuesFound | Repairs attempted: $repairsPerformed."
}
