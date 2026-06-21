# Name: TPM INFO TOOL
# Updates: Check https://github.com/ArrowGamingCode/TPM-INFO-TOOL for updates.
# Purpose: An experimental tool that displays technical information to help troubleshoot TPM-related settings for gaming.
# Use official tools and troubleshooting first!
# License: GNU General Public License version 3

<# : chooser
@echo off
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
$global:TotalSteps   = 40

# =========================================================================
# FUNCTIONS
# =========================================================================

function Step-Progress {
    $global:ProgressStep++
    $PercentComplete = [math]::Min(100, [int](($global:ProgressStep / $global:TotalSteps) * 100))
    Write-Progress -Activity "Loading System Diagnostics" -Status "Progress: $PercentComplete%" -PercentComplete $PercentComplete
}

function Get-CpuCompliance {
    $cpu = Get-CimInstance -ClassName Win32_Processor
    $isPassed = if ($cpu.Name -match 'Ryzen \d+ [12]\d{3}') { $false } else { $true }

    return [PSCustomObject]@{
        Name   = $cpu.Name
        Passed = $isPassed
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
    # Grabs only the very first RAM stick object
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
        # Check crypto keys without using error pipelines that break execution blocks
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
        $steamPath = Join-Path $steamReg.InstallPath "steamapps\common\Call of Duty HQ"
        if (-not (Test-Path $steamPath)) {
              $steamPath = Join-Path $steamReg.InstallPath "steamapps\common\Call of Duty"
        }
        if (Test-Path $steamPath) { $steamInstalled = $true }
    }

    if (-not $steamInstalled) {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        foreach ($d in $drives) {
            $testPath = "$($d.DeviceID)\SteamLibrary\steamapps\common\Call of Duty HQ"
            $testPath2 = "$($d.DeviceID)\SteamLibrary\steamapps\common\Call of Duty"
            if (Test-Path $testPath) {
                $steamPath = $testPath
                $steamInstalled = $true
                break
            }
            if (Test-Path $testPath2) {
                $steamPath = $testPath2
                $steamInstalled = $true
                break
            }
        }
    }

    $bnetInstalled = $false
    $bnetPath = ""
    $bnetReg = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Call of Duty" -Name "InstallLocation" -ErrorAction SilentlyContinue
    if ($bnetReg -and (Test-Path $bnetReg.InstallLocation)) {
        $bnetPath = $bnetReg.InstallLocation
        $bnetInstalled = $true
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
                return # Skip to next line
            }
            elseif ($line -eq "Hardware Value:") {
                $currentSection = "Hardware"
                return # Skip to next line
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

            # Stripped the | from the very front and very back
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

function Get-TcgAttestationAudit {
    $rawLogs = tpmtool parsetcglogs -validate
    $fullLogText = $rawLogs -join "`n"

    $check_secureBootState = if ($fullLogText -match 'SecureBoot.*0x1' -or $fullLogText -match '00\s+74\s+00\s+01') { $true } elseif ($fullLogText -match 'SecureBoot.*0x0' -or $fullLogText -match '00\s+74\s+00\s+00') { $false } else { "Unknown" }
    $check_pkKeyPresent    = $fullLogText -match 'P\s*K\s*.*?'
    $check_kekKeyPresent   = $fullLogText -match 'K\s*E\s*K\s*.*?'
    $check_dbKeyPresent    = $fullLogText -match 'd\s*b\s*.*?'
    $check_dbxKeyPresent   = $fullLogText -match 'd\s*b\s*x\s*'
    $check_ebbrProfile     = $fullLogText -match 'Spec ID Event03' -or $fullLogText -match '53\s+70\s+65\s+63\s+20\s+49\s+44'
    $check_kernelDebug     = if ($fullLogText -match 'KernelDebug.*0x1' -or $fullLogText -match 'TestSigning.*0x1') { $false } elseif ($fullLogText -match 'KernelDebug.*0x0' -and $fullLogText -match 'TestSigning.*0x0') { $true } else { "Unknown" }
    $check_bitlockerPolicy = $fullLogText -match 'BitLocker' -or $fullLogText -match 'B\s*i\s*t\s*L\s*o\s*c\s*k\s*e\s*r'
    $check_pcr7Attestation = $fullLogText -match 'PCR7' -or ($check_secureBootState -eq $true -and $check_pkKeyPresent -eq $true)

    $pcrFailures = @()

    return [PSCustomObject]@{
        PcrFailures = $pcrFailures
        SbState     = $check_secureBootState
        PkPresent   = $check_pkKeyPresent
        KekPresent  = $check_kekKeyPresent
        DbPresent   = $check_dbKeyPresent
        DbxPresent  = $check_dbxKeyPresent
        Ebbr        = $check_ebbrProfile
        KernelDebug = $check_kernelDebug
        Bitlocker   = $check_bitlockerPolicy
        Pcr7Ready   = $check_pcr7Attestation
    }
}

# =========================================================================
# PRINT PIPELINE
# =========================================================================

function Show-PlatformStatus {
    if ($global:platforms.SteamFound) {
        Log-Output "RESULT: Steam Call of Duty Found"
    } else {
        Log-Output "RESULT: Steam Call of Duty Not Detected"
    }

    if ($global:platforms.BnetFound) {
        Log-Output "RESULT: Battle.net Call of Duty Found"
    } else {
        Log-Output "RESULT: Battle.net Call of Duty Not Detected"
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

function Show-TcgAttestationAudit ($TcgData) {
    Log-Output "`n--- TCG LOG ATTESTATION AUDIT ---" 'Cyan'

	Show-PCR_Message

	if (Get-TpmIsWBCL -HelpText $env:TpmToolType) {
        return
    }

<#
    if ($TcgData.SbState -eq $true) {
        Log-Output "[PASS] Secure Boot 'Enabled' state (0x01) verified from event log." 'Green'
    } elseif ($TcgData.SbState -eq $false) {
        Log-Output "[WARN] Secure Boot is explicitly 'Disabled' (0x00) in the TCG event log." 'DarkYellow'
    }

    @(@('Platform Key (PK)', $TcgData.PkPresent, 'Motherboard ownership validation block is missing.'),
      @('Key Exchange Key (KEK) Database', $TcgData.KekPresent, 'Intermediate verification key hierarchy is missing.'),
      @('Signature Database (db)', $TcgData.DbPresent, 'Ecosystem certificate array verification missing.'),
      @('Revocation Tree (dbx)', $TcgData.DbxPresent, 'Blacklist component definition missing.')) |
    ForEach-Object {
        if ($_[1] -eq $true) { Log-Output "[PASS] $_[0] : Verified Present" 'Green' }
        else { Log-Output "[WARN] $_[0] : Missing from log architecture" 'DarkYellow';
        Log-Output "       Detail: $_[2]" 'DarkRed' }
    }

    if ($TcgData.Ebbr -eq $true) { Log-Output "[PASS] TCG Specification Profile Alignment : Validated." 'Green' }
    else { Log-Output "[WARN] TCG Specification Profile Alignment : Motherboard formatting defaults out of spec." 'DarkYellow' }

    if ($TcgData.KernelDebug -eq $true) { Log-Output "[PASS] OS Production Baseline Mode : Non-debug production kernel confirmed." 'Green' }
    elseif ($TcgData.KernelDebug -eq $false) { Log-Output "[WARN] OS Production Baseline Mode : Test-signing or Active Kernel Debugging detected!" 'DarkYellow' }

    if ($TcgData.Bitlocker -eq $true) { Log-Output "[PASS] BitLocker Native Storage Policy Handshake : Active pre-boot validation logged." 'Green' }
    if ($TcgData.Pcr7Ready -eq $true) { Log-Output "[PASS] Cloud Device Attestation Readiness : Perfect PCR 7 bound signature design matrix." 'Green' }
    else { Log-Output "[WARN] Cloud Device Attestation Readiness : Incompatible register signature design matrix." 'DarkYellow' }
#>
	Log-Output ""
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
        Log-Output "-> Your current AMD TPM firmware version requires an update. If you have done this, you may need to reset/clear the TPM keys. (press Windows Key + R, type 'tpm.msc', hit Enter, and click 'Clear TPM')" 'Yellow'
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
#(unsure if all system work with this	-and $Data.LocalAttest

    Clear-Host
    Show-Banner -enrollSuccess $enrollSuccess -criticalHardwarePass $criticalHardwarePass -ConsoleOnly

    Log-Output 'TPM INFO TOOL - 1.0.2'
    Log-Output '--- HARDWARE SPECIFICATIONS ---' 'Cyan'
    Log-Output "OS:           $($Data.currentOS)  - (Original Install: $($Data.OriginalOSBuild))"
    Log-Output "CPU:          $($Data.CpuInfo.Name)"
	Log-Output "GPU ver:      Nvidia: $($Data.NvidiaDriver) AMD: $($Data.AmdDriver)"
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
		# 'DarkYellow' acts as the standard console replacement for DarkYellow
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

	Log-Output "Windows Age:  $($Data.DaysSinceInstall) days. Original Install OS: $($Data.OriginalOSBuild)"
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
	Log-Output $data.parsedTpmToolType
	$exclude = 'TPM Present', 'TPM Version', 'TPM Manufacturer ID', 'TPM Manufacturer Full Name', 'TPM Manufacturer Version',
			   'Lockout Counter', 'Max Auth Fail', 'Lockout Interval', 'Lockout Recovery'
    foreach ($prop in $Data.ExtendedTpmProperties.PSObject.Properties) {
        if ($prop.Name -notin $exclude) {
            Log-Output ("{0,-30}: {1}" -f $prop.Name, $prop.Value)
        }
    }
	Log-Output ""

	#Print-PCRTable($data.parsedTpmToolType)
	Show-TcgAttestationAudit -TcgData $Data.TcgAudit

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

    # Direct string pipeline allocation straight to windows clipboard
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
		TcgAudit              = $(Step-Progress; Get-TcgAttestationAudit)
		CurrentOS             = $(Step-Progress; (Get-CimInstance -ClassName Win32_OperatingSystem).Caption)
    }

    Show-UIOutput -Data $systemData
	return $systemData
}

# Run the pipeline
$Data = Invoke-MainExecution
Show-UserRecommendedSteps -Data $Data