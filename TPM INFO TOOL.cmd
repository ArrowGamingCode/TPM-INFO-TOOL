# Name: TPM INFO TOOL
# Updates: Check https://github.com/ArrowGamingCode/TPM-INFO-TOOL for updates.
# Purpose: An experimental tool that displays technical information to help troubleshoot TPM-related settings for gaming.
# Use official tools and troubleshooting first!
# License: GNU General Public License version 3

<# : chooser
@echo off
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Store the file path in an environment variable for PowerShell to read safely
set "TPM_TEST_FILE=%~1"

cls
echo Please wait while system information is retrieved...
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content '%~f0' -Raw) -join [Environment]::NewLine)"
echo -------------------------------------------------------------------------
pause
exit /b
#>

$MinBiosDate = [datetime]'2025-08-01'
$TestFile = $env:TPM_TEST_FILE
$global:ClipboardBuffer = ""

# =========================================================================
# FUNCTIONS
# =========================================================================

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
            Text   = $text
            Passed = $passed
        }
    } else {
        return [PSCustomObject]@{
            Text   = 'Not Found / Missing'
            Passed = $false
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

function Log-Output ($Text, $Color = "White", $NoNewLine = $false) {
     if ($NoNewLine) {
        Write-Host $Text -ForegroundColor $Color -NoNewline
        $global:ClipboardBuffer += $Text
    } else {
        Write-Host $Text -ForegroundColor $Color
        $global:ClipboardBuffer += "$Text`r`n"
     }
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

    if (!$hasIssues) {
        Log-Output "-> NA" 'Green'
    }
}

function Get-IntelMeVersion {
    try {
        $meDriver = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { $_.DeviceName -like "*Intel*Management Engine*" } | Select-Object -First 1
        if ($meDriver -and $meDriver.DriverVersion) {
            return $meDriver.DriverVersion
        } else {
            return "Not Found"
        }
    } catch {
        return "Error Querying Driver"
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
                # Just pull the issuer string directly without building a validation chain
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

# =========================================================================
# UI RENDERING PIPELINE
# =========================================================================

function Show-UIOutput ($Data) {
    Clear-Host

    Log-Output 'TPM INFO TOOL - 1.0.0'
    Log-Output '--- HARDWARE SPECIFICATIONS ---' 'Cyan'
    Log-Output "OS:           $((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName)"
    Log-Output "CPU:          $($Data.CpuInfo.Name)"
    Log-Output "Motherboard:  $($Data.Mobo)"
    Log-Output "BIOS:          $($Data.BiosInfo.String)"
    Log-Output "Secure Boot:  $($Data.SecureBoot.Text)"
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

    if ($Data.SecureBoot.Passed) { Log-Output 'RESULT: Secure Boot Pass' 'Green' } else { Log-Output 'WARNING: Secure Boot is not enabled' 'Yellow' }

    if ($Data.CsmInfo.Passed) {
        Log-Output "RESULT: BIOS Boot Mode Pass ($($Data.CsmInfo.Text))" 'Green'
    } else {
        Log-Output "CRITICAL: BIOS Boot Mode Fail ($($Data.CsmInfo.Text)). Turn off CSM/Legacy mode!" 'Red'
    }

    if ($Data.BiosInfo.Passed) { Log-Output 'RESULT: BIOS Date Promising' 'Green' } else { Log-Output "WARNING: BIOS could be newer. $($MinBiosDate)" 'Yellow' }

    Log-Output "`n--- XTRAS ---" 'Cyan'
    Log-Output "COD Broker:   $($Data.CodBroker.Text)"
    if ($Data.CodBroker.Passed) { Log-Output 'RESULT: COD Broker Service Pass' 'Green' } else { Log-Output "ERROR: COD.Broker.Service is $($Data.CodBroker.Text)" 'Red' }
    if ($Data.BrokerExe)        { Log-Output 'RESULT: CODBrokerService.exe Binary Exists (Pass)' 'Green' } else { Log-Output 'WARNING: CODBrokerService.exe Binary Missing (Fail)' 'Yellow' }

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

    Log-Output "Windows UEFI CA 2023:      $($Data.MicrosoftCa.Uefi2023Text)"
	Log-Output "Intel ME:     $($Data.IntelMeVersion)"
    Log-Output "RESULT: TPM Endorsement: $($Data.TpmEndorsement.Text)"

    Log-Output "`n--- SECURE BOOT KEYS DETECTED ---" 'Cyan'
    Log-Output "Platform Key (PK):           $($Data.SbKeys.PK)"
    Log-Output "Key Exchange Key (KEK):    $($Data.SbKeys.KEK)"
    Log-Output "Authorized DB Key:         $($Data.SbKeys.DB)"
    Log-Output ""

    # --- CONDITIONAL INPUT: TEST FILE VS CERTREQ ---
    if ($TestFile -and (Test-Path $TestFile)) {
        Log-Output "--- USING TEST FILE INPUT: $TestFile ---" 'Yellow'
        $certRaw = Get-Content $TestFile -Raw
    } else {
        $certRaw = certreq -enrollaik -config '""' 2>&1 | Out-String
    }

    $certOut = $certRaw | Protect-AIKPrivacy
    Write-Host $certOut
    $global:ClipboardBuffer += $certOut

    # --- OVERALL PASS/FAIL BANNER LOGIC ---
	$successPatterns = "Success|Certificate Request Created|Certificate Enrolled|(?=.*New Certificate)(?=.*EnrollStatus\(1\):)"
	$enrollSuccess = $certRaw -match $successPatterns

    $criticalHardwarePass = $Data.TpmInfo.Passed -and $Data.CsmInfo.Passed -and $Data.TpmOwnership.Passed

    Log-Output "`n=========================================================================" 'Cyan'
    if ($enrollSuccess -and $criticalHardwarePass) {
        Log-Output "|                            [ OVERALL: TPM Attestation PASS ]                              |" 'Green'
    } else {
        Log-Output "|                            [ OVERALL: TPM Attestation FAIL ]                          |" 'Red'
        Log-Output "FAILED: TPM Attention is not working on this pc." 'Red'

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
    Log-Output "=========================================================================" 'Cyan'

    # Direct string pipeline allocation straight to windows clipboard
    $global:ClipboardBuffer | Set-Clipboard
    Write-Host "`nAll information has been copied to your clipboard ready to paste into a forum!" -ForegroundColor Cyan
}

# =========================================================================
# MAIN EXECUTION PIPELINE
# =========================================================================

function Invoke-MainExecution {
    $global:platforms = Get-PlatformInstallStatus

    $systemData = [PSCustomObject]@{
        CpuInfo        = Get-CpuCompliance
        RamSlots       = Get-RamDetails
        Mobo           = (Get-CimInstance -ClassName Win32_BaseBoard | ForEach-Object { '{0} {1} (Ver: {2})' -f $_.Manufacturer, $_.Product, $_.Version })
        BiosInfo         = Get-BiosCompliance
        SecureBoot     = Get-SecureBootStatus
        SbKeys         = Get-SecureBootKeysType
        MicrosoftCa    = Get-MicrosoftCaStatus
        CsmInfo        = Get-CsmStatus
        TpmInfo        = Get-TpmStatus
        TpmOwnership    = Get-TpmOwnershipState
        ActivisionKey  = Get-ActivisionKeyStatus
        CodBroker       = Get-CodBrokerStatus
        Randgrid       = Get-randgridRegistryAndDriverInfo
        XboxRandgrid   = Get-XboxRandgridInfo
        BrokerExe      = Test-Path 'C:\ProgramData\Activision\Call of Duty\CODBrokerService.exe'
        BatteryInfo    = Get-BatteryStatus
        PartitionStyle = Get-DiskPartitionStyle
        CoreIsolation  = Get-CoreIsolationHardwareStatus
		IntelMeVersion = Get-IntelMeVersion
		TpmEndorsement = Get-TpmEndorsementCertStatus
    }

    Show-UIOutput -Data $systemData
	return $systemData
}

# Run the pipeline
$Data = Invoke-MainExecution
Show-UserRecommendedSteps -Data $Data