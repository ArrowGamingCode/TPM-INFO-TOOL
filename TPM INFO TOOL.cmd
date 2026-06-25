<# : chooser
@echo off

:: # Name: TPM INFO TOOL
:: # Updates: Check https://github.com/ArrowGamingCode/TPM-INFO-TOOL for updates.
:: # Purpose: An experimental tool that displays technical information to help troubleshoot TPM-related settings for gaming.
:: # Use official tools and troubleshooting first!
:: # License: GNU General Public License version 3
set "TPM_TOOL_VERSION=1.0.4"

setlocal enabledelayedexpansion
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

set "TPM_TEST_FILE=%~1"

cls
echo Please wait while system information is retrieved...

set "TpmDeviceData="
set "TpmToolType="
call :CollapseCommandOutput TpmDeviceData "tpmtool getdeviceinformation"
call :CollapseCommandOutput TpmToolType "tpmtool /?"

echo Stage 1 done.

powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content '%~f0' -Raw) -join [Environment]::NewLine)"
echo -------------------------------------------------------------------------
pause
exit /b

:CollapseCommandOutput
set "varName=%~1"
set "command=%~2"
set "%varName%="

for /f "usebackq tokens=* delims=" %%A in (`%command% 2^>nul`) do (
    if "!%varName%!"=="" (
        set "%varName%=%%A"
    ) else (
        for /f "delims=" %%B in ("!varName!") do (
            set "current_val=!%%B!"
            set "%%B=!current_val! | %%A"
        )
    )
)
goto :eof
#>

$MinBiosDate = [datetime]'2025-08-01'
$TestFile = $env:TPM_TEST_FILE
$global:ClipboardBuffer = ""
$global:ProgressStep = 0
$global:TotalSteps   = 48
$ScriptVersion = $env:TPM_TOOL_VERSION

# =========================================================================
# FUNCTIONS
# =========================================================================

function Step-Progress {
    $global:ProgressStep++
    $PercentComplete = [math]::Min(100, [int](($global:ProgressStep / $global:TotalSteps) * 100))
    Write-Progress -Activity "Loading System Diagnostics" -Status "Progress: $PercentComplete%" -PercentComplete $PercentComplete
}

function Get-CpuCompliance {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
        $cpuName = $cpu.Name.Trim() -replace '\s+', ' '
        $isPassed = $true

        if ($cpuName -match 'AMD Ryzen' -and $cpuName -match '\b([12]\d{3})[A-Z]*\b') {
            $isPassed = $false
        }

        return [PSCustomObject]@{
            Name   = $cpu.Name
            Passed = $isPassed
        }
    }
    catch {
        return [PSCustomObject]@{
            Name   = "Unknown"
            Passed = $false
        }
    }
}

function Get-BatteryStatus {
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            $status = ($battery | Select-Object -First 1).Status
            return [PSCustomObject]@{
                Text    = "Detected (Status: $status)"
                Present = $true
            }
        } else {
            return [PSCustomObject]@{
                Text    = "No Battery Detected (Desktop/Fixed PC)"
                Present = $false
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text    = "Unknown / Error checking battery"
            Present = $false
        }
    }
}

function Get-RamDetails {
    $ram = Get-CimInstance -ClassName Win32_PhysicalMemory | Select-Object -First 1

    if ($ram) {
        $type = switch ($ram.SMBIOSMemoryType) {
            20      {'DDR'}
            21      {'DDR2'}
            24      {'DDR3'}
            26      {'DDR4'}
            34      {'DDR5'}
            default {'Unknown'}
        }
        return '{1}' -f $ram.DeviceLocator, $type, $ram.Speed
    }
}

function Get-BiosCompliance {
    $biosObj = Get-CimInstance -ClassName Win32_Bios
    $isPassed = $false
    $dateString = "Unknown"

    if ($biosObj -and $biosObj.ReleaseDate) {
        try {
            $biosDate = [datetime]$biosObj.ReleaseDate
            $dateString = $biosDate.ToString('yyyy-MM-dd')
            if ($biosDate -ge $MinBiosDate) { $isPassed = $true }
        } catch {
            if ([datetime]::TryParse($biosObj.ReleaseDate, [ref]$biosDate)) {
                $dateString = $biosDate.ToString('yyyy-MM-dd')
                if ($biosDate -ge $MinBiosDate) { $isPassed = $true }
            } else {
                 $dateString = "$($biosObj.ReleaseDate) (Unparsed)"
            }
        }
    }

    return [PSCustomObject]@{
        String = '{0} (Released: {1})' -f $biosObj.SMBIOSBIOSVersion, $dateString
        Passed = $isPassed
    }
}

function Get-SecureBootStatus {
    try {
        $sb = Confirm-SecureBootUEFI
        return [PSCustomObject]@{
            Text   = "Enabled ($sb)"
            Passed = $sb
        }
    } catch {
        return [PSCustomObject]@{
            Text   = 'Not Supported or Disabled'
            Passed = $false
        }
    }
}

function Get-SecureBootSetupType {
    try {
        $smVar = Get-SecureBootUEFI -Name SetupMode -ErrorAction Stop
        $byteValue = if ($smVar -and $smVar.PSObject.Properties['Bytes']) { $smVar.Bytes[0] } else { $smVar[0] }

        if ($null -ne $byteValue) {
            if ($byteValue -eq 1) {
                return [PSCustomObject]@{
                    Text   = "Type (Setup Mode)"
                    Passed = $false
                }
            } else {
                return [PSCustomObject]@{
                    Text   = "Type (User Mode)"
                    Passed = $true
                }
            }
        } else {
            return [PSCustomObject]@{
                Text   = "Type (Unknown - No Data)"
                Passed = $false
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text   = "Type (Unreadable - $_)"
            Passed = $false
        }
    }
}

function Get-SecureBootKeysType {
    function Get-SingleKeyType ($KeyName) {
        try {
            $RawKey = Get-SecureBootUEFI -Name $KeyName -ErrorAction Stop
            $TextData = [System.Text.Encoding]::ASCII.GetString($RawKey.Bytes)

            if ($TextData -match "Microsoft") {
                return "Microsoft Certified"
            } elseif ($TextData -match "ASUS" -or $TextData -match "Asustek") {
                return "ASUS Factory"
            } elseif ($TextData -match "Gigabyte") {
                return "Gigabyte Factory"
            } elseif ($TextData -match "MSI" -or $TextData -match "Micro-Star") {
                return "MSI Factory"
            } elseif ($TextData -match "HP " -or $TextData -match "Hewlett-Packard") {
                return "HP Factory"
            } elseif ($TextData -match "Dell") {
                return "Dell Factory"
            } elseif ([string]::IsNullOrEmpty($TextData.Trim())) {
                return "Empty / Not Set"
            } else {
                $CleanedText = $TextData -replace '[^a-zA-Z0-9\s\-\.\,\(\)]', ''
                $IssuerMatch = [regex]::Match($CleanedText, "(CN=|O=|OU=)[A-Za-z0-9\s\.\-]+")
                if ($IssuerMatch.Success) {
                    return "Custom ($($IssuerMatch.Value))"
                }
                return "Custom / User-Generated"
            }
        } catch {
            return "Unreadable (Secure Boot Off or Setup Mode)"
        }
    }

    return [PSCustomObject]@{
        PK  = Get-SingleKeyType 'PK'
        KEK = Get-SingleKeyType 'KEK'
        DB  = Get-SingleKeyType 'db'
    }
}

function Get-MicrosoftCaStatus {
    try {
        $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
        $blob = [System.Text.Encoding]::ASCII.GetString($db.Bytes)
        $has2023Key = $blob -like "*Windows UEFI CA 2023*" -or $blob -like "*Microsoft Corporation UEFI CA 2023*"

        return [PSCustomObject]@{
            Uefi2023Text = if ($has2023Key) { "INSTALLED" } else { "NOT FOUND (Using old 2011 Keys)" }
            Passed       = $has2023Key
        }
    } catch {
        return [PSCustomObject]@{
            Uefi2023Text = "Unreadable / Secure Boot Off"
            Passed       = $false
        }
    }
}

function Get-DoesThirdPartySecurityExist {
    try {
        $avProducts = @(
            Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName "AntivirusProduct" -ErrorAction SilentlyContinue |
                Where-Object { $_.displayName -notmatch 'Defender' }
        )

        $hasThirdParty = $avProducts.Count -gt 0
        $avName = ""

        if ($hasThirdParty) {
            $firstName = $avProducts[0].displayName

            if ($firstName -match 'Norton|McAfee') {
                $avName = $firstName
            }
        }

        return [PSCustomObject]@{
            Passed = $hasThirdParty
            Name   = $avName
        }
    } catch {
        return [PSCustomObject]@{
            Passed = $false
            Name   = "Unknown"
        }
    }
}

function Get-TpmStatus {
     try {
        $tpmObj = Get-CimInstance -Namespace 'Root\Cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm
        if ($tpmObj -and $tpmObj.SpecVersion -like '2.0*') {
            $cpu = Get-CimInstance -ClassName Win32_Processor
            $version = $tpmObj.ManufacturerVersion
            $isAmdBug = ($cpu.Name -match 'AMD') -and ($version -match '^3\.\d+\.0')

            return [PSCustomObject]@{
                Text           = "2.0 - (v$version)"
                Passed         = $true
                AmdFixRequired = $isAmdBug
            }
        } else {
             return [PSCustomObject]@{
                Text           = 'TPM 2.0 Not Supported'
                Passed         = $false
                AmdFixRequired = $false
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text           = 'TPM 2.0 Not Supported / Access Denied'
            Passed         = $false
            AmdFixRequired = $false
        }
    }
}

function Get-LocalAttestationStatus {
    try {
        $features = Get-TpmSupportedFeature -ErrorAction SilentlyContinue
        if ($features -match 'Key Attestation') {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Get-TpmOwnershipState {
    try {
        $tpmCmd = Get-Tpm -ErrorAction SilentlyContinue
        if ($tpmCmd) {
            $isReady = $tpmCmd.TpmReady
            $statusText = "Ready: $isReady, Present: $($tpmCmd.TpmPresent)"
            return [PSCustomObject]@{
                Text   = $statusText
                Passed = $isReady
            }
        } else {
            return [PSCustomObject]@{
                Text   = "Unable to read TPM Ownership properties via Get-Tpm"
                Passed = $false
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text   = "Error executing TPM Ownership query"
            Passed = $false
        }
    }
}

function Get-ActivisionKeyStatus {
    try {
        $keys = certutil -csp "Microsoft Platform Crypto Provider" -key 2>&1 | Out-String
        if ($keys -match "ActivisionAIK") {
            return "Found"
        } else {
            return "Not Found"
        }
    } catch {
        return "Error checking Key CSP Container"
    }
}

function Get-CodBrokerStatus {
    $service = Get-Service -Name 'COD.Broker.Service' -ErrorAction SilentlyContinue
    if ($service) {
        $passed = if ($service.StartType -eq 'Disabled') { $false } else { $true }
        $text   = if (-not $passed) { 'Disabled' } else { $service.Status.ToString() }
        return [PSCustomObject]@{
            Text      = $text
            Passed    = $passed
            StartType = $service.StartType.ToString()
        }
    } else {
        return [PSCustomObject]@{
            Text      = 'Not Found / Missing'
            Passed    = $false
            StartType = 'None'
        }
    }
}

function Get-randgridRegistryAndDriverInfo {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $regKey  = $baseKey.OpenSubKey('SYSTEM\CurrentControlSet\Services\atvi-randgrid_sr')

    $results = [PSCustomObject]@{
        RegKeyExists       = $null -ne $regKey
        FirstChars         = 'N/A'
        RandgridFileExists = $false
    }

    if ($results.RegKeyExists) {
        $imagePath = $regKey.GetValue('ImagePath')
         if ($imagePath) {
            $results.FirstChars = if ($imagePath.Length -ge 5) { $imagePath.Substring(4,2) } else { $imagePath }
            $cleanPath = $imagePath -replace '^\\[\?]{2}\\', '' -replace '^\\\\\\\?\\\\', ''
            if ($cleanPath -notmatch '^[A-Za-z]:') { $cleanPath = Join-Path $env:SystemRoot $cleanPath }
            if (Test-Path $cleanPath) { $results.RandgridFileExists = $true }
         }
        $regKey.Close()
    }
    $baseKey.Close()
    return $results
}

function Get-XboxRandgridInfo {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $regKey  = $baseKey.OpenSubKey('SYSTEM\CurrentControlSet\Services\atvi-randgrid_xbr')

    $results = [PSCustomObject]@{
        RegKeyExists       = $null -ne $regKey
        FirstChars         = 'N/A'
        RandgridFileExists = $false
    }

     if ($results.RegKeyExists) {
        $imagePath = $regKey.GetValue('ImagePath')
        if ($imagePath) {
            $results.FirstChars = if ($imagePath.Length -ge 5) { $imagePath.Substring(4,2) } else { $imagePath }
            $cleanPath = $imagePath -replace '^\\[\?]{2}\\', '' -replace '^\\\\\\\?\\\\', ''
            if ($cleanPath -notmatch '^[A-Za-z]:') { $cleanPath = Join-Path $env:SystemRoot $cleanPath }
             if (Test-Path $cleanPath) { $results.RandgridFileExists = $true }
        }
        $regKey.Close()
    }
    $baseKey.Close()
    return $results
}

function Get-PlatformInstallStatus {
    $steamInstalled = $false
    $steamPath = ""

    $steamReg = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue

    if ($steamReg) {
        $primaryHQ = Join-Path $steamReg.InstallPath "steamapps\common\Call of Duty HQ"
        $primaryLegacy = Join-Path $steamReg.InstallPath "steamapps\common\Call of Duty"

        if (Test-Path (Join-Path $primaryHQ "bootstrapper.exe")) {
            $steamPath = $primaryHQ
            $steamInstalled = $true
        } elseif (Test-Path (Join-Path $primaryLegacy "bootstrapper.exe")) {
            $steamPath = $primaryLegacy
            $steamInstalled = $true
        }
    }

    if (-not $steamInstalled) {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        foreach ($d in $drives) {
            $testPath = Join-Path $d.DeviceID "SteamLibrary\steamapps\common\Call of Duty HQ"
            if (Test-Path (Join-Path $testPath "bootstrapper.exe")) {
                $steamPath = $testPath
                $steamInstalled = $true
                break
            }
        }

        if (-not $steamInstalled) {
            foreach ($d in $drives) {
                $testPath2 = Join-Path $d.DeviceID "SteamLibrary\steamapps\common\Call of Duty"
                if (Test-Path (Join-Path $testPath2 "bootstrapper.exe")) {
                    $steamPath = $testPath2
                    $steamInstalled = $true
                    break
                }
            }
        }
    }

    $bnetInstalled = $false
    $bnetPath = ""

    $bnetRegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Call of Duty",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Call of Duty"
    )

    foreach ($path in $bnetRegPaths) {
        if (Test-Path $path) {
            $bnetReg = Get-ItemProperty -Path $path -Name "InstallLocation" -ErrorAction SilentlyContinue
            if ($bnetReg -and (Test-Path $bnetReg.InstallLocation)) {
                $bnetPath = $bnetReg.InstallLocation
                $bnetInstalled = $true
                break
            }
        }
    }

    if (-not $bnetInstalled) {
        $defaultBnetPaths = @(
            "${env:ProgramFiles}\Call of Duty HQ",
            "${env:ProgramFiles}\Call of Duty",
            "${env:ProgramFiles(x86)}\Call of Duty HQ",
            "${env:ProgramFiles(x86)}\Call of Duty"
        )
        foreach ($path in $defaultBnetPaths) {
            if (Test-Path (Join-Path $path "bootstrapper.exe")) {
                $bnetPath = $path
                $bnetInstalled = $true
                break
            }
        }
    }

    return [PSCustomObject]@{
        SteamFound = $steamInstalled
        SteamPath  = $steamPath
        BnetFound  = $bnetInstalled
        BnetPath   = $bnetPath
    }
}

function Get-DiskPartitionStyle {
    try {
        $osDrive = Get-Disk | Where-Object { $_.IsSystem -eq $true } | Select-Object -First 1
        if (-not $osDrive) {
            $osDrive = Get-Disk | Select-Object -First 1
        }
        return $osDrive.PartitionStyle.ToString()
    } catch {
        return "Unknown / Error"
    }
}

function Format-ClipboardLine ($text) {
    $global:ClipboardBuffer += $text
}

function Get-CsmStatus {
    try {
        $BiosMode = (Get-CimInstance -Namespace "Root\Cimv2" -ClassName Win32_DiskPartition | Where-Object { $_.BootPartition -eq $true }).Type
        if ($BiosMode -match "GPT") {
             return [PSCustomObject]@{ Text = "UEFI"; Passed = $true }
        } else {
            return [PSCustomObject]@{ Text = "Legacy / CSM"; Passed = $false }
        }
    } catch {
        return [PSCustomObject]@{ Text = "Error reading System Info Layer"; Passed = $false }
    }
}

function Get-CoreIsolationHardwareStatus {
    try {
        $sysInfo = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($sysInfo.HypervisorPresent -eq $true) {
            return [PSCustomObject]@{ Passed = $true }
        } else {
            return [PSCustomObject]@{ Passed = $false }
        }
    } catch {
        return [PSCustomObject]@{ Text = "Error reading Virtualization Layer"; Passed = $false }
    }
}

function Protect-AIKPrivacy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$InputString
    )

    process {
        if ([string]::IsNullOrWhiteSpace($InputString)) {
            return $InputString
        }

        $certPattern = "(?s)(?<=-----BEGIN CERTIFICATE-----\r?\n).*?(?=\r?\n-----END CERTIFICATE-----)"
        $thumbprintPattern = "(?<=Thumbprint:\s?.{7}).+"
        $keyIdPattern = "(?<=\b\w+-KeyId-.{7})\w+"
        $requestIdPattern = "(?m)^x-ms-request-id:.*\r?\n?"
        $clientRequestIdPattern = "(?m)^x-ms-client-request-id.*\r?\n?"
        $serialPattern = "(?<=Serial Number:\s?.{7}).+"
        $keyPattern = "(?<=Key\s?=\s?.{15}).+"
        $enrollStepsPattern = "(?s)(?<=EnrollStage = \d+\r?\n).*?(?=Total =)"
        $contentLengthPattern = "(?m)^Content-Length:.*\r?\n?"
        $datePattern = "(?m)^Date:.*\r?\n?"
        $aesPattern = "AES128"
        $shaPattern = "SHA256"
		$versionPattern = "v2\.0"
		$systemUserPattern = "Local System User context"

        $cleanOutput = $InputString `
            -replace $certPattern, "..REMOVED.." `
            -replace $thumbprintPattern, ".." `
            -replace $keyIdPattern, ".." `
            -replace $requestIdPattern, "" `
            -replace $clientRequestIdPattern, "" `
            -replace $serialPattern, ".." `
            -replace $keyPattern, ".." `
            -replace $enrollStepsPattern, "" `
            -replace $contentLengthPattern, "" `
            -replace $datePattern, "" `
            -replace $aesPattern, "[REMOVED]" `
            -replace $shaPattern, "[REMOVED]" `
			-replace $versionPattern, "" `
			-replace $systemUserPattern, ""

        return $cleanOutput
    }
}

function Convert-TpmStringToObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TpmString
    )

    $cleanString = $TpmString.Trim().TrimEnd(';')
    $pairs = $cleanString.Split('|')
    $tpmProperties = [ordered]@{}

    foreach ($pair in $pairs) {
        if ($pair -match '-(?<Key>.*?):\s*(?<Value>.*)') {
            $key = $Matches['Key'].Trim()
            $value = $Matches['Value'].Trim()

            if ($value -eq 'True') { $value = $true }
            elseif ($value -eq 'False') { $value = $false }

            $tpmProperties[$key] = $value
        }
    }
    return [PSCustomObject]$tpmProperties
}

function Get-TpmIsWBCL {
    param (
        [string]$HelpText = ""
    )

    return $HelpText -notmatch "parsetcglogs"
}

function Get-TpmToolTypeMessage {
    param (
        [string]$HelpText = ""
    )

    if (Get-TpmIsWBCL -HelpText $HelpText){
        return "TPM Tool (Modern WBCL logs)"
    }
    else {
        return "TPM Tool (Classic TCG logs)"
    }
}

function Get-PCR {
    if (Get-TpmIsWBCL -HelpText $env:TpmToolType) {
        $tcgLogValues = [ordered]@{}
        $hardwareValues = [ordered]@{}
        $currentSection = $null

        tpmtool printpcr sha256 | ForEach-Object {
            $line = $_.Trim()

            if ($line -eq "TCG Log Value:") {
                $currentSection = "TCG"
                return
            }
            elseif ($line -eq "Hardware Value:") {
                $currentSection = "Hardware"
                return
            }

            if ($line -match 'PCR\[(\d+)\]\s*:\s*([0-9A-Fa-f ]+)') {
                $pcr = "{0:D2}" -f [int]$matches[1]
                $digest = ($matches[2] -replace '\s+', '').ToLower()

                if ($currentSection -eq "TCG") {
                    $tcgLogValues[$pcr] = $digest
                }
                elseif ($currentSection -eq "Hardware") {
                    $hardwareValues[$pcr] = $digest
                }
            }
        }

        foreach ($pcr in $tcgLogValues.Keys) {
            $tcgVal = $tcgLogValues[$pcr]
            $hwVal  = $hardwareValues[$pcr]

            if ($null -eq $hwVal) {
                $status = "MISSING HW"
            }
            elseif ($tcgVal -eq $hwVal) {
                $status = "MATCH!"
            }
            else {
                $status = "MISMATCH!"
            }

            "PCR[$pcr] |  $tcgVal  |  $status"
        }
    }
    else {
       tpmtool parsetcglogs -validate |
         Where-Object { $_ -match '^\|\s*PCR' } |
         ForEach-Object { $_.Trim(" |!`r`n") }
    }
}

function Get-IntelBiosCompliance {
    $cpu = Get-CimInstance -ClassName Win32_Processor
    if ($cpu.Name -notmatch 'Intel') {
        return [PSCustomObject]@{
            IsIntel                 = $false
            RequiresFirmwareUpdate = $false
            Version                 = "N/A"
        }
    }

    $tpmObj = Get-CimInstance -Namespace 'Root\Cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm
    $tpmVersion = if ($tpmObj) { $tpmObj.ManufacturerVersion } else { "Unknown" }

    $requiresUpdate = $tpmVersion -match '^INTC 30[23]\.12\.'

    return [PSCustomObject]@{
        IsIntel                 = $true
        RequiresFirmwareUpdate = $requiresUpdate
        Version                 = $tpmVersion
    }
}

function Get-BitLockerStatus {
    try {
        $blVolume = Get-BitLockerVolume -VolumeType OperatingSystem -ErrorAction Stop
        if ($blVolume -and $blVolume.ProtectionStatus -eq "On") {
            return [PSCustomObject]@{ Text = "Yes"; Passed = $true }
        } else {
            return [PSCustomObject]@{ Text = "No"; Passed = $false }
        }
    } catch {
        return [PSCustomObject]@{ Text = "No / Not Supported"; Passed = $false }
    }
}

function Get-IntelMeVersion {
    try {
        $meDriver = Get-CimInstance -ClassName Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -like "*Intel*Management Engine*" } | Select-Object -First 1

        if ($meDriver -and $meDriver.DriverVersion) {
            if ($meDriver.DriverDate) {
                $rawDate = $meDriver.DriverDate
                $formattedDate = "{0}-{1}-{2}" -f $rawDate.Year, $rawDate.Month.ToString("00"), $rawDate.Day.ToString("00")
                return [PSCustomObject]@{
                    Version = $meDriver.DriverVersion
                    Date    = $formattedDate
                    RawDate = [datetime]$rawDate
                }
            } else {
                return [PSCustomObject]@{
                    Version = $meDriver.DriverVersion
                    Date    = "Unknown"
                    RawDate = $null
                }
            }
        } else {
            return [PSCustomObject]@{
                Version = "Not Found"
                Date    = "N/A"
                RawDate = $null
            }
        }
    } catch {
        return [PSCustomObject]@{
            Version = "Error Querying Driver"
            Date    = "Error"
            RawDate = $null
        }
    }
}

function Get-NvidiaDriverVersion {
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController |
               Where-Object { $_.Name -like "*NVIDIA*" } |
               Select-Object -First 1

        if ($gpu -and $gpu.DriverVersion) {
            $rawVersion = $gpu.DriverVersion -replace '\.', ''
            if ($rawVersion.Length -ge 5) {
                $formattedVersion = ($rawVersion.Substring($rawVersion.Length - 5, 3) + "." + $rawVersion.Substring($rawVersion.Length - 2))
                return $formattedVersion
            }
            return $gpu.DriverVersion
        } else {
            return "Not Detected"
        }
    } catch {
        return "Error Querying"
    }
}

function Get-AmdDriverVersion {
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController |
               Where-Object { $_.Name -like "*AMD*" -or $_.Name -like "*Radeon*" } |
               Select-Object -First 1

        if ($gpu -and $gpu.DriverVersion) {
            return $gpu.DriverVersion
        } else {
            return "Not Detected"
        }
    } catch {
        return "Error Querying"
    }
}

function Get-TpmEndorsementCertStatus {
    try {
        $TpmInfo = Get-TpmEndorsementKeyInfo -HashAlgorithm SHA256 -ErrorAction Stop

        if ($null -eq $TpmInfo.AdditionalCertificates -or $TpmInfo.AdditionalCertificates.Count -eq 0) {
            return [PSCustomObject]@{
                Text   = "No AdditionalCertificates found (Likely older fTPM/PTT setup with no silicon-fused factory certs)"
                Passed = $false
            }
        } else {
            $CertIssuerList = @()
            foreach ($Cert in $TpmInfo.AdditionalCertificates) {
                $CertIssuerList += "$($Cert.Issuer)"
            }

            return [PSCustomObject]@{
                Text   = $CertIssuerList -join " | "
                Passed = $true
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text   = "Error or Access Denied Reading Endorsement Key Info"
            Passed = $false
        }
    }
}

function Show-UpdateMessage {
	Write-Host "`n`n`n`n`n"
    Write-Host "===================================================================================" -ForegroundColor Yellow
    Write-Host " You can check for updates here:  https://github.com/ArrowGamingCode/TPM-INFO-TOOL" -ForegroundColor White
	Write-Host "===================================================================================`n" -ForegroundColor Yellow
}
Show-UpdateMessage

function Get-PowerShellVersion {
    return $PSVersionTable.PSVersion.ToString()
}

function Get-WindowsSubVersion {
    return (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
}

function Get-PcModel {
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($system) {
            $manufacturer = $system.Manufacturer.Trim()
            $model = $system.Model.Trim()

            return "{0} {1}" -f $manufacturer, $model
        } else {
            return "Unknown System"
        }
    } catch {
        return "Error Querying PC Model"
    }
}

# =========================================================================
# PRINT PIPELINE
# =========================================================================

function Show-PlatformStatus {
    if ($global:platforms.SteamFound) {
        Log-Output "RESULT: Steam CoD Found"
    } else {
        Log-Output "RESULT: Steam CoD Not Detected"
    }

    if ($global:platforms.BnetFound) {
        Log-Output "RESULT: Battle.net CoD Found"
    } else {
        Log-Output "RESULT: Battle.net CoD Not Detected"
    }
}

function Print-PCRTable {
    Log-Output "`n--- PCR LOGS ---" 'Cyan'

    Get-PCR | ForEach-Object {
        Log-Output $_
    }
    Log-Output ""
}

function Log-Output ($Text, $Color = "White", $NoNewLine = $false) {
     if ($NoNewLine) {
        Write-Host $Text -ForegroundColor $Color -NoNewline
        $global:ClipboardBuffer += $Text
    } else {
        Write-Host $Text -ForegroundColor $Color
        $global:ClipboardBuffer += "$Text`r`n"
     }
}

function Show-PCR_Message() {
    $HasFailures = $false
    $FailedRegisters = @()

    Get-PCR | ForEach-Object {
        if ($_ -match 'PCR\[(?<num>\d+)\]') {
            $pcrNum = $Matches['num']
            if ($_ -match 'MISMATCH|Failed|Error') {
                $HasFailures = $true
                $FailedRegisters += "PCR[$pcrNum]"
            }
        }

        if ($_ -match 'PCR\[00?\]') {
            $CleanedLine = $_.Trim(" |!`r`n")

            if ($CleanedLine -match 'MISMATCH|Failed|Error') {
                Log-Output $CleanedLine 'Red'
            } else {
                Log-Output $CleanedLine 'White'
            }
        }
    }

    if ($HasFailures -eq $false) {
        Log-Output "[PASS] Hardware log verification matches live PCR registers." 'Green'
    } else {
        Log-Output "[WARN] Cryptographic Mismatch Detected! Physical TPM registers do not match log history." 'DarkYellow'
        Log-Output "       Affected Registers: $($FailedRegisters -join ', ')" 'DarkRed'
    }
}

function Get-Win10SupportStatus {
    $OS = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption

    if ($OS -match "Windows 10") {
        if ($OS -match "LTSC" -or $OS -match "LTSB") {
            return "True"
        }
        return "True (ESU)"
    }
    elseif ($OS -match "Windows 11") {
        return "True"
    }
    else {
        return "False"
    }
}









function Invoke-TpmLogParser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$OutputFolder = "$env:TEMP\TPM_Gathered_Logs"
    )
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder | Out-Null
    }

    & tpmtool.exe gatherlogs $OutputFolder | Out-Null
    $targetLog = Join-Path $OutputFolder "SRTMBoot.dat"

    if (-not (Test-Path $targetLog)) {
        return $null
    }
    $binaryData = [System.IO.File]::ReadAllBytes($targetLog)
    return Decode-TcgBinaryLog -BinaryLog $binaryData
}

function Decode-TcgBinaryLog {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][byte[]]$BinaryLog)

    $offset = 0
    $eventIndex = 0
    $results = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($BinaryLog.Length -lt 32) { return $null }

    $pcrIndex = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
    $eventTypeVal = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
    $eventTypeName = Get-EventTypeName -Id $eventTypeVal
    $digestBytes = Read-Bytes -Offset ([ref]$offset) -Buffer $BinaryLog -Count 20
    $eventSize = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
    $eventDataBytes = Read-Bytes -Offset ([ref]$offset) -Buffer $BinaryLog -Count $eventSize
    $headerText = [System.Text.Encoding]::ASCII.GetString($eventDataBytes) -replace '[^\x20-\x7E]', ''

    $results.Add([PSCustomObject]@{
        Index     = $eventIndex++
        PCRIndex  = $pcrIndex
        EventType = $eventTypeName
        Digests   = "Header Spec Event"
        EventSize = $eventSize
        EventData = $headerText.Trim()
    })

    while ($offset -lt $BinaryLog.Length) {
        if (($BinaryLog.Length - $offset) -lt 12) { break }
        $paddingCheck = $true
        for ($j = 0; $j -lt 12; $j++) {
            if ($BinaryLog[$offset + $j] -ne 0) { $paddingCheck = $false; break }
        }
        if ($paddingCheck) { break }

        $pcrIndex = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
        $eventTypeVal = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
        $digestCount = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
        $eventTypeName = Get-EventTypeName -Id $eventTypeVal
        $digests = @()
        $alignmentFailed = $false

        for ($i = 0; $i -lt $digestCount; $i++) {
            if (($BinaryLog.Length - $offset) -lt 2) { $alignmentFailed = $true; break }
            $algId = Get-UInt16 -Offset ([ref]$offset) -Buffer $BinaryLog
            $algInfo = Get-AlgInfo -Id $algId
            if ($null -ne $algInfo) {
                $hashSize = $algInfo.Size
                $algName  = $algInfo.Name
                if (($BinaryLog.Length - $offset) -lt $hashSize) { $alignmentFailed = $true; break }
                $hashBytes = Read-Bytes -Offset ([ref]$offset) -Buffer $BinaryLog -Count $hashSize
                $hashHex = [BitConverter]::ToString($hashBytes).Replace('-', '')
                $digests += "$algName`:$hashHex"
            } else {
                $alignmentFailed = $true; break
            }
        }

        if ($alignmentFailed -or (($BinaryLog.Length - $offset) -lt 4)) { break }
        $eventSize = Get-UInt32 -Offset ([ref]$offset) -Buffer $BinaryLog
        if (($BinaryLog.Length - $offset) -lt $eventSize) { break }
        $eventDataBytes = Read-Bytes -Offset ([ref]$offset) -Buffer $BinaryLog -Count $eventSize

        $printableText = [System.Text.Encoding]::UTF8.GetString($eventDataBytes) -replace '[^\x20-\x7E\s]', ''
        if ($printableText.Trim().Length -lt 2 -and $eventSize -gt 0) {
            $printableText = "Hex: " + [BitConverter]::ToString($eventDataBytes).Replace('-', '')
        }

        $results.Add([PSCustomObject]@{
            Index     = $eventIndex++
            PCRIndex  = $pcrIndex
            EventType = $eventTypeName
            Digests   = ($digests -join " | ")
            EventSize = $eventSize
            EventData = $printableText.Trim()
        })
    }
    return $results
}

function Read-Bytes {
    param ([ref]$Offset, [byte[]]$Buffer, [int]$Count)
    $result = New-Object byte[] $Count
    [Buffer]::BlockCopy($Buffer, $Offset.Value, $result, 0, $Count)
    $Offset.Value += $Count
    return $result
}

function Get-UInt32 {
    param ([ref]$Offset, [byte[]]$Buffer)
    return [BitConverter]::ToUInt32((Read-Bytes -Offset $Offset -Buffer $Buffer -Count 4), 0)
}

function Get-UInt16 {
    param ([ref]$Offset, [byte[]]$Buffer)
    return [BitConverter]::ToUInt16((Read-Bytes -Offset $Offset -Buffer $Buffer -Count 2), 0)
}

function Get-AlgInfo {
    param ([uint16]$Id)
    switch ($Id) {
        0x0004 { return @{ Name = "SHA1"; Size = 20 } }
        0x000B { return @{ Name = "SHA256"; Size = 32 } }
        0x000C { return @{ Name = "SHA384"; Size = 48 } }
        0x000D { return @{ Name = "SHA512"; Size = 64 } }
        0x0012 { return @{ Name = "SM3_256"; Size = 32 } }
        default { return $null }
    }
}

function Get-EventTypeName {
    param ([uint32]$Id)
    switch ($Id) {
        0x00000000 { return "EV_PREBOOT_CERT" }
        0x00000001 { return "EV_POST_CODE" }
        0x00000002 { return "EV_UNUSED" }
        0x00000003 { return "EV_NO_ACTION" }
        0x00000004 { return "EV_SEPARATOR" }
        0x00000005 { return "EV_ACTION" }
        0x00000006 { return "EV_EVENT_TAG" }
        0x00000007 { return "EV_S_CRTM_CONTENTS" }
        0x00000008 { return "EV_S_CRTM_VERSION" }
        0x00000009 { return "EV_CPU_MICROCODE" }
        0x0000000A { return "EV_PLATFORM_CONFIG_FLAGS" }
        0x0000000B { return "EV_TABLE_OF_DEVICES" }
        0x0000000C { return "EV_COMPACT_HASH" }
        0x0000000D { return "EV_IPL" }
        0x0000000E { return "EV_IPL_PARTITION_DATA" }
        0x0000000F { return "EV_NONHOST_CODE" }
        0x00000010 { return "EV_NONHOST_CONFIG" }
        0x00000011 { return "EV_NONHOST_INFO" }
        0x80000001 { return "EV_EFI_VARIABLE_DRIVER_CONFIG" }
        0x80000002 { return "EV_EFI_VARIABLE_BOOT" }
        0x80000003 { return "EV_EFI_BOOT_SERVICES_APPLICATION" }
        0x80000004 { return "EV_EFI_BOOT_SERVICES_DRIVER" }
        0x80000005 { return "EV_EFI_RUNTIME_SERVICES_DRIVER" }
        0x80000006 { return "EV_EFI_GPT_DATA" }
        0x80000007 { return "EV_EFI_ACTION" }
        0x80000008 { return "EV_EFI_PLATFORM_FIRMWARE_BLOB" }
        0x80000009 { return "EV_EFI_HANDOFF_TABLES" }
        0x8000000A { return "EV_EFI_VARIABLE_AUTHORITY" }
        default    { return "Unknown (0x" + $Id.ToString("X8") + ")" }
    }
}

function Test-SecurityCompliance {
    param ($DecodedLog)
    if (-not $DecodedLog) { return $null }

    $check_secureBootState  = "Unknown"
    $check_pkKeyPresent     = $false
    $check_kekKeyPresent    = $false
    $check_dbKeyPresent     = $false
    $check_dbxKeyPresent    = $false
    $check_kernelDebug      = "Unknown"
    $check_bitlockerPolicy  = $false
    $check_pcr7Attestation  = $false
    $hasPcr7Variables       = $false
    $hasPcr7Authority       = $false

    foreach ($event in $DecodedLog) {
        $data = $event.EventData
        $type = $event.EventType

        if ($event.PCRIndex -eq 7) {
            if ($type -match "EV_EFI_VARIABLE_DRIVER_CONFIG" -or $type -match "80000001") {
                $hasPcr7Variables = $true
                if ($data -match "SecureBoot") {
					if ($data -match "Hex:\s*00") {
						$check_secureBootState = "?"
					} else {
						$check_secureBootState = "Pass"
					}
                }
                if ($data -match "PK")  { $check_pkKeyPresent  = $true }
                if ($data -match "KEK") { $check_kekKeyPresent = $true }
                if ($data -match "db")  { $check_dbKeyPresent  = $true }
                if ($data -match "dbx") { $check_dbxKeyPresent = $true }
            }
            if ($type -match "EV_EFI_VARIABLE_AUTHORITY" -or $type -match "8000000A") {
                $hasPcr7Authority = $true
            }
        }
        if ($event.PCRIndex -eq 13 -and $data -match "bootmgfw.efi") {
            if ($data -match "debug=true" -or $data -match "bootdebug=true") { $check_kernelDebug = "Enabled (Insecure)" }
            else { $check_kernelDebug = "Pass" }
        }
        if ($event.PCRIndex -eq 13 -and ($data -match "VbsSiPolicy.p7b" -or $data -match "siPolicy")) {
            $check_bitlockerPolicy = $true
        }
    }

    if ($hasPcr7Variables -and $check_pkKeyPresent -and $check_dbKeyPresent) {
        $check_pcr7Attestation = $true
    }

    return [PSCustomObject]@{
        SecureBootState = $check_secureBootState
        PkKeyPresent    = if ($check_pkKeyPresent) { "Pass" } else { "?" }
        KekKeyPresent   = if ($check_kekKeyPresent) { "Pass" } else { "?" }
        DbKeyPresent    = if ($check_dbKeyPresent) { "Pass" } else { "?" }
        DbxKeyPresent   = if ($check_dbxKeyPresent) { "Pass" } else { "?" }
        KernelDebug     = $check_kernelDebug
        Pcr7Attestation = if ($check_pcr7Attestation) { "Pass" } else { "?" }
    }
}


function Show-TcgAttestationAudit ($TcgData) {
    Log-Output "--- MEASURED BOOT BINARY AUDIT (EXPERIMENTAL) ---" 'Cyan'
	Show-PCR_Message

	if ($TcgData) {
		Log-Output "SecureBoot State: $($TcgData.SecureBootState)"
		Log-Output "Platform Key:       $($TcgData.PkKeyPresent)"
		Log-Output "Key Exchange Keys: $($TcgData.KekKeyPresent)"
		Log-Output "DB Signature database:   $($TcgData.DbKeyPresent)"
		Log-Output "DBX Revocation list:    $($TcgData.DbxKeyPresent)"
		Log-Output "No Kernel Debugging:        $($TcgData.KernelDebug)"
		Log-Output "PCR7 Log Binding Valid:  $($TcgData.Pcr7Attestation)"
	}
	write-host ""
}

function Test-CompatibilityFlag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$ExeNames = @("steam.exe", "Battle.net.exe", "cod.exe", "bootstrapper.exe", "CODBrokerInstaller.exe", "CODBrokerService.exe")
    )

    $regPaths = @(
        "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers",
        "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    )

    $issuesFound = 0
    $foundEntries = @()

    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            $properties = Get-ItemProperty -Path $path
            foreach ($prop in $properties.PSObject.Properties) {
                if ($prop.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                    foreach ($exe in $ExeNames) {
                        if ($prop.Name -like "*$exe") {
                            $foundEntries += [PSCustomObject]@{
                                Path  = $prop.Name
                                Flags = $prop.Value
                            }
                            $issuesFound++
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Passed       = ($issuesFound -eq 0)
        IssuesFound  = $issuesFound
        FoundEntries = $foundEntries
    }
}

function Get-CallOfDutyLogStatus {
    $LogPath = "C:\ProgramData\Activision\Call of Duty\broker_service.log"

    if (Test-Path $LogPath) {
        $LogFile = Get-Item $LogPath
        $SizeInBytes = $LogFile.Length

        $Lines = Get-Content $LogPath -TotalCount 3 -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            Exists      = $true
            Size        = $SizeInBytes
            Passed      = ($SizeInBytes -eq 0)
            Content     = $Lines
        }
    } else {
        return [PSCustomObject]@{
            Exists      = $false
            Size        = 0
            Passed      = $false
            Content     = @()
        }
    }
}

function Get-CallOfDutyBootstrapperStatus {
    $GamePaths = @()

    if ($global:platforms.BnetFound -and $global:platforms.BnetPath) {
        $GamePaths += [PSCustomObject]@{ Platform = "Battle.net"; Path = $global:platforms.BnetPath }
    }

    if ($global:platforms.SteamFound -and $global:platforms.SteamPath) {
        $GamePaths += [PSCustomObject]@{ Platform = "Steam"; Path = $global:platforms.SteamPath }
    }

    if ($GamePaths.Count -eq 0) {
        return [PSCustomObject]@{
            Platform    = "None"
            Found       = $false
            Passed      = $false
            BottomLines = @("Game directory not detected or missing for any platform")
        }
    }

    $Results = foreach ($Target in $GamePaths) {
        $Path = $Target.Path
        $Platform = $Target.Platform

        if (-not (Test-Path $Path)) {
            [PSCustomObject]@{
                Platform    = $Platform
                Found       = $false
                Passed      = $false
                BottomLines = @("Game directory path configured but does not exist on disk")
            }
            continue
        }

        $LogPath = Join-Path $Path "bootstrapper.log"

        if (Test-Path $LogPath) {
            $LastLine = Get-Content $LogPath -Tail 1 -ErrorAction SilentlyContinue

            $Passed = $false
            if ($LastLine -and $LastLine -match "Success") {
                $Passed = $true
            }

            [PSCustomObject]@{
                Platform    = $Platform
                Found       = $true
                Passed      = $Passed
                BottomLines = if ($LastLine) { @($LastLine) } else { @("Log file is empty") }
            }
        } else {
            [PSCustomObject]@{
                Platform    = $Platform
                Found       = $false
                Passed      = $false
                BottomLines = @("bootstrapper.log not found")
            }
        }
    }

    return $Results
}

# =========================================================================
# USER RECOMMENDATION PIPELINE
# =========================================================================

function Show-UserRecommendedSteps ($Data) {
    Log-Output "`n--- USER RECOMMENDED STEPS ---" 'Cyan'
    $hasIssues = $false

    if (!$Data.CpuInfo.Passed) {
        Log-Output "-> Check your CPU is not a 1st or 2nd gen Ryzen as TPM Attestation is not supported." 'Yellow'
        $hasIssues = $true
    }

	if ($Data.TpmInfo.AmdFixRequired) {
        if ($Data.BitLocker -and $Data.BitLocker.Passed -eq $false) {
            Log-Output "-> Your current AMD TPM firmware version requires an update. If you have done this, you may need to reset/clear the TPM keys. (press Windows Key + R, type 'tpm.msc', hit Enter, and click 'Clear TPM')" 'Yellow'
        } else {
            Log-Output "-> Your current AMD TPM firmware version requires an update, but you have bitlocker." 'Yellow'
        }
        $hasIssues = $true
    }

    if (!$Data.SecureBoot.Passed) {
        Log-Output "-> SECURE BOOT is showing OFF: Check its on." 'Yellow'
        $hasIssues = $true
    }

    if (!$Data.CsmInfo.Passed) {
        Log-Output "-> Your system is running in Legacy/CSM mode instead of modern UEFI mode." 'Yellow'
        $hasIssues = $true
    }

    if (!$Data.BiosInfo.Passed) {
        Log-Output "-> Check if there is a newer BIOS" 'Yellow'
        $hasIssues = $true
    }

	if ($Data.IntelBiosInfo.IsIntel -and $Data.IntelBiosInfo.RequiresFirmwareUpdate) {
        Log-Output "-> Your Intel PTT Firmware version ($($Data.IntelBiosInfo.Version)) appears to be outdated. Update BIOS/Firmware" 'Yellow'
        $hasIssues = $true
    }

    if (!$hasIssues) {
        Log-Output "-> NA" 'Green'
    }
}

# =========================================================================
# UI RENDERING PIPELINE
# =========================================================================

function Show-Banner ($enrollSuccess, $criticalHardwarePass, [switch]$ConsoleOnly) {
    $LogCmd = if ($ConsoleOnly) { { param($msg, $color) Write-Host $msg -ForegroundColor $color } }
              else { { param($msg, $color) Log-Output $msg $color } }

    if ($enrollSuccess -and $criticalHardwarePass) {
        $statusText = "PASS"
        $color      = "Green"
        $padding    = " " * 17
    } else {
        $statusText = "FAIL"
        $color      = "Red"
        $padding    = " " * 17
    }

    &$LogCmd "=========================================================================" 'Cyan'
    &$LogCmd "| $padding [ OVERALL: TPM Attestation $statusText ] $padding |" $color
    PrintLargeOverallResult $statusText
    &$LogCmd "=========================================================================" 'Cyan'
}

function PrintLargeOverallResult ($result) {
	Write-Host "=========================================================================" -ForegroundColor Blue
    if ($result -eq 'PASS') {
        $ascii = @'
  ____    _    ____ ____  
 |  _ \  / \  / ___/ ___| 
 | |_) |/ _ \ \___ \___ \ 
 |  __/ ___ \ ___) |___) |
 |_| /_/   \_\____/|____/ 
'@
        Write-Host $ascii -ForegroundColor Green
    } else {
        $ascii = @'
  _____ _   ___ _     
 |  ___/ \ |_ _| |    
 | |_ / _ \ | || |    
 |  _/ ___ \| || |___ 
 |_|/_/   \_\___|_____|
'@
        Write-Host $ascii -ForegroundColor Red
    }
}

function Show-UIOutput ($Data) {
	Step-Progress
	Write-Host "Testing Certreq.." -ForegroundColor White
    if ($TestFile -and (Test-Path $TestFile)) {
        $certRaw = Get-Content $TestFile -Raw
    } else {
        $certRaw = certreq -enrollaik -config '""' 2>&1 | Out-String
    }
	Write-Progress -Activity "Loading System Diagnostics" -Completed

    $successPatterns = "(?s)(?=.*SCEPDispositionSuccess)(?=.*EnrollStatus\(1\):\s*Enrolled)(?=.*New Certificate:)"
	$enrollSuccess = $certRaw -match $successPatterns
	if ($certRaw -match "Bad Request" -or $certRaw -match "No valid TPM EK") {
        $enrollSuccess = $false
    }

	$criticalHardwarePass = $Data.TpmInfo.Passed -and $Data.CsmInfo.Passed -and $Data.TpmOwnership.Passed
							#(unsure if all system work with this -and $Data.LocalAttest

    Clear-Host
    Show-Banner -enrollSuccess $enrollSuccess -criticalHardwarePass $criticalHardwarePass -ConsoleOnly

    Log-Output "TPM INFO TOOL - $ScriptVersion - PowerShell: $($Data.PowerShellVer)"
    Log-Output '--- HARDWARE SPECIFICATIONS ---' 'Cyan'
    Log-Output "OS:           $($Data.currentOS) ($($Data.OSSubVersion)) - (Original Install: $($Data.OriginalOSBuild)) - Supported: $($Data.OSSupported)"
    Log-Output "CPU:          $($Data.CpuInfo.Name)"
	Log-Output "GPU ver:      Nvidia: $($Data.NvidiaDriver) AMD: $($Data.AmdDriver)"
	Log-Output "PC Model:     $($Data.PcModel)"
    Log-Output "Motherboard:  $($Data.Mobo)"
    Log-Output "BIOS:          $($Data.BiosInfo.String)"
	Log-Output "RAM Type:     $($Data.RamSlots)"
    Log-Output "TPM Version:  $($Data.TpmInfo.Text)"
    Log-Output "TPM Status:   $($Data.TpmOwnership.Text)"

    Log-Output "`n--- COMPLIANCE REPORT ---" 'Cyan'
    if (!$Data.CpuInfo.Passed) { Log-Output 'CRITICAL: Old CPUs may not be supported' 'Red' }
    if ($Data.TpmInfo.Passed)  { Log-Output 'RESULT: TPM 2.0 Version Pass' 'Green' } else { Log-Output "CRITICAL: $($Data.TpmInfo.Text)" 'Red' }

    if ($Data.TpmOwnership.Passed) {
        Log-Output 'RESULT: TPM Ownership/Ready State Pass' 'Green'
    } else {
        Log-Output "CRITICAL: TPM is not fully Ready/Owned by Windows. (Run tpm.msc to fix)" 'Red'
    }

    if ($Data.TpmInfo.AmdFixRequired) {
        Log-Output 'CRITICAL: Bad TPM version. Bios update or key reset required' 'Red'
    }

	if ($Data.SecureBoot.Passed -and $Data.SecureBootType.Passed) {
		Log-Output "RESULT: Secure Boot: $($Data.SecureBoot.Text) - $($Data.SecureBootType.Text)" 'Green'
	} else {
		Log-Output "WARNING: Secure Boot is not enabled. $($Data.SecureBoot.Text) - $($Data.SecureBootType.Text)" 'Red'
	}

    if ($Data.CsmInfo.Passed) {
        Log-Output "RESULT: BIOS Boot Mode Pass ($($Data.CsmInfo.Text))" 'Green'
    } else {
        Log-Output "CRITICAL: BIOS Boot Mode Fail ($($Data.CsmInfo.Text)). Turn off CSM/Legacy mode!" 'Red'
    }

    if ($Data.BiosInfo.Passed) { Log-Output 'RESULT: BIOS Date Promising' 'Green' } else { Log-Output "WARNING: BIOS could be newer. $($MinBiosDate)" 'Yellow' }

    Log-Output "`n--- XTRAS ---" 'Cyan'

    if ($Data.localAttest) {
        Log-Output "Local Attestation: SUPPORTED" 'Green'
    } else {
        Log-Output "Local Attestation: FAILED / NOT SUPPORTED" 'Red'
    }

	Log-Output "COD Broker:   $($Data.CodBroker.Text) (StartType: $($Data.CodBroker.StartType))"
	if ($Data.CodBroker.StartType -eq 'Automatic') {
		Log-Output 'WARNING: COD.Broker.Service is set to Automatic' 'DarkYellow'
	} elseif ($Data.CodBroker.Passed) {
		Log-Output 'RESULT: COD Broker Service Pass' 'Green'
	} else {
		Log-Output "ERROR: COD.Broker.Service is $($Data.CodBroker.Text)" 'Red'
	}

    if ($Data.BrokerExe) {
        try {
            $brokerVersion = (Get-ItemProperty -Path 'C:\ProgramData\Activision\Call of Duty\CODBrokerService.exe').VersionInfo.FileVersion
            Log-Output "RESULT: CODBrokerService.exe Binary Exists (v$brokerVersion) (Pass)" 'Green'
        } catch {
            Log-Output 'RESULT: CODBrokerService.exe Binary Exists (Version Unreadable) (Pass)' 'Green'
        }
    } else {
        Log-Output 'WARNING: CODBrokerService.exe Binary Missing (Fail)' 'Yellow' 
    }

    if ($Data.Randgrid.RegKeyExists) {
        Log-Output 'RESULT: randgrid Registry Key Exists (Pass)' 'Green'
    } else {
        Log-Output 'CRITICAL: randgrid Registry Key Missing (Fail)' 'Red'
    }
    if ($Data.Randgrid.RandgridFileExists) {
		Log-Output 'RESULT: randgrid.sys Driver Found (Pass)' 'Green'
	} else {
		Log-Output 'CRITICAL: randgrid.sys Driver File Missing from Path (Fail)' 'Red'
	}

    if ($Data.XboxRandgrid.RegKeyExists) {
        Log-Output 'RESULT: Xbox randgrid' 'Green'
    }
	
    if ($Data.CompatibilityFlags.Passed) {
        Log-Output "[PASS] Compatibility flags are clear." 'Green'
    } else {
        Log-Output "[FAIL] Compatibility flags found on target gaming executables!" 'Red'
        foreach ($entry in $Data.CompatibilityFlags.FoundEntries) {
            Log-Output "          Found Path: $($entry.Path)" 'DarkYellow'
            Log-Output "          Applied Flags: $($entry.Flags)" 'DarkRed'
        }
    }

	Log-Output "Third-Party AV: $($Data.doesThirdPartySecurityExist.Passed) - $($Data.doesThirdPartySecurityExist.Name)"
    Log-Output "Battery:      $($Data.BatteryInfo.Text)"
    Log-Output "Partition:    $($Data.PartitionStyle)"
	Log-Output "Activision Key: $($Data.ActivisionKey)"

    Show-PlatformStatus

     if ($Data.CoreIsolation.Passed) { Log-Output "RESULT: Core Isolation Pass" 'Green'
	} else {
		Log-Output "RESULT: Core Isolation Off"
	}

	Log-Output "IME Version: $($Data.IntelMeVersion.Version) - IME Date: $($Data.IntelMeVersion.Date)"

    $biosObj = Get-CimInstance -ClassName Win32_Bios
    if ($biosObj -and $biosObj.ReleaseDate -and $Data.IntelMeVersion.RawDate) {
        try {
            $biosDate = [datetime]$biosObj.ReleaseDate
            $meDate = $Data.IntelMeVersion.RawDate
            $dateDiff = [Math]::Abs(($biosDate - $meDate).TotalDays)

            if ($dateDiff -gt 180) {
                Log-Output "WARNING: BIOS & IME dates are over 6 months apart! ($([Math]::Round($dateDiff)) days difference)" 'Yellow'
            } else {
                Log-Output "IME Sync: Passed (Dates are within 6 months)" 'Green'
            }
        }catch { }
    }

	Log-Output "Windows Age:  $($Data.DaysSinceInstall) days"
	if ($Data.BitLocker.Passed) {
        Log-Output "BitLocker Enabled: Yes" 'Red'
    } else {
        Log-Output "BitLocker Enabled: No"
    }

    Log-Output "RESULT: TPM Endorsement: $($Data.TpmEndorsement.Text)"

    Log-Output "`n--- SECURE BOOT KEYS DETECTED ---" 'Cyan'
    Log-Output "Platform Key (PK):           $($Data.SbKeys.PK)"
    Log-Output "Key Exchange Key (KEK):    $($Data.SbKeys.KEK)"
    Log-Output "Authorized DB Key:         $($Data.SbKeys.DB)"
    Log-Output ""

    $certOut = $certRaw | Protect-AIKPrivacy
    Write-Host $certOut
    $global:ClipboardBuffer += $certOut

    Log-Output "`n--- ADVANCED TPM PROPERTIES ---" 'Cyan'
	Log-Output $Data.parsedTpmToolType
	$exclude = 'TPM Present', 'TPM Version', 'TPM Manufacturer ID', 'TPM Manufacturer Full Name', 'TPM Manufacturer Version',
			   'Lockout Counter', 'Max Auth Fail', 'Lockout Interval', 'Lockout Recovery'
    foreach ($prop in $Data.ExtendedTpmProperties.PSObject.Properties) {
        if ($prop.Name -notin $exclude) {
            Log-Output ("{0,-30}: {1}" -f $prop.Name, $prop.Value)
        }
    }

	Log-Output "`n--- LOGS ---" 'Cyan'
    if ($Data.CodBrokerLog.Exists) {
        if ($Data.CodBrokerLog.Passed) {
            Log-Output "PASS: broker_service.log" 'Green'
        } else {
            Log-Output "RESULT: broker_service.log" 'White'
            if ($Data.CodBrokerLog.Content.Count -gt 0) {
                foreach ($Line in $Data.CodBrokerLog.Content) {
                    Log-Output "  $Line" 'White'
                }
            }
        }
    } else {
        Log-Output "RESULT: broker_service.log not found" 'White'
    }

	if ($Data.CodBootstrapperStatus.Found) {
        if ($Data.CodBootstrapperStatus.Passed) {
            Log-Output "PASS: bootstrapper.log" 'Green'
        } else {
            Log-Output "INFO: bootstrapper.log"
            foreach ($Line in $Data.CodBootstrapperStatus.BottomLines) {
                Log-Output "  $Line" 'White'
            }
        }
    } else {
        Log-Output "RESULT: bootstrapper.log tracking skipped ($($Data.CodBootstrapperStatus.BottomLines[0]))" 'White'
    }
	Log-Output ""

	#Print-PCRTable
	Show-TcgAttestationAudit -TcgData $Data.MeasuredBootCompliance

    Show-Banner -enrollSuccess $enrollSuccess -criticalHardwarePass $criticalHardwarePass

	if (-not ($enrollSuccess)) {
		Log-Output "EnrollSuccess Fail." 'Red'
	}

    if (-not ($enrollSuccess -and $criticalHardwarePass)) {
        Log-Output "FAILED: TPM Attestation is not working on this pc.`n" 'Red'
		Write-Host "Reminder - Ensure you are on the latest BIOS and have reset/cleared the TPM. Start Menu->type tpm.msc and Clear TPM." -ForegroundColor Yellow

        if ($certRaw) {
            $certRaw -split "`r?`n" | ForEach-Object {
                if ($_ -match '^\s*\{\s*"Message"\s*:') {
                    try {
                        $jsonObject = $_ | ConvertFrom-Json
                        Log-Output $jsonObject.Message 'Red'
                    } catch {
                        Log-Output $_ 'Red'
                    }
                  }
            }
        }
    }

    $global:ClipboardBuffer | Set-Clipboard
    Write-Host "`nAll information has been copied to your clipboard ready to paste into a forum!" -ForegroundColor Cyan
}

# =========================================================================
# MAIN EXECUTION PIPELINE
# =========================================================================

function Invoke-MainExecution {
    $global:platforms = Get-PlatformInstallStatus

	$originalOS = "Unknown"
    $subVersion = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "SubVersion" -ErrorAction SilentlyContinue
    $buildLab   = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "BuildLabEx" -ErrorAction SilentlyContinue

    if ($subVersion -and $subVersion.SubVersion -match "Original Install: Windows 10") {
        $originalOS = "Windows 10"
    } elseif ($subVersion -and $subVersion.SubVersion -match "Original Install: Windows 11") {
        $originalOS = "Windows 11"
    } elseif ($buildLab) {
        $buildNumber = ($buildLab.BuildLabEx -split "\.")[0]
		$parsedBuild = 0
        if ([int]::TryParse($buildNumber, [ref]$parsedBuild)) {
            if ($parsedBuild -ge 22000) { $originalOS = "Windows 11" } else { $originalOS = "Windows 10" }
        }
    }

	$parsedTpmObject = Convert-TpmStringToObject -TpmString $env:TpmDeviceData
	$parsedTpmToolTypeObject = Get-TpmToolTypeMessage -HelpText $env:TpmToolType

    $systemData = [PSCustomObject]@{
		CpuInfo               = $(Step-Progress; Get-CpuCompliance)
		NvidiaDriver          = $(Step-Progress; Get-NvidiaDriverVersion)
		AmdDriver             = $(Step-Progress; Get-AmdDriverVersion)
		RamSlots              = $(Step-Progress; Get-RamDetails)
		Mobo                  = $(Step-Progress; Get-CimInstance -ClassName Win32_BaseBoard | ForEach-Object { '{0} {1} (Ver: {2})' -f $_.Manufacturer, $_.Product, $_.Version })
		BiosInfo              = $(Step-Progress; Get-BiosCompliance)
		SecureBoot            = $(Step-Progress; Get-SecureBootStatus)
		SecureBootType        = $(Step-Progress; Get-SecureBootSetupType)
		SbKeys                = $(Step-Progress; Get-SecureBootKeysType)
		MicrosoftCa           = $(Step-Progress; Get-MicrosoftCaStatus)
		CsmInfo               = $(Step-Progress; Get-CsmStatus)
		TpmInfo               = $(Step-Progress; Get-TpmStatus)
		TpmOwnership          = $(Step-Progress; Get-TpmOwnershipState)
		ActivisionKey         = $(Step-Progress; Get-ActivisionKeyStatus)
		CodBroker             = $(Step-Progress; Get-CodBrokerStatus)
		Randgrid              = $(Step-Progress; Get-randgridRegistryAndDriverInfo)
		XboxRandgrid          = $(Step-Progress; Get-XboxRandgridInfo)
		BrokerExe             = $(Step-Progress; Test-Path 'C:\ProgramData\Activision\Call of Duty\CODBrokerService.exe')
		BatteryInfo           = $(Step-Progress; Get-BatteryStatus)
		PartitionStyle        = $(Step-Progress; Get-DiskPartitionStyle)
		CoreIsolation         = $(Step-Progress; Get-CoreIsolationHardwareStatus)
		IntelMeVersion        = $(Step-Progress; Get-IntelMeVersion)
		TpmEndorsement        = $(Step-Progress; Get-TpmEndorsementCertStatus)
		OriginalOSBuild       = $(Step-Progress; $originalOS)
		DaysSinceInstall      = $(Step-Progress; [Math]::Round(((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).InstallDate).TotalDays))
		BitLocker             = $(Step-Progress; Get-BitLockerStatus)
		ExtendedTpmProperties = $(Step-Progress; $parsedTpmObject)
		LocalAttest           = $(Step-Progress; Get-LocalAttestationStatus)
		parsedTpmToolType     = $(Step-Progress; $parsedTpmToolTypeObject)
		IntelBiosInfo         = $(Step-Progress; Get-IntelBiosCompliance)
		MeasuredBootCompliance = $(Step-Progress; Test-SecurityCompliance -DecodedLog (Invoke-TpmLogParser))
		CurrentOS             = $(Step-Progress; (Get-CimInstance -ClassName Win32_OperatingSystem).Caption)
		PowerShellVer		  = $(Step-Progress; Get-PowerShellVersion)
		OSSubVersion          = $(Step-Progress; Get-WindowsSubVersion)
		OSSupported           = $(Step-Progress; Get-Win10SupportStatus)
		PcModel               = $(Step-Progress; Get-PcModel)
		doesThirdPartySecurityExist = $(Step-Progress; Get-DoesThirdPartySecurityExist)
		CompatibilityFlags    = $(Step-Progress; Test-CompatibilityFlag)
		CodBrokerLog          = $(Step-Progress; Get-CallOfDutyLogStatus)
		CodBootstrapperStatus = $(Step-Progress; Get-CallOfDutyBootstrapperStatus)
    }

    Show-UIOutput -Data $systemData
	return $systemData
}

$Data = Invoke-MainExecution
Show-UserRecommendedSteps -Data $Data