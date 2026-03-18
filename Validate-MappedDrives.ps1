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

.PARAMETER Credential
Optional credential to use when a mapping attempt fails with authentication errors
such as access denied or invalid password.
If omitted, the script prompts with Get-Credential when needed (interactive mode).

.PARAMETER DoNotStoreCredential
Prevents the script from saving prompted/supplied credentials to Windows
Credential Manager via cmdkey.exe.

.EXAMPLE
.\Validate-MappedDrives.ps1
Runs interactively. Prompts y/n for each missing or mismatched mapping.

.EXAMPLE
.\Validate-MappedDrives.ps1 -WhatIf
Shows what would be removed/recreated without making changes.

.EXAMPLE
.\Validate-MappedDrives.ps1 -SkipPlatformChecks -NonInteractive
Testing mode: skips platform checks and evaluates discrepancies without repairs.

.EXAMPLE
.\Validate-MappedDrives.ps1 -Credential (Get-Credential)
Supplies credentials up front for any access-denied mapping retries.

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
    [switch]$DefaultRepairYes,
    [PSCredential]$Credential,
    [switch]$DoNotStoreCredential
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

function Test-IsAuthenticationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
            $messages.Add($exception.Message)
        }

        $exception = $exception.InnerException
    }

    if ($messages.Count -eq 0) {
        $messages.Add([string]$ErrorRecord)
    }

    $combinedMessage = ($messages -join "`n")
    return $combinedMessage -match "(?i)(access is denied|specified network password is not correct|logon failure|unknown user name or bad password|username or password is incorrect)"
}

function Test-IsRememberedConnectionFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
            $messages.Add($exception.Message)
        }

        $exception = $exception.InnerException
    }

    if ($messages.Count -eq 0) {
        $messages.Add([string]$ErrorRecord)
    }

    $combinedMessage = ($messages -join "`n")
    return $combinedMessage -match "(?i)(remembered connection to another network resource|device name is already in use)"
}

function Clear-RememberedDriveConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    $normalizedDriveLetter = Normalize-DriveLetter -DriveLetter $DriveLetter
    $driveWithColon = "$normalizedDriveLetter`:"

    try {
        Remove-PSDrive -Name $normalizedDriveLetter -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to remove existing PSDrive '$driveWithColon' before retry: $($_.Exception.Message)"
    }

    if (-not $IsWindows) {
        return
    }

    $netCommand = Get-Command -Name "net.exe" -ErrorAction SilentlyContinue
    if (-not $netCommand) {
        Write-Warning "net.exe was not found; unable to clear remembered connection for drive $driveWithColon."
        return
    }

    $netOutput = & $netCommand.Source use $driveWithColon /delete /y 2>&1
    $netOutputText = ($netOutput -join [Environment]::NewLine)

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Cleared remembered connection for drive $driveWithColon."
        return
    }

    if ($netOutputText -match "(?i)(network connection could not be found|no entries in the list|network connection does not exist)") {
        return
    }

    Write-Warning "Unable to clear remembered connection for drive $driveWithColon. net use output: $netOutputText"
}

function New-MappedDriveWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [string]$ExpectedPath,

        [PSCredential]$Credential
    )

    $newPsDriveParams = @{
        Name       = $DriveLetter
        PSProvider = "FileSystem"
        Root       = $ExpectedPath
        Persist    = $true
        Scope      = "Global"
        ErrorAction = "Stop"
    }

    if ($Credential) {
        $newPsDriveParams["Credential"] = $Credential
    }

    try {
        New-PSDrive @newPsDriveParams | Out-Null
        return
    }
    catch {
        if (-not (Test-IsRememberedConnectionFailure -ErrorRecord $_)) {
            throw
        }

        Write-Warning "Drive $DriveLetter`: has a remembered connection conflict. Clearing stale connection and retrying."
        Clear-RememberedDriveConnection -DriveLetter $DriveLetter
        New-PSDrive @newPsDriveParams | Out-Null
    }
}

function Repair-MappedDrive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [string]$ExpectedPath,

        [switch]$ExistsWithWrongPath,
        [PSCredential]$Credential,
        [switch]$DoNotStoreCredential,
        [switch]$NonInteractive
    )

    if ($ExistsWithWrongPath) {
        if ($PSCmdlet.ShouldProcess("$DriveLetter`:", "Remove existing mapping")) {
            Remove-PSDrive -Name $DriveLetter -Force -ErrorAction Stop
            Write-Host "Removed existing mapping for drive $DriveLetter`."
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$DriveLetter`:", "Create mapping to '$ExpectedPath'")) {
        return
    }

    try {
        New-MappedDriveWithRetry -DriveLetter $DriveLetter -ExpectedPath $ExpectedPath
        Write-Host "Mapped drive $DriveLetter`: to '$ExpectedPath'."
    }
    catch {
        if (-not (Test-IsAuthenticationFailure -ErrorRecord $_)) {
            throw
        }

        Write-Warning "Authentication failed while mapping drive $DriveLetter`: to '$ExpectedPath'. Attempting credentialed mapping."

        $credentialToUse = $Credential
        $hasPromptedForCredential = $false
        if (-not $credentialToUse) {
            if ($NonInteractive) {
                throw "Authentication failed mapping drive $DriveLetter`: and no -Credential was provided in non-interactive mode."
            }

            $credentialToUse = Get-Credential -Message "Enter credentials for '$ExpectedPath' (drive $DriveLetter`:)"
            $hasPromptedForCredential = $true
        }

        try {
            if (-not $DoNotStoreCredential) {
                Save-CredentialToWindowsCredentialManager -Path $ExpectedPath -Credential $credentialToUse
            }

            New-MappedDriveWithRetry -DriveLetter $DriveLetter -ExpectedPath $ExpectedPath -Credential $credentialToUse
            Write-Host "Mapped drive $DriveLetter`: to '$ExpectedPath' using supplied credentials."
        }
        catch {
            if (-not (Test-IsAuthenticationFailure -ErrorRecord $_)) {
                throw
            }

            if ($NonInteractive -or $hasPromptedForCredential) {
                throw "Credential retry failed mapping drive $DriveLetter`: to '$ExpectedPath'."
            }

            Write-Warning "The supplied credential for drive $DriveLetter`: was rejected. Please enter credentials one more time."
            $credentialToUse = Get-Credential -Message "Credential was rejected for '$ExpectedPath' (drive $DriveLetter`:). Enter credentials one final time."

            if (-not $DoNotStoreCredential) {
                Save-CredentialToWindowsCredentialManager -Path $ExpectedPath -Credential $credentialToUse
            }

            try {
                New-MappedDriveWithRetry -DriveLetter $DriveLetter -ExpectedPath $ExpectedPath -Credential $credentialToUse
                Write-Host "Mapped drive $DriveLetter`: to '$ExpectedPath' using re-entered credentials."
            }
            catch {
                if (Test-IsAuthenticationFailure -ErrorRecord $_) {
                    throw "Credential retry failed mapping drive $DriveLetter`: to '$ExpectedPath'."
                }

                throw
            }
        }
    }
}

function Get-ServerNameFromUncPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -match "^[\\]{2}([^\\]+)\\") {
        return $Matches[1]
    }

    return $null
}

function Save-CredentialToWindowsCredentialManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    if (-not $IsWindows) {
        return
    }

    $server = Get-ServerNameFromUncPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($server)) {
        Write-Warning "Could not extract server name from '$Path'; skipping Credential Manager save."
        return
    }

    $cmdKey = Get-Command -Name "cmdkey.exe" -ErrorAction SilentlyContinue
    if (-not $cmdKey) {
        Write-Warning "cmdkey.exe was not found; skipping Credential Manager save."
        return
    }

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $plainTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

        $cmdOutput = & $cmdKey.Source /add:$server /user:$($Credential.UserName) /pass:$plainTextPassword 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to save credential in Credential Manager for '$server'. cmdkey output: $cmdOutput"
            return
        }

        Write-Host "Saved credential for '$server' in Windows Credential Manager."
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
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

    Repair-MappedDrive -DriveLetter $driveLetter -ExpectedPath $expectedPath -ExistsWithWrongPath:$exists -Credential $Credential -DoNotStoreCredential:$DoNotStoreCredential -NonInteractive:$NonInteractive
    $repairsPerformed++
}

if ($issuesFound -eq 0) {
    Write-Host "Validation complete. No discrepancies found."
}
else {
    Write-Host "Validation complete. Discrepancies: $issuesFound | Repairs attempted: $repairsPerformed."
}

if (-not $NonInteractive) {
    Write-Host "Press any key to continue ..."

    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    catch {
        # Fallback for hosts that do not support RawUI key reads.
        [void](Read-Host -Prompt "Press Enter to continue")
    }
}
