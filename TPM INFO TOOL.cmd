<# : chooser
@echo off

:: # Name: TPM INFO TOOL
:: # Updates: Check https://github.com/ArrowGamingCode/TPM-INFO-TOOL for updates.
:: # Purpose: An experimental tool that displays technical information to help troubleshoot TPM-related settings for gaming.
:: # Use official tools and troubleshooting first!
:: # License: GNU General Public License version 3
set "TPM_TOOL_VERSION=1.0.15"

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

for /f "tokens=4" %%G in ('chcp') do set "ORIGINAL_CP=%%G"
chcp 437 >nul
set "TpmDeviceData="
set "TpmToolType="
call :CollapseCommandOutput TpmDeviceData "tpmtool getdeviceinformation"
call :CollapseCommandOutput TpmToolType "tpmtool /?"
chcp %ORIGINAL_CP% >nul

echo Stage 1 done.

powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content '%~f0' -Raw) -join [Environment]::NewLine)"
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
$global:TotalSteps = 63

$MinBiosDate = [datetime]'2025-08-01'
$TestFile = $env:TPM_TEST_FILE
$global:ClipboardBuffer = ""
$global:ImageBuffer     = [System.Collections.Generic.List[PSObject]]::new()
$global:ProgressStep = 0
$ScriptVersion = $env:TPM_TOOL_VERSION
$global:HasPCRFailures = $false
$global:EnableUploadFeature = $true

# =========================================================================
# FUNCTIONS
# =========================================================================

function Start-TPM-Maintenance {
	#Read TPM from nvram.
	Start-ScheduledTask -TaskPath "\Microsoft\Windows\TPM\" -TaskName "Tpm-Maintenance"
}

function Step-Progress {
    $global:ProgressStep++
    $PercentComplete = [math]::Min(100, [int](($global:ProgressStep / $global:TotalSteps) * 100))
    Write-Progress -Activity "Loading System Diagnostics" -Status "Progress: $PercentComplete%" -PercentComplete $PercentComplete
}

function Get-CpuCompliance {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cpuName = $cpu.Name.Trim() -replace '\s+', ' '
        $oldAMD = $false
		$fakeOldAMD = $false
        $isAmd = $cpu.Manufacturer -like '*AMD*' -or $cpuName -match 'AMD'

        $isRyzenAI   = $cpuName -match "Ryzen AI"
        $isCoreUltra = $cpuName -match "Ultra"
        $genValue = $null

        if ($cpuName -match "Intel") {
            if ($isCoreUltra) {
                if ($cpuName -match "Ultra \d\s+(?:[A-Z]+\s+)?(\d)\d{2}") {
                    $genValue = "Gen: $($Matches[1])"
                }
            } elseif ($cpuName -match "i\d-(\d+)") {
                $modelNum = $Matches[1]
                if ($modelNum.Length -eq 4) { $genValue = "Gen: $($modelNum.Substring(0, 1))" }
                elseif ($modelNum.Length -eq 5) { $genValue = "Gen: $($modelNum.Substring(0, 2))" }
            }
        } elseif ($isAmd -and $cpuName -match "Ryzen") {
            if ($isRyzenAI) {
                if ($cpuName -match "Ryzen AI \d\s+(?:[A-Z]+\s+)?(\d)\d{2}") {
                    $genValue = "Gen: $($Matches[1])"
                }
            } elseif ($cpuName -match "\b(\d)\d{3}\b") {
                $genValue = "Gen: $($Matches[1])"
            }

            if ($cpuName -match '\b([12]\d{3})[A-Z]*\b') {
                $oldAMD = $true
            }

			$fake3rdGenRegex = '\b(3200G|3400G|3100U|3200U|3250U|3250C|3300U|3500U|3500C|3501U|3550H|3580U|3700U|3700C|3750H|3780U|3000G|300GE|3050U|3050e|3050C|3150U|3150G|3150GE)\b'  
			if ($cpuName -match $fake3rdGenRegex) {
				$oldAMD     = $true
				$fakeOldAMD = $true
			}
        }

        return [PSCustomObject]@{
            Name        = $cpu.Name
            Gen         = $genValue
            OldAMD      = $isPassed
			FakeOldAMD  = $fakeOldAMD
            Socket      = $cpu.SocketDesignation
            IsAMD       = $isAmd
            IsCoreUltra = $isCoreUltra
            IsRyzenAI   = $isRyzenAI
        }
    }
    catch {
        return [PSCustomObject]@{
            Name        = "Unknown"
            Gen         = ""
			FakeOldAMD  = $false
            OldAMD      = $false
            Socket      = "Unknown"
            IsAMD       = $false
            IsCoreUltra = $false
            IsRyzenAI   = $false
        }
    }
}

function Get-BatteryStatus {
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            $status = ($battery | Select-Object -First 1).Status
            return [PSCustomObject]@{
                Text    = "Laptop"
                Present = $true
            }
        } else {
            return [PSCustomObject]@{
                Text    = "Desktop"
                Present = $false
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text    = "Unknown"
            Present = $false
        }
    }
}

function Get-RamDetails {
    $ram = Get-CimInstance -ClassName Win32_PhysicalMemory | Select-Object -First 1

    if ($ram) {
        $targetType = if ($ram.SMBIOSMemoryType -and $ram.SMBIOSMemoryType -ne 0) {
            $ram.SMBIOSMemoryType
        } else {
            $ram.MemoryType
        }

        $type = switch ($targetType) {
            20      {'DDR'}
            21      {'DDR2'}
            24      {'DDR3'}
            26      {'DDR4'}
            27      {'LPDDR'}
            28      {'LPDDR2'}
            29      {'LPDDR3'}
            30      {'LPDDR4'}
            34      {'DDR5'}
            35      {'LPDDR5'}
            default {'Unknown'}
        }
        return $type
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

        $smArray = @($smVar)
        $byteValue = $null

        if ($smVar -and $smVar.PSObject.Properties['Bytes']) {
            $byteValue = $smVar.Bytes[0]
        } elseif ($smArray.Count -gt 0) {
            $byteValue = $smArray[0]
        }

        if ($null -ne $byteValue) {
            if (1 -eq $byteValue) {
                return [PSCustomObject]@{
					Text = "Type (Setup Mode)"
					Passed = $false
				}
            } else {
                return [PSCustomObject]@{
					Text = "Type (User Mode)"
					Passed = $true
				}
            }
        } else {
            return [PSCustomObject]@{
				Text = "Type (Unknown - No Data)"
				Passed = $false
			}
        }
    } catch {
        return [PSCustomObject]@{
            Text   = "Type (Unreadable - $($_.Exception.Message))"
            Passed = $false
        }
    }
}

function Get-SecureBootKeysType {
    try {
        function Parse-UefiCert ($KeyName) {
            $Certs = Get-SecureBootUEFI -Name $KeyName -Decoded 2>$null
            if ($Certs) {
                foreach ($Cert in $Certs) {
                    $CN = if ($Cert.Subject -match 'CN=([^,]+)') { $Matches[1] } else { 'Unknown' }
                    [PSCustomObject]@{
                        CN           = $CN
                        SerialNumber = $Cert.SerialNumber
                    }
                }
            }
        }

        [PSCustomObject]@{
            PlatformKey    = Parse-UefiCert -KeyName 'PK'
            KeyExchangeKey = Parse-UefiCert -KeyName 'KEK'
            DbKey          = Parse-UefiCert -KeyName 'db'
        }
    } catch {
        [PSCustomObject]@{
            PlatformKey    = 'error'
            KeyExchangeKey = 'error'
            DbKey          = 'error'
        }
    }
}

function Get-OverallPassStatus {
	param($enrollSuccess, $Data)
	$criticalHardwarePass = $Data.TpmInfo.Passed -and $Data.CsmInfo.Passed -and $Data.TpmOwnership.Passed
							#(unsure if all system work with this -and $Data.LocalAttest
    return ($enrollSuccess -and $criticalHardwarePass)
}

function Get-MicrosoftCaStatus {
    try {
        $db = Get-SecureBootUEFI -Name db -ErrorAction Stop
        $blob = [System.Text.Encoding]::ASCII.GetString($db.Bytes)
        $has2023Key = $blob -like "*Windows UEFI CA 2023*" -or $blob -like "*Microsoft Corporation UEFI CA 2023*"

        $baseData      = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -ErrorAction SilentlyContinue
        $servicingData = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -ErrorAction SilentlyContinue

        $availableUpdates = if ($baseData.PSObject.Properties['AvailableUpdates']) { $baseData.AvailableUpdates } else { 0 }
        $servicingStatus  = if ($servicingData.PSObject.Properties['UEFICA2023Status']) { $servicingData.UEFICA2023Status } else { "Missing" }

        if ($has2023Key) {
            $overallState = "Success"
        }
        elseif ($availableUpdates -eq 0x5944 -and ($servicingStatus -eq "NotStarted" -or $servicingStatus -eq "InProgress")) {
            $overallState = "Stuck"
        }
        elseif ($servicingStatus -eq "PendingReboot") {
            $overallState = "Pending Reboot"
        }
        elseif ($availableUpdates -eq 0 -and $servicingStatus -eq "Missing") {
            $overallState = "Not Required / Not Started"
        }
        else {
            $overallState = "Transient"
        }

        return [PSCustomObject]@{
            Passed       = $has2023Key
            OverallState = $overallState
        }

    } catch {
        return [PSCustomObject]@{
            Passed       = $false
            OverallState = "Unsupported"
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
            $pendingRestart = if ($tpmCmd.RestartPending) { "." } else { "" }
            $statusText = "Ready: $isReady, Present: $($tpmCmd.TpmPresent)$pendingRestart"

            return [PSCustomObject]@{
                Text           = $statusText
                Passed         = $isReady
                PendingRestart = $pendingRestart
                ManufacturerIdTxt = $tpmCmd.ManufacturerIdTxt
            }
        } else {
            return [PSCustomObject]@{
                Text           = "Unable to read TPM Ownership properties via Get-Tpm"
                Passed         = $false
                PendingRestart = $null
                ManufacturerIdTxt = $null
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text           = "Error executing TPM Ownership query"
            Passed         = $false
            PendingRestart = $null
            ManufacturerIdTxt = $null
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

function Get-RandgridRegistryAndDriverInfo {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)

    $platforms = @{
        'Steam'      = 'SYSTEM\CurrentControlSet\Services\atvi-randgrid_sr'
        'Xbox/Store' = 'SYSTEM\CurrentControlSet\Services\atvi-randgrid_msstore'
        'Battle.net' = 'SYSTEM\CurrentControlSet\Services\atvi-randgrid'
    }

    $allResults = @()
    $foundList  = @()
    $charsList  = @()
	$md5List    = @()

    foreach ($platform in $platforms.Keys) {
        $subKeyPath = $platforms[$platform]
        $regKey     = $baseKey.OpenSubKey($subKeyPath)

        $results = [PSCustomObject]@{
            Platform           = $platform
            RegKeyExists       = $null -ne $regKey
            FirstChars         = 'N/A'
            ImagePath          = 'N/A'
            RandgridFileExists = $false
			Md5Hash            = ''
        }

        if ($results.RegKeyExists) {
            $foundList += $platform
            $imagePath = $regKey.GetValue('ImagePath')
            if ($imagePath) {
                $results.ImagePath  = $imagePath
				$results.FirstChars = if ($imagePath.Length -ge 6) { $imagePath.Substring(4,2) } else { $imagePath }
                $charsList += $results.FirstChars

                $cleanPath = $imagePath -replace '^\\[\?]{2}\\', '' -replace '^\\\\\\\?\\\\', ''

                if ($cleanPath -notmatch '^[A-Za-z]:') {
                    $cleanPath = Join-Path $env:SystemRoot $cleanPath
                }

                if (Test-Path $cleanPath) {
                    $results.RandgridFileExists = $true
						try {
							$hash = (Get-FileHash -Path $cleanPath -Algorithm MD5).Hash.Substring(0, 2)
							$results.Md5Hash = $hash
							$md5List += $hash
						} catch {
						}
                }
            }
            $regKey.Close()
        }
        $allResults += $results
    }

    $baseKey.Close()

    $platformsString = if ($foundList.Count -gt 0) {
        ($foundList | ForEach-Object { $_.Substring(0,1) }) -join ', '
    } else {
        'None'
    }

    $allCharsString = if ($charsList.Count -gt 0) {
        ($charsList | Select-Object -Unique) -join ' '
    } else {
        'N/A'
    }

	$allMd5sString = if ($md5List.Count -gt 0) {
        ($md5List | Select-Object -Unique) -join ' '
    } else {
        ''
    }

    return [PSCustomObject]@{
        RegKeyExists       = @($allResults | Where-Object { $_.RegKeyExists }).Count -gt 0
        RandgridFileExists = @($allResults | Where-Object { $_.RandgridFileExists }).Count -gt 0
        FirstChars         = $allCharsString
        PlatformsFound     = $platformsString
        AllPlatforms       = $allResults
		AllMd5s            = $allMd5sString
    }
}

function Get-PlatformInstallStatus {
    $steamInstalled = $false
    $steamPath      = ""
    $bnetInstalled  = $false
    $bnetPath       = ""

    $steamRegKey = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"
    if (Test-Path $steamRegKey) {
        $steamReg = Get-ItemProperty -Path $steamRegKey -Name "InstallPath" -ErrorAction SilentlyContinue
        if ($steamReg -and $steamReg.InstallPath) {
            $libraryPaths = [System.Collections.Generic.List[string]]::new()
            $libraryPaths.Add($steamReg.InstallPath)

            $vdfPath = Join-Path $steamReg.InstallPath "config\libraryfolders.vdf"
            if (Test-Path $vdfPath) {
                $vdfContent = Get-Content $vdfPath -ErrorAction SilentlyContinue
                foreach ($line in $vdfContent) {
                    if ($line -match '"path"\s+"([^"]+)"') {
                        $cleanPath = $Matches[1].Replace("\\", "\")
                        if ($libraryPaths -notcontains $cleanPath) { $libraryPaths.Add($cleanPath) }
                    }
                }
            }

            $steamSubDirs = @("steamapps\common\Call of Duty HQ")
            :steamSearch foreach ($lib in $libraryPaths) {
                foreach ($subDir in $steamSubDirs) {
                    $checkPath = Join-Path $lib $subDir
                    if (Test-Path (Join-Path $checkPath "bootstrapper.exe")) {
                        $steamPath      = $checkPath
                        $steamInstalled = $true
                        break steamSearch
                    }
                }
            }
        }
    }

    $bnetRegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Call of Duty",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Call of Duty"
    )

    foreach ($path in $bnetRegPaths) {
        if (Test-Path $path) {
            $bnetReg = Get-ItemProperty -Path $path -Name "InstallLocation" -ErrorAction SilentlyContinue
            if ($bnetReg -and $bnetReg.InstallLocation -and (Test-Path $bnetReg.InstallLocation)) {
                $locPath = $bnetReg.InstallLocation

                $exeFile = Get-ChildItem -Path $locPath -Filter "bootstrapper.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1

                if ($exeFile) {
                    $foundPath = $exeFile.DirectoryName
                    $bnetPath      = $foundPath
                    $bnetInstalled = $true
                    break
                }
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
        $blankLinesPattern = "(?m)^\s*\r?\n"

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
            -replace $systemUserPattern, "" `
            -replace $blankLinesPattern, ""

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

$KeyName = "TPM_INFO_TOOL_KEY"
$CngProvider = New-Object System.Security.Cryptography.CngProvider("Microsoft Platform Crypto Provider")

function Remove-TpmKey {
    param (
        [string]$KeyName = $script:KeyName
    )

    if ([System.Security.Cryptography.CngKey]::Exists($KeyName, $script:CngProvider)) {
        try {
            $KeyToDelete = [System.Security.Cryptography.CngKey]::Open($KeyName, $script:CngProvider)
            $KeyToDelete.Delete()
        } catch {
            Write-Host "[FAILURE] Could not delete the hardware key." -ForegroundColor Red
            Write-Error $_.Exception.Message
        }
    }
}

function Protect-DataWithTpmKey {
    param (
        [string]$KeyName = $script:KeyName,
        [string]$StringToSign = "TPM INFO TOOL"
    )

    if (-not [System.Security.Cryptography.CngKey]::Exists($KeyName, $script:CngProvider)) {
        try {
            $CngKeyCreationParameters = New-Object System.Security.Cryptography.CngKeyCreationParameters
            $CngKeyCreationParameters.Provider = $script:CngProvider
            $CngKeyCreationParameters.KeyCreationOptions = [System.Security.Cryptography.CngKeyCreationOptions]::None
            $Algorithm = [System.Security.Cryptography.CngAlgorithm]::Rsa

            $Null = [System.Security.Cryptography.CngKey]::Create($Algorithm, $KeyName, $CngKeyCreationParameters)
        } catch {
            Write-Host "[FAILURE] Failed to provision the TPM key." -ForegroundColor Red
            Write-Error $_.Exception.Message
            return $null
        }
    }

    try {
        $TpmKey = [System.Security.Cryptography.CngKey]::Open($KeyName, $script:CngProvider)
        $ChallengeBytes = [System.Text.Encoding]::UTF8.GetBytes($StringToSign)

        $RsaSigner = New-Object System.Security.Cryptography.RSACng($TpmKey)
        $Padding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        $HashAlgorithm = [System.Security.Cryptography.HashAlgorithmName]::SHA256

        $SignatureBytes = $RsaSigner.SignData($ChallengeBytes, $HashAlgorithm, $Padding)
        $SignatureBase64 = [Convert]::ToBase64String($SignatureBytes)

        $PublicKeyBytes = $TpmKey.Export([System.Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob)
        $PublicKeyBase64 = [Convert]::ToBase64String($PublicKeyBytes)

        return [PSCustomObject]@{
            OriginalString  = $StringToSign
            PublicKeyBase64 = $PublicKeyBase64
            SignatureBase64 = $SignatureBase64
        }
    } catch {
        return $null
    }
}

function Test-MyTpmProof {
    param (
        [Parameter(Mandatory = $true)]
        [string]$OriginalString,

        [Parameter(Mandatory = $true)]
        [string]$PublicKeyBase64,

        [Parameter(Mandatory = $true)]
        [string]$SignatureBase64
    )

    try {
        $CleanPublicKey = $PublicKeyBase64 -replace '\s+'
        $CleanSignature = $SignatureBase64 -replace '\s+'

        $PublicKeyBytes = [Convert]::FromBase64String($CleanPublicKey)
        $SignatureBytes = [Convert]::FromBase64String($CleanSignature)
        $DataBytes = [System.Text.Encoding]::UTF8.GetBytes($OriginalString)

        $CngKeyBlobFormat = [System.Security.Cryptography.CngKeyBlobFormat]::GenericPublicBlob
        $CngKey = [System.Security.Cryptography.CngKey]::Import($PublicKeyBytes, $CngKeyBlobFormat)
        $Rsa = New-Object System.Security.Cryptography.RSACng($CngKey)

        $Padding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        $HashAlgorithm = [System.Security.Cryptography.HashAlgorithmName]::SHA256

        $IsValid = $Rsa.VerifyData($DataBytes, $SignatureBytes, $HashAlgorithm, $Padding)
        return $IsValid;
    } catch {
        return $false
    }
}

function Test-LocalAttestation {
    try {
        Remove-TpmKey -KeyName $KeyName -ErrorAction SilentlyContinue

        $CryptoPayload = Protect-DataWithTpmKey -StringToSign "TPM_INFO_TOOL_KEY"

        if ($null -ne $CryptoPayload) {
            return Test-MyTpmProof -OriginalString $CryptoPayload.OriginalString `
                                   -PublicKeyBase64 $CryptoPayload.PublicKeyBase64 `
                                   -SignatureBase64 $CryptoPayload.SignatureBase64
        } else {
            return $false
        }
    }
    catch {
        return $false
    }
    finally {
        Remove-TpmKey -KeyName $KeyName -ErrorAction SilentlyContinue
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

    $requiresUpdate = $tpmVersion -match '30[23]\.12\.'

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
        } elseif ($blVolume) {
            return [PSCustomObject]@{ Text = "No"; Passed = $false }
        }
    } catch {}

    try {
        $bitLockerStatus = Get-CimInstance -Namespace "Root\Microsoft\Windows\CIDatastore" -ClassName "CitBitLockerStatus" -ErrorAction SilentlyContinue
        if ($bitLockerStatus -and $bitLockerStatus.BaseEncryptionStatus -eq 1) {
            return [PSCustomObject]@{ Text = "Yes (Device Encryption)"; Passed = $true }
        }
    } catch {}

    try {
        $manageBde = manage-bde -status C: 2>$null
        if ($manageBde -match "Protection Status:\s+Protection On") {
            return [PSCustomObject]@{ Text = "Yes (Device Encryption)"; Passed = $true }
        } elseif ($manageBde -match "Protection Status:\s+Protection Off") {
            return [PSCustomObject]@{ Text = "No"; Passed = $false }
        }
    } catch {}

    return [PSCustomObject]@{ Text = "No / Not Supported"; Passed = $false }
}

function Get-IntelMeVersion {
    try {
        $meDriver = Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceName LIKE '%Intel%Management Engine%'" |
            Select-Object -First 1

        if ($meDriver -and $meDriver.DriverVersion) {
            if ($meDriver.DriverDate) {
                return [PSCustomObject]@{
                    Version = $meDriver.DriverVersion
                    Date    = $meDriver.DriverDate.ToString("yyyy-MM-dd")
                    RawDate = [datetime]$meDriver.DriverDate
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
        $CertIssuerList = [System.Collections.Generic.List[string]]::new()
        $HasMfg = $null -ne $TpmInfo.ManufacturerCertificates -and $TpmInfo.ManufacturerCertificates.Count -gt 0
        $HasAdd = $null -ne $TpmInfo.AdditionalCertificates -and $TpmInfo.AdditionalCertificates.Count -gt 0

        if ($HasMfg) {
            foreach ($Cert in $TpmInfo.ManufacturerCertificates) {
                $CertIssuerList.Add("INFO:Manufacturer Cert: $($Cert.Issuer)")
            }
        } else {
            $CertIssuerList.Add("INFO:Manufacturer Cert: 0")
        }

        if ($HasAdd) {
            foreach ($Cert in $TpmInfo.AdditionalCertificates) {
                $CertIssuerList.Add("INFO: Additional Cert: $($Cert.Issuer)")
            }
        } else {
            $CertIssuerList.Add("INFO:Additional Cert: 0")
        }

        return [PSCustomObject]@{
            Text = $CertIssuerList -join "`n"
        }

    } catch {
        return [PSCustomObject]@{
            Text = "Error or Access Denied Reading Endorsement Key Info"
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

function Invoke-CodBrokerCycle {
    $serviceName = 'COD.Broker.Service'
    $processName = 'cod'

    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        return "False (Game Running)"
    }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return "False (Service Missing)"
    }

    function Watch-ServiceStatus {
        param (
            [System.ServiceProcess.ServiceController]$Service,
            [string]$TargetStatus,
            [double]$TimeoutSec = 3.5,
            [double]$IntervalSec = 0.5
        )
        $elapsed = 0
        while ($Service.Status -ne $TargetStatus -and $elapsed -lt $TimeoutSec) {
            Start-Sleep -Seconds $IntervalSec
            $elapsed += $IntervalSec
            $Service.Refresh()
        }
        return ($Service.Status -eq $TargetStatus)
    }

    try {
        if ($service.Status -ne 'Running') {
            Start-Service -Name $serviceName -ErrorAction Stop
            if (-not (Watch-ServiceStatus -Service $service -TargetStatus 'Running')) {
                return "False (Timeout / Hung on Start)"
            }
        }

        Stop-Service -Name $serviceName -Force -ErrorAction Stop -WarningAction SilentlyContinue
        if (-not (Watch-ServiceStatus -Service $service -TargetStatus 'Stopped')) {
            return "False (Timeout / Hung on Stop)"
        }

        return "True"
    }
    catch {
        return "False (Service Issue: $_)"
    }
}

function Print-CodBrokerCycleStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CycleResult
    )

    $cleanResult = $CycleResult.Trim()

    if ($cleanResult -eq "True") {
        Log-Output "[PASS] COD Broker Service Cycled" 'Green'
    } else {
        Log-Output "[FAIL] COD Broker Service Cycled: $cleanResult" 'Red'
    }
}

function Check-CodBrokerService {
    param (
        [Parameter(Mandatory = $true)]
        $Data
    )

    if ($Data.CodBroker -and $Data.CodBroker.StartType -eq 'Disabled') {
        Write-Host "`n=========================================================================" -ForegroundColor Yellow
        Write-Host "[!] COD Broker Service is currently Disabled." -ForegroundColor Yellow
        $choice = Read-Host "Would you like to attempt to repair it now? [Y/N]"

        if ($choice -match '^[Yy]') {
            try {
                Set-Service -Name 'COD.Broker.Service' -StartupType Manual -ErrorAction Stop
            } catch {
            }
        }
    }
}

function Test-SocialMedia_UEFICA2023 {
    [bool](Get-ChildItem -Path Cert:\LocalMachine\*, Cert:\CurrentUser\* -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "*Windows UEFI CA 2023*" } |
        Select-Object -First 1)
}

function Get-Event1040Details {
    [CmdletBinding()]
    param(
        [string]$LogName = 'Application',
        [int]$EventId = 1040
    )

    $startTime = (Get-Date).AddDays(-1)

    $event = Get-WinEvent -FilterHashtable @{
        LogName   = $LogName
        Id        = $EventId
        Level     = 2
        StartTime = $startTime
    } -MaxEvents 1 -ErrorAction SilentlyContinue

    if (-not $event) {
        return [PSCustomObject]@{
            Found    = $false
            Filename = $null
        }
    }

    $xml = [xml]$event.ToXml()
    $filename = $xml.Event.EventData.Data | Where-Object { $_ -match '\d{10}-\d{10}\.json' }

    return [PSCustomObject]@{
        Found    = $true
        Filename = $filename
    }
}

function Get-EfiBootSignature {
    param (
        [string]$DriveLetter = "S:"
    )

    if ($DriveLetter -notmatch ':$') { $DriveLetter += ':' }
    $bootPath = "$DriveLetter\EFI\Microsoft\Boot\bootmgfw.efi"

    try {
        $null = mountvol $DriveLetter /s

        if (Test-Path -Path $bootPath) {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromSignedFile($bootPath)
            $issuer = $cert.Issuer

            if ($issuer -like "*2023*") {
                return "2023"
            }
            elseif ($issuer -like "*2011*") {
                return "2011"
            }
        }
        return "Unknown"
    }
    catch {
        return "Unknown"
    }
    finally {
        $null = mountvol $DriveLetter /d
    }
}

function Get-PC-ID {
    [CmdletBinding()]
    param ()

    try {
        $MachineSystemProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        $HardwareUuid         = $MachineSystemProduct.UUID

        $CryptoMd5Provider = [System.Security.Cryptography.MD5]::Create()
        $RawUuidBytes      = [System.Text.Encoding]::UTF8.GetBytes($HardwareUuid)
        $ComputedHashBytes = $CryptoMd5Provider.ComputeHash($RawUuidBytes)

        $DeterministicIntId = [System.Math]::Abs([System.BitConverter]::ToInt32($ComputedHashBytes, 0))

        $SevenDigitBaseValue = ($DeterministicIntId % 9000000) + 1000000
        $BaseStringValue     = $SevenDigitBaseValue.ToString()

        $CryptoMd5Provider.Dispose()
        return $BaseStringValue
    }
    catch {
        return "0000000"
    }
}

function Convert-Rot13 {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$InputString
    )

    process {
        return [regex]::Replace($InputString, '[a-zA-Z]', {
            param($m)
            $c = [int]$m.Value[0]
            $base = if ($c -ge 97) { 97 } else { 65 }
            return [char]((($c - $base + 13) % 26) + $base)
        })
    }
}

function Get-URL { #Reduce Spam
    return "https://" + (Convert-Rot13 "neebjtnzvat.qri") + "/INFO_TOOL/"
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

function Is-Pluton {
    $plutonCheck = Get-PnpDevice -FriendlyName "*Pluton*" -Status OK -ErrorAction SilentlyContinue
    return [bool]$plutonCheck
}

function Test-CertutilPluton {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CertutilText
    )

    if ($CertutilText -match "msft-keyid-") {
        return $true
    } else {
        return $false
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
                        $check_secureBootState = "Fail"
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
            if ($data -match "debug=true" -or $data -match "bootdebug=true") { $check_kernelDebug = "Fail" }
            else { $check_kernelDebug = "Pass" }
        }
        if ($event.PCRIndex -eq 13 -and ($data -match "VbsSiPolicy.p7b" -or $data -match "siPolicy")) {
            $check_bitlockerPolicy = $true
        }
    }

    if ($hasPcr7Variables -and $check_pkKeyPresent -and $check_dbKeyPresent) {
        $check_pcr7Attestation = $true
    }

    $failedChecks = @()

    if ($check_secureBootState -ne "Pass") { $failedChecks += "SecureBootState" }
    if (-not $check_pkKeyPresent)          { $failedChecks += "PkKeyPresent" }
    if (-not $check_kekKeyPresent)         { $failedChecks += "KekKeyPresent" }
    if (-not $check_dbKeyPresent)          { $failedChecks += "DbKeyPresent" }
    if (-not $check_dbxKeyPresent)         { $failedChecks += "DbxKeyPresent" }
    if ($check_kernelDebug -ne "Pass")     { $failedChecks += "KernelDebug" }
    if (-not $check_pcr7Attestation)       { $failedChecks += "Pcr7Attestation" }

    if ($failedChecks.Count -eq 0) {
        return [PSCustomObject]@{
            message  = "[PASS] Measured Boot Check"
            pass = $true
        }
    } else {
        return [PSCustomObject]@{
            message  = "[WARN] Measured Boot Check: $($failedChecks -join ', ')"
            pass = $false
        }
    }
}

function Show-TcgAttestationAudit ($Data) {
    Log-Output "--- MEASURED BOOT BINARY AUDIT ---" 'Cyan'
	Show-PCR_Message

	if($Data.ComparedKeyId){
		Log-Output "[PASS] Key Comp" 'Green'
	}else{
		Log-Output "[WARN] Key Comp" 'Yellow'
	}

	if($Data.MeasuredBootCompliance.pass){
		Log-Output $Data.MeasuredBootCompliance.message 'Green'
	}else{
		Log-Output $Data.MeasuredBootCompliance.message 'Yellow'
	}

	Log-Output "DBX: Recent: $($Data.ScoreRecentShims) All: $($Data.ScoreShims)" 'White'
	Log-Output "Efi Boot: $($Data.EfiBootSignature)" 'White'

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

function Get-UacStatus {
    $Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

    try {
        $RegistrySettings = Get-ItemProperty -Path $Path -ErrorAction Stop
        $EnableLUA                 = $RegistrySettings.EnableLUA
        $ConsentPromptBehaviorAdmin = $RegistrySettings.ConsentPromptBehaviorAdmin
        $PromptOnSecureDesktop     = $RegistrySettings.PromptOnSecureDesktop

        if ($EnableLUA -eq 0) {
            return "UAC Disabled"
        }
        else {
            switch ($ConsentPromptBehaviorAdmin) {
                0 { return "Never Notify" }
                5 {
                    if ($PromptOnSecureDesktop -eq 0) {
                        return "Don't Dim Desktop"
                    } else {
                        return "Default"
                    }
                }
                2 { return "Always Notify" }
                default { return "Custom" }
            }
        }
    } catch {
        return "Unknown"
    }
}

function Get-CertreqAttestation($Data) {
	Write-Host "Testing Certreq.." -ForegroundColor White
	if ($TestFile -and (Test-Path $TestFile)) {
        $certRaw = Get-Content $TestFile -Raw
    } else {
        $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = New-Object System.Globalization.CultureInfo("en-US")
        try {
            $certRaw = certreq -q -enrollaik -f -config '""' 2>&1 | Out-String
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = $oldCulture
        }
    }
	Write-Progress -Activity "Loading System Diagnostics" -Completed

    $successPatterns = "(?s)(?=.*SCEPDispositionSuccess)(?=.*EnrollStatus\(1\):\s*Enrolled)(?=.*New Certificate:)"
	$enrollSuccess = $certRaw -match $successPatterns
	if ($certRaw -match "Bad Request" -or $certRaw -match "No valid TPM EK") {
        $enrollSuccess = $false
    }

	$nameResolutionFailure = $certRaw -match "The server name or address could not be resolved"
	$failureType1 = $certRaw -match "1168 ERROR_NOT_FOUND"
	$serverOverload = $certRaw -match "Too Many Requests"

	$failureMessage = ""
	if($failureType1){
		$failureMessage = "[FAIL] CertReq - registry issue?"
	}
	if($serverOverload ){
		$failureMessage = "[FAIL] Server Overloaded - Please run again"
	}

	$IsOverallAIKPass = Get-OverallPassStatus -enrollSuccess $enrollSuccess -data $Data

	if ($IsOverallAIKPass) {
		$OverallPassResult = 1;
	}else{
		$OverallPassResult = 0;

		if (Is-NextGenTPM -Data $Data) {
			$OverallPassResult = 2;
		}

		if($serverOverload){
			$OverallPassResult = 2;
		}
	}

	#$OverallPassResult = 2;

    return [PSCustomObject]@{
        CertRaw       = $certRaw
        OverallPassResult = $OverallPassResult
		IsOverallAIKPass = $IsOverallAIKPass;

		EnrollSuccess = $enrollSuccess
		NameResolutionFailure = $nameResolutionFailure
		FailureMessage = $failureMessage
    }
}

function Is-NextGenTPM {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    if ($Data.Pluton) {
        return $true
    }

	if ($Data.TpmOwnership.ManufacturerIdTxt -eq "MSFT") {
		return $true
    }

	if ($Data.CpuInfo.IsCoreUltra) {
		return $true
    }

	if ($Data.CpuInfo.IsRyzenAI) {
		if (-not $data.HasEK) {
			return $true
		}
    }

    return $false
}

function HasEK {
    try {
        $ek = Get-TpmEndorsementKeyInfo -ErrorAction Stop
        if ($ek.PublicKey) {
            return $true
        } else {
            return $false
        }
    } catch {
        return $false
    }
}

function Compare-TpmKeyId {
    param (
        [string]$certData,
        [string]$tpmKeyId
    )

	if ($certData -match '-KeyId-([a-f0-9]+)') {
		$certKeyId = $Matches[1]
	}

    if ($certKeyId -eq $tpmKeyId) {
        return $true
    }

    return $false
}

function Get-LiveTpmKeyId {
    $certData = certutil -silent -v -tpmInfo 2>$null | Out-String

    $pattern = 'KeyID\s*=\s*(?<id>[A-Fa-f0-9]{6,})'

    if ($certData -match $pattern) {
        return $Matches['id']
    }

    return $false
}

function Get-CODBrokerInfo {
    $filePath = 'C:\ProgramData\Activision\Call of Duty\CODBrokerService.exe'

    if (Test-Path -Path $filePath) {
        $brokerVersion = (Get-ItemProperty -Path $filePath).VersionInfo.FileVersion
        $md5Short      = (Get-FileHash -Path $filePath -Algorithm MD5).Hash.Substring(0, 2)

        [PSCustomObject]@{
            Version     = $brokerVersion
            MD5ShortHex = $md5Short
        }
    } else {
        return $null
    }
}

function Test-TPMSha256Support {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\IntegrityServices"
    if (Test-Path $path) {
        $value = Get-ItemPropertyValue -Path $path -Name "TPMActivePCRBanks" -ErrorAction SilentlyContinue
        if ($null -ne $value) {
            return [bool]($value -band 0x00000002)
        }
    }
    return $false
}

function Test-MSI {
    [CmdletBinding()]
    param()

    $data = [ordered]@{
        ComputerSystem = (Get-CimInstance Win32_ComputerSystem).Manufacturer
        BaseBoard      = (Get-CimInstance Win32_BaseBoard).Manufacturer
        BIOS           = (Get-CimInstance Win32_BIOS).Manufacturer
        Enclosure      = (Get-CimInstance Win32_SystemEnclosure).Manufacturer
    }

    $normalized = $data.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            Source       = $_.Key
            Manufacturer = ($_.Value -as [string]).Trim().ToUpper()
        }
    }

    $pattern = 'MSI|MICRO-STAR'
    $isMSI = $normalized.Manufacturer -match $pattern

    [PSCustomObject]@{
        IsMSI          = ($isMSI.Count -gt 0)
    }
}

function Get-AgesaVersion {
    try {
        $CpuVendor = Get-CimInstance -ClassName Win32_Processor | Select-Object -ExpandProperty Manufacturer
        if ($CpuVendor -notmatch 'Advanced Micro Devices|AMD') {
            Write-Warning "This system does not appear to be running an AMD processor (Vendor: $CpuVendor)."
            return $null
        }

        $RawSmbios = Get-CimInstance -Namespace root\wmi -ClassName MSSmBios_RawSMBiosTables -ErrorAction Stop
        $Bytes = $RawSmbios.SMBiosData

        $AsciiString = [System.Text.Encoding]::ASCII.GetString($Bytes)

        if ($AsciiString -match 'AGESA[^a-zA-Z0-9]*(.{1,20})') {
            return $Matches[1].Trim()
        } else {
            return $null
        }
    }
    catch [UnauthorizedAccessException] {
        return $null
    }
    catch {
        return $null
    }
}

function BIOS_TPM_ResetMessage {
	Log-Output "Reset the TPM from the BIOS. Look for 'Pending Operation'."
	Log-Output " AM4 Gigabyte->BIOS->Advanced->Miscellaneous->Trusted Computing 2.0->Pending Operation->TPM Clear."
	Log-Output " AM5 MSI->Security->Trusted Computing 2.0->Pending Operation->TPM Clear."
}

function Get-LatestUpdatesSummary {
    $updates = Get-HotFix | Where-Object { $_.InstalledOn }
    if (-not $updates) { return "No updates found with valid dates." }

    $latestDate = ($updates | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn.Date
    $kbList = ($updates | Where-Object { $_.InstalledOn.Date -eq $latestDate }).HotFixID -join ", "

    return "$($latestDate.ToString('dd/MM/yyyy')): $kbList"
}

function Get-EventId87 {
    try {
        $OneWeekAgo = (Get-Date).AddDays(-7)
        $Filter = @{
            LogName   = 'Application'
            Id        = 87
            StartTime = $OneWeekAgo
        }

        $Events = Get-WinEvent -FilterHashtable $Filter -MaxEvents 2 -ErrorAction SilentlyContinue

        if ($null -eq $Events) {
            return
        }

        foreach ($Event in $Events) {
            if ($Event.Message -match 'Submit\(ChallengeAnswer\):\s*(.*)') {
                $Answer = $Matches[1].Trim()
                "$($Event.TimeCreated) - $Answer"
            }
        }
    }
    catch {
        Write-Error $_
    }
}

function Get-DbxRevocationScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string[]]$Hashes
    )

    begin {
        try {
            $DbxBytes = (Get-SecureBootUEFI -Name dbx).Bytes
            $script:DbxHex = [System.BitConverter]::ToString($DbxBytes) -replace '-'
        } catch {
            throw "Failed to read Secure Boot DBX: $_"
        }

        $script:InputHashes = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($Hash in $Hashes) {
            $script:InputHashes.Add($Hash)
        }
    }

    end {
        if ($script:InputHashes.Count -eq 0) {
            return 0
        }

        $MatchCount = ($script:InputHashes | Where-Object { $script:DbxHex -like "*$_*" }).Count

        return "$($MatchCount)/$($Hashes.Count)"
    }
}

# =========================================================================
# FIX Menu
# =========================================================================

function Show-FixMenu {
    param (
        [string]$Message = ""
    )

    Clear-Host
    Write-Host "             TPM INFO TOOL - FIX MENU         " -ForegroundColor Cyan -BackgroundColor DarkCyan
    Write-Host "=============================================" -ForegroundColor Cyan

    if (-not [string]::IsNullOrEmpty($Message)) {
        Write-Host "NOTE: $Message" -ForegroundColor Yellow
        Write-Host "=============================================" -ForegroundColor Cyan
    }

    Write-Host "Please only run this if you have been asked to:"  -ForegroundColor White
    Write-Host "1) Reset Windows TPM Cache"                       -ForegroundColor White
    Write-Host "2) Attempt to install UEFI CA 2023"               -ForegroundColor White
	Write-Host "3) Delete Activision Key"                         -ForegroundColor White
	Write-Host "4) Print PCR Table"                               -ForegroundColor White
	Write-Host "5) Print DBX Table"                               -ForegroundColor White
    Write-Host "Q) Quit"                                          -ForegroundColor Red
    Write-Host "============================================="    -ForegroundColor Cyan

    $choice = Read-Host "Select an option"

    switch ($choice) {
        "1" {
            Reset-WindowsCache
            Show-FixMenu -Message "TPM Cache Reset completed successfully."
        }
        "2" {
            Set-SecureBoot2023Certificates
        }
        "3" {
            Reset-ActivisionKey
        }
        "4" {
            Print-PCRTable
			pause
			Show-FixMenu
        }
        "5" {
            Print-DBX | Format-Table -Property @{E='Authority CN'; Width=40}, @{E='Description'; Width=35}, Hash -Wrap
			pause
			Show-FixMenu
        }
        "Q" {
			cls
            exit
        }

        default {
            Show-FixMenu -Message "Invalid selection. Please try again."
        }
    }
}

function Reset-WindowsCache{
	$Path1 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tpm\WMI\Provisioning"
	$Path2 = "HKLM:\SYSTEM\CurrentControlSet\Services\Tpm\WMI\Endorsement"
	if (Test-Path $Path1) {
		Remove-Item -Path $Path1 -Recurse -Force
	}
	if (Test-Path $Path2) {
		Remove-Item -Path $Path2 -Recurse -Force
	}
	Start-TPM-Maintenance
	Write-Host "Actioned" -ForegroundColor Green
}

function Set-SecureBoot2023Certificates {
    try {
        $uefiDb = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes)
        if ($uefiDb -match 'Windows UEFI CA 2023') {
            Show-FixMenu -Message "Secure Boot 2023 certificates are ALREADY installed. No action required."
            return
        }
    } catch {
        $status = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -ErrorAction SilentlyContinue
        if ($status.UEFICA2023Status -eq "Updated") {
            Show-FixMenu -Message "Secure Boot 2023 certificates are ALREADY marked as Updated. No action required."
            return
        }
    }

    Write-Host "WARNING: In rare cases, this may trigger a Secure Boot Violation." -ForegroundColor Yellow
    Write-Host "Do you wish to continue? (Y/N)" -ForegroundColor Yellow

    $choice = Read-Host "Enter choice"

    if($choice.ToUpper() -eq "Y") {

    }else{
        Write-Host "Cancelled" -ForegroundColor Yellow
        return
    }

    $os = Get-CimInstance Win32_OperatingSystem

    if ($os.Caption -match "Windows 10") {
        $ubr = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
        if ($ubr -lt 4169) {
            $kbCheck = Get-HotFix -Id "KB5036210" -ErrorAction SilentlyContinue
            if (-not $kbCheck) {
                Write-Error "Windows 10 is missing mandatory Secure Boot servicing files. Please run Windows Update first."
                return
            }
        }
    }

    $blStatus = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if ($blStatus | Where-Object { $_.VolumeStatus -eq 'Encrypted' -or $_.ProtectionStatus -eq 'On' }) {
        Write-Warning "Cancelled as BitLocker is ENABLED"
        return
    }

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"
    $bitmask = 0x5944

    try {
        Set-ItemProperty -Path $regPath -Name "AvailableUpdates" -Value $bitmask -Force -ErrorAction Stop
        Start-ScheduledTask -TaskPath "\Microsoft\Windows\PI\" -TaskName "Secure-Boot-Update" -ErrorAction Stop
        Write-Host "Success. Reboot your PC twice consecutively." -ForegroundColor Green
    } catch {
        Write-Error "Execution failed to push keys to staging: $_"
    }
	pause
}

function Reset-ActivisionKey {
    try {
        $keys = certutil -csp "Microsoft Platform Crypto Provider" -key 2>&1
        $index = [array]::FindIndex($keys, [Predicate[object]]{ $args[0] -match "ActivisionAIK" })

        if ($index -ge 0 -and $index -lt ($keys.Count - 1)) {
            $filePath = $keys[$index + 1].Trim()

            if (Test-Path $filePath) {
                Rename-Item -Path $filePath -NewName "$($filePath | Split-Path -Leaf).bak" -Force
                Show-FixMenu -Message "Successfully renamed key file to: $filePath.bak"
            } else {
                Show-FixMenu "Key found in certutil, but physical file not found at: $filePath"
            }
        } else {
            Show-FixMenu "ActivisionAIK key not found."
        }
    } catch {
       Show-FixMenu "Error: $($_.Exception.Message)"
    }
}

function Print-DBX {
    $script:dbxData = (Get-SecureBootUEFI -Name dbx -Decoded) | Select-Object `
        @{N='Authority CN'; E={
            if ($_.Authority) {
                $_.Authority -match 'CN\s*=\s*([^,]+)' | Out-Null; $Matches[1]
            } elseif ($_.Subject) {
                $_.Subject -match 'CN\s*=\s*([^,]+)' | Out-Null; $Matches[1]
            } else {
                "N/A (Raw Hash)"
            }
        }},
        @{N='Description'; E={
            if ($_.Description) { $_.Description }
            elseif ($_.Company) { $_.Company }
            else { "N/A" }
        }},
        @{N='Hash'; E={
            if ($_.Hash) { $_.Hash }
            elseif ($_.Fingerprint) { $_.Fingerprint }
            else { $_.SerialNumber }
        }}

    # Return the variable so it still outputs to console if desired
    return $script:dbxData
}

# =========================================================================
# PRINT PIPELINE
# =========================================================================

function Show-PlatformStatus {
    $foundPlatforms = @()

    if ($global:platforms.SteamFound) {
        $foundPlatforms += "Steam"
    }

    if ($global:platforms.BnetFound) {
        $foundPlatforms += "BNET"
    }

    if ($foundPlatforms.Count -gt 0) {
        # Joins the array elements with '/' (e.g., "Steam/BNET")
        $platformString = $foundPlatforms -join "/"
        Log-Output "RESULT: COD $platformString Found"
    } else {
        Log-Output "RESULT: Neither COD Steam/BNET detected"
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

    $global:ImageBuffer.Add([PSCustomObject]@{
        Text      = $Text
        Color     = $Color
        NoNewLine = $NoNewLine
    })
}

function Show-PCR_Message() {
    $HasFailures = $false
    $FailedRegisters = [System.Collections.Generic.List[string]]::new()
	$MatchCount = 0

    Get-PCR | ForEach-Object {

        if ($_ -match 'PCR\[(?<num>\d+)\]') {
            $pcrNum = $Matches['num']
            $CleanedLine = $_.Trim(" |!`r`n")
            if ($_ -match 'MISMATCH|Failed|Error') {
                $HasFailures = $true
                $FailedRegisters.Add("PCR[$pcrNum]")
                Log-Output $CleanedLine 'Red'
            }
            elseif ($pcrNum -eq '00' -or $pcrNum -eq '0') {
                Log-Output $CleanedLine 'White'
            }

			if ($_ -match 'MATCH' -and -not ($_ -match 'MISMATCH')) {
				$MatchCount++
			}
        }
    }

    if (-not $HasFailures) {
        Log-Output "[PASS] Hardware log verification matches live $MatchCount PCR registers.)" 'Green'
		$global:HasPCRFailures = $true
    } else {
        Log-Output "[WARN] Cryptographic Mismatch Detected! Physical TPM registers do not match log history." 'DarkYellow'
        Log-Output "       Affected Registers: $($FailedRegisters -join ', ')" 'DarkRed'
    }
}

# =========================================================================
# SHIMS
# =========================================================================

$RevokedRecentShims = @(
    "AE75F0D82BA3DF824FBFC69340CC3B4D66C598373B1AB54CDB6C8BFD83A6B961",
    "FD23D6E57DE6F4E1F9D7118DA1C5F31A8AF6BE5E5D9E8170F9493447268D50C5",
    "A0DE9333442C1BF9349A460141AE5E80F911955C6506040FA3D021BF6C1AE3E4",
    "7F8C4A9213192CDB9B4F831C1A53EAE1842C9C227F6D43B06C19F215038A6A4E",
    "C55C3E3A4B8298AD2E9452E58C3005A32B669145A760630D29E1A29D64C59218",
    "5B1C289569727B422CD0042A27A795A8D38316B79D5C80FA3D8A29BD64929D7A",
    "8B7394E612B895FA148E730948924089C57904C9281B94C1083984E2A895C911",
    "12B008A5EAE99A50123BD82A036E7BCE798084A4960B379510C1B039A5D6B428",
    "3E2914B007B2D2B03C590E8F9B8A749021884C0A1C81134594A02A0B70891234",
    "8F1023948BA023C91480C2951C81034A7B28391A041B82A9C02193857B910A2D",
    "94A021884C0A1C81134594A02A0B7089123412B008A5EAE99A50123BD82A036E"
)


$RevokedShims = @(
    "80B4D96931BF0D02FD91A61E19D14F1DA452E66DB2408CA8604D411F92659F0A",
    "F52F83A3FA9CFBD6920F722824DBE4034534D25B8507246B3B957DAC6E1BCE7A",
    "C5D9D8A186E2C82D09AFAA2A6F7F2E73870D3E64F72C4E08EF67796A840F0FBD",
    "1AEC84B84B6C65A51220A9BE7181965230210D62D6D33C48999C6B295A2B0A06",
    "C3A99A460DA464A057C3586D83CEF5F4AE08B7103979ED8932742DF0ED530C66",
    "58FB941AEF95A25943B3FB5F2510A0DF3FE44C58C95E0AB80487297568AB9771",
    "5391C3A2FB112102A6AA1EDC25AE77E19F5D6F09CD09EEB2509922BFCD5992EA",
    "D626157E1D6A718BC124AB8DA27CBB65072CA03A7B6B257DBDCBBD60F65EF3D1",
    "D063EC28F67EBA53F1642DBF7DFF33C6A32ADD869F6013FE162E2C32F1CBE56D",
    "29C6EB52B43C3AA18B2CD8ED6EA8607CEF3CFAE1BAFE1165755CF2E614844A44",
    "90FBE70E69D633408D3E170C6832DBB2D209E0272527DFB63D49D29572A6F44C",
    "106FACEACFECFD4E303B74F480A08098E2D0802B936F8EC774CE21F31686689C",
    "174E3A0B5B43C6A607BBD3404F05341E3DCF396267CE94F8B50E2E23A9DA920C",
    "2B99CF26422E92FE365FBF4BC30D27086C9EE14B7A6FFF44FB2F6B9001699939",
    "2E70916786A6F773511FA7181FAB0F1D70B557C6322EA923B2A8D3B92B51AF7D",
    "3FCE9B9FDF3EF09D5452B0F95EE481C2B7F06D743A737971558E70136ACE3E73",
    "47CC086127E2069A86E03A6BEF2CD410F8C55A6D6BDB362168C31B2CE32A5ADF",
    "71F2906FD222497E54A34662AB2497FCC81020770FF51368E9E3D9BFCBFD6375",
    "82DB3BCEB4F60843CE9D97C3D187CD9B5941CD3DE8100E586F2BDA5637575F67",
    "8AD64859F195B5F58DAFAA940B6A6167ACD67A886E8F469364177221C55945B9",
    "8D8EA289CFE70A1C07AB7365CB28EE51EDD33CF2506DE888FBADD60EBF80481C",
    "AEEBAE3151271273ED95AA2E671139ED31A98567303A332298F83709A9D55AA1",
    "C409BDAC4775ADD8DB92AA22B5B718FB8C94A1462C1FE9A416B95D8A3388C2FC",
    "C617C1A8B1EE2A811C28B5A81B4C83D7C98B5B0C27281D610207EBE692C2967F",
    "C90F336617B8E7F983975413C997F10B73EB267FD8A10CB9E3BDBFC667ABDB8B",
    "64575BD912789A2E14AD56F6341F52AF6BF80CF94400785975E9F04E2D64D745",
    "45C7C8AE750ACFBB48FC37527D6412DD644DAED8913CCD8A24C94D856967DF8E",
    "81D8FB4C9E2E7A8225656B4B8273B7CBA4B03EF2E9EB20E0A0291624ECA1BA86",
    "B92AF298DC08049B78C77492D6551B710CD72AADA3D77BE54609E43278EF6E4D",
    "E19DAE83C02E6F281358D4EBD11D7723B4F5EA0E357907D5443DECC5F93C1E9D",
    "39DBC2288EF44B5F95332CB777E31103E840DBA680634AA806F5C9B100061802",
    "32F5940CA29DD812A2C145E6FC89646628FFCC7C7A42CAE512337D8D29C40BBD",
    "10D45FCBA396AEF3153EE8F6ECAE58AFE8476A280A2026FC71F6217DCF49BA2F",
    "C805603C4FA038776E42F263C604B49D96840322E1922D5606A9B0BBB5BFFE6F",
    "D8D4E6DDF6E42D74A6A536EA62FD1217E4290B145C9E5C3695A31B42EFB5F5A4",
    "F277AF4F9BDC918AE89FA35CC1B34E34984C04AE9765322C3CB049574D36509C",
    "68EE4632C7BE1C66C83E89DD93EAEE1294159ABF45B4C2C72D7DC7499AA2A043",
    "148FE18F715A9FCFE1A444CE0FFF7F85869EB422330DC04B314C0F295D6DA79E",
    "AD3BE589C0474E97DE5BB2BF33534948B76BB80376DFDC58B1FED767B5A15BFC",
    "E051B788ECBAEDA53046C70E6AF6058F95222C046157B8C4C1B9C2CFC65F46E5",
    "C452AB846073DF5ACE25CCA64D6B7A09D906308A1A65EB5240E3C4EBCAA9CC0C",
    "3A91F0F9E5287FA2994C7D930B2C1A5EE14CE8E1C8304AE495ADC58CC4453C0C",
    "1B909115A8D473E51328A87823BD621CE655DFAE54FA2BFA72FDC0298611D6B8",
    "8C0349D708571AE5AA21C11363482332073297D868F29058916529EFC520EF70",
    "EED7E0EFF2ED559E2A79EE361F9962AF3B1E999131E30BB7FD07546FAE0A7267",
    "BADFF5E4F0FEA711701CA8FB22E4C43821E31E210CF52D1D4F74DD50F1D039BC",
    "D89A11D16C488DD4FBBC541D4B07FAF8670D660994488FE54B1FBFF2704E4288",
    "F2A16D35B554694187A70D40CA682959F4F35C2CE0EAB8FD64F7AC2AB9F5C24A",
    "5B248E913D71853D3DA5AEDD8D9A4BC57A917126573817FB5FCB2D86A2F1C886",
    "7EAC80A915C84CD4AFEC638904D94EB168A8557951A4D539B0713028552B6B8C",
    "E7681F153121EA1E67F74BBCB0CDC5E502702C1B8CC55FB65D702DFBA948B5F4",
    "804E354C6368BB27A90FAE8E498A57052B293418259A019C4F53A2007254490F",
    "B93F0699598F8B20FA0DACC12CFCFC1F2568793F6E779E04795E6D7C22530F75",
    "EAFF8C85C208BA4D5B6B8046F5D6081747D779BADA7768E649D047FF9B1F660C",
    "C9EC350406F26E559AFFB4030DE2EBDE5435054C35A998605B8FCF04972D8D55",
    "340DA32B58331C8E2B561BAF300CA9DFD6B91CD2270EE0E2A34958B1C6259E85",
    "5C39F0E5E0E7FA3BE05090813B13D161ACAF48494FDE6233B452C416D29CDDBE",
    "DD59AF56084406E38C63FBE0850F30A0CD1277462A2192590FB05BC259E61273",
    "0FA3A29AD05130D7FE5BF4D2596563CDED1D874096AACC181069932A2E49519A",
    "DBAF9E056D3D5B38B68553304ABC88827EBC00F80CB9C7E197CDBC5822CD316C",
    "0CE02100F67C7EF85F4EED368F02BF7092380A3C23CA91FD7F19430D94B00C19",
    "2B2298EAA26B9DC4A4558AE92E7BB0E4F85CF34BF848FDF636C0C11FBEC49897",
    "3765D769C05BF98B427B3511903B2137E8A49B6F859D0AF159ED6A86786AA634",
    "78B4EDCAABC8D9093E20E217802CAEB4F09E23A3394C4ACC6E87E8F35395310F",
    "9954A1A99D55E8B189AB1BCA414B91F6A017191F6C40A86B6F3EF368DD860031",
    "F1B4F6513B0D544A688D13ADC291EFA8C59F420CA5DCB23E0B5A06FA7E0D083D",
    "F1863EC8B7F43F94AD14FB0B8B4A69497A8C65ECBC2A55E0BB420E772B8CDC91",
    "781764102188A8B4B173D4A8F5EC94D828647156097F99357A581E624B377509",
    "E6856F137F79992DC94FA2F43297EC32D2D9A76F7BE66114C6A13EFC3BCDF5C8",
    "81A8B2C9751AEB1FABA7DBDE5EE9691DC0EAEE2A31C38B1491A8146756A6B770",
    "9FA4D5023FD43ECAFF4200BA7E8D4353259D2B7E5E72B5096EFF8027D66D1043",
    "D372C0D0F4FDC9F52E9E1F23FC56EE72414A17F350D0CEA6C26A35A6C3217A13",
    "09F98AA90F85198C0D73F89BA77E87EC6F596C491350FB8F8BBA80A62FBB914B",
    "147730B42F11FE493FE902B6251E97CD2B6F34D36AF59330F11D02A42F940D07",
    "29CCA4544EA330D61591C784695C149C6B040022AC7B5B89CBD72800D10840EA",
    "2DCF8E8D817023D1E8E1451A3D68D6EC30D9BED94CBCB87F19DDC1CC0116AC1A",
    "3A4F74BEAFAE2B9383AD8215D233A6CF3D057FB3C7E213E897BEEF4255FAEE9D",
    "4185821F6DAB5BA8347B78A22B5F9A0A7570CA5C93A74D478A793D83BAC49805",
    "45876B4DD861D45B3A94800774027A5DB45A48B2A729410908B6412F8A87E95D",
    "5890FA227121C76D90ED9E63C87E3A6533EEA0F6F0A1A23F1FC445139BC6BCDF",
    "5D1E9ACBBB4A7D024B6852DF025970E2CED66FF622EE019CD0ED7FD841CCAD02",
    "6DEAD13257DFC3CCC6A4B37016BA91755FE9E0EC1F415030942E5ABC47F07C88",
    "BEF7663BE5EA4DBFD8686E24701E036F4C03FB7FCD67A6C566ED94CE09C44470",
    "CF13A243C1CD2E3C8CEB7E70100387CECBFB830525BBF9D0B70C79ADF3E84128",
    "DF02AAB48387A9E1D4C65228089CB6ABE196C8F4B396C7E4BBC395DE136977F6",
    "DF91AC85A94FCD0CFB8155BD7CBEFAAC14B8C5EE7397FE2CC85984459E2EA14E",
    "E36DFC719D2114C2E39AEA88849E2845AB326F6F7FE74E0E539B7E54D81F3631",
    "E24B315A551671483D8B9073B32DE11B4DE1EB2EAB211AFD2D9C319FF55E08D0",
    "B3E506340FBF6B5786973393079F24B66BA46507E35E911DB0362A2ACDE97049",
    "7BC9CB5463CE0F011FB5085EB8BA77D1ACD283C43F4A57603CC113F22CEBC579",
    "91971C1497BF8E5BC68439ACC48D63EBB8FAABFD764DCBE82F3BA977CAC8CF6A",
    "BC75F910FF320F5CB5999E66BBD4034F4AE537A42FDFEF35161C5348E366E216",
    "65F3C0A01B8402D362B9722E98F75E5E991E6C186E934F7B2B2E6BE6DEC800EC",
    "2679650FE341F2CF1EA883460B3556AAAF77A70D6B8DC484C9301D1B746CF7B5",
    "E7C20B3AB481EC885501ECA5293781D84B5A1AC24F88266B5270E7ECB4AA2538",
    "47FF1B63B140B6FC04ED79131331E651DA5B2E2F170F5DAEF4153DC2FBC532B1",
    "894D7839368F3298CC915AE8742EF330D7A26699F459478CF22C2B6BB2850166",
    "1F16078CCE009DF62EDB9E7170E66CAAE670BCE71B8F92D38280C56AA372031D",
    "37A480374DAF6202CE790C318A2BB8AA3797311261160A8E30558B7DEA78C7A6",
    "408B8B3DF5ABB043521A493525023175AB1261B1DE21064D6BF247CE142153B9",
    "540801DD345DC1C33EF431B35BF4C0E68BD319B577B9ABE1A9CFF1CBC39F548F",
    "89F3D1F6E485C334CD059D0995E3CDFDC00571B1849854847A44DC5548E2DCFB",
    "9F1863ED5717C394B42EF10A6607B144A65BA11FB6579DF94B8EB2F0C4CD60C1",
    "BB1DD16D530008636F232303A7A86F3DFF969F848815C0574B12C2D787FEC93F",
    "02E6216ACAEF6401401FA555ECBED940B1A5F2569AED92956137AE58482EF1B7",
    "6EFEFE0B5B01478B7B944C10D3A8ACA2CCA4208888E2059F8A06CB5824D7BAB0",
    "0DC24C75EB1AEF56B9F13AB9DE60E2ECA1C4510034E290BBB36CF60A549B234C",
    "835881F2A5572D7059B5C8635018552892E945626F115FC9CA07ACF7BDE857A4",
    "3ECE27CBB3EC4438CCE523B927C4F05FDC5C593A3766DB984C5E437A3FF6A16B",
    "0C51D7906FC4931149765DA88682426B2CFE9E6AA4F27253EAB400111432E3A7",
    "631F0857B41845362C90C6980B4B10C4B628E23DBE24B6E96C128AE3DCB0D5AC",
    "947078F97C6196968C3AE99C9A5D58667E86882CF6C8C9D58967A496BB7AF43C",
    "A924D3CAD6DA42B7399B96A095A06F18F6B1ABA5B873B0D5F3A0EE2173B48B6C",
    "95049F0E4137C790B0D2767195E56F73807D123ADCF8F6E7BF2D4D991D305F89",
    "06EB5BADD26E4FAE65F9A42358DEEF7C18E52CC05FBB7FC76776E69D1B982A14",
    "0928F0408BF725E61D67D87138A8EEBC52962D2847F16E3587163B160E41B6AD",
    "1D8B58C1FDB8DA8B33CCEE1E5F973AF734D90EF317E33F5DB1573C2BA088A80C",
    "270C84B29D86F16312B06AAAE4EBB8DFF8DE7D080D825B8839FF1766274EFF47",
    "311A2AC55B50C09B30B3CC93B994A119153EEEAC54EF892FC447BBBD96101AA1",
    "32AD3296829BC46DCFAC5EDDCB9DBF2C1EED5C11F83B2210CF9C6E60C798D4A7",
    "367A31E5838831AD2C074647886A6CDFF217E6B1BA910BFF85DC7A87AE9B5E98",
    "3AE76C45CA70E9180C1559981F42622DD251BCA1FBE6B901C52EC11673B03514",
    "3BE8E7EB348D35C1928F19C769846788991641D1F6CF09514CA10269934F7359",
    "3E3926F0B8A15AD5A14167BB647A843C3D4321E35DBC44DCE8C837417F2D28B0",
    "400AC66D59B7B094A9E30B01A6BD013AFF1D30570F83E7592F421DBE5FF4BA8F",
    "4667BF250CD7C1A06B8474C613CDB1DF648A7F58736FBF57D05D6F755DAB67F4",
    "57E6913AFACC5222BD76CDAF31F8ED88895464255374EF097A82D7F59AD39596",
    "65B2E7CC18D903C331DF1152DF73CA0DC932D29F17997481C56F3087B2DD3147",
    "788383A4C733BB87D2BF51673DC73E92DF15AB7D51DC715627AE77686D8D23BC",
    "7F49CCB309323B1C7AB11C93C955B8C744F0A2B75C311F495E18906070500027",
    "82ACBA48D5236CCFF7659AFC14594DEE902BD6082EF1A30A0B9B508628CF34F4",
    "8D93D60C691959651476E5DC464BE12A85FA5280B6F524D4A1C3FCC9D048CFAD",
    "9783B5EE4492E9E891C655F1F48035959DAD453C0E623AF0FE7BF2C0A57885E3",
    "97A8C5BA11D61FEFBB5D6A05DA4E15BA472DC4C6CD4972FC1A035DE321342FE4",
    "992820E6EC8C41DAAE4BD8AB48F58268E943A670D35CA5E2BDCD3E7C4C94A072",
    "9C259FCB301D5FC7397ED5759963E0EF6B36E42057FD73046E6BD08B149F751C",
    "9DD2DCB72F5E741627F2E9E03AB18503A3403CF6A904A479A4DB05D97E2250A9",
    "BDD01126E9D85710D3FE75AF1CC1702A29F081B4F6FDF6A2B2135C0297A9CEC5",
    "BE435DF7CD28AA2A7C8DB4FC8173475B77E5ABF392F76B7C76FA3F698CB71A9A",
    "C3505BF3EC10A51DACE417C76B8BD10939A065D1F34E75B8A3065EE31CC69B96",
    "CB340011AFEB0D74C4A588B36EBAA441961608E8D2FA80DCA8C13872C850796B",
    "CC8EEC6EB9212CBF897A5ACE7E8ABEECE1079F1A6DEF0A789591CB1547F1F084",
    "DA3560FD0C32B54C83D4F2FF869003D2089369ACF2C89608F8AFA7436BFA4655",
    "E39891F48BBCC593B8ED86CE82CE666FC1145B9FCBFD2B07BAD0A89BF4C7BFBF",
    "EE83A566496109A74F6AC6E410DF00BB29A290E0021516AE3B8A23288E7E2E72",
    "F31FD461C5E99510403FC97C1DA2D8A9CBE270597D32BADF8FD66B77495F8D94",
    "F48E6DD8718E953B60A24F2CBEA60A9521DEAE67DB25425B7D3ACE3C517DD9B7",
    "4B8668A5D465BCDD9000AA8DFCFF42044FCBD0AECE32FC7011A83E9160E89F09",
    "9D00AE4CD47A41C783DC48F342C076C2C16F3413F4D2DF50D181CA3BB5AD859D",
    "0A75EA0B1D70EAA4D3F374246DB54FC7B43E7F596A353309B9C36B4FD975725E",
    "96E4509450D380DAC362FF8E295589128A1F1CE55885D20D89C27BA2A9D00909",
    "A4D978B7C4BDA15435D508F8B9592EC2A5ADFB12EA7BAD146A35ECB53094642F",
    "386D695CDF2D4576E01BCACCF5E49E78DA51AF9955C0B8FA7606373B007994B3",
    "70A1450AF2AD395569AD0AFEB1D9C125324EE90AEC39C258880134D4892D51AB",
    "5C5805196A85E93789457017D4F9EB6828B97C41CB9BA6D3DC1FCC115F527A55",
    "66AA13A0EDC219384D9C425D3927E6ED4A5D1940C5E7CD4DAC88F5770103F2F1",
    "DCCC3CE1C00EE4B0B10487D372A0FA47F5C26F57A359BE7B27801E144EACBAC4",
    "E800395DBE0E045781E8005178B4BAF5A257F06E159121A67C595F6AE22506FD",
    "1CB4DCCAF2C812CFA7B4938E1371FE2B96910FE407216FD95428672D6C7E7316",
    "0257FF710F2A16E489B37493C07604A7CDA96129D8A8FD68D2B6AF633904315D",
    "495300790E6C9BF2510DABA59DB3D57E9D2B85D7D7640434EC75BAA3851C74E5",
    "8E53EFDC15F852CEE5A6E92931BC42E6163CD30FF649CCA7E87252C3A459960B",
    "992D359AA7A5F789D268B94C11B9485A6B1CE64362B0EDB4441CCC187C39647B",
    "03F64A29948A88BEFFDB035E0B09A7370CCF0CD9CE6BCF8E640C2107318FAB87",
    "05D87E15713454616F5B0ED7849AB5C1712AB84F02349478EC2A38F970C01489",
    "08BB2289E9E91B4D20FF3F1562516AB07E979B2C6CEFE2AB70C6DFC1199F8DA5",
    "1F179186EFDF5EF2DE018245BA0EAE8134868601BA0D35FF3D9865C1537CED93",
    "362ED31D20B1E00392281231A96F0A0ACFDE02618953E695C9EF2EB0BAC37550",
    "41D1EEB177C0324E17DD6557F384E532DE0CF51A019A446B01EFB351BC259D77",
    "61CEC4A377BF5902C0FEAEE37034BF97D5BC6E0615E23A1CDFBAE6E3F5FB3CFD",
    "6873D2F61C29BD52E954EEFF5977AA8367439997811A62FF212C948133C68D97",
    "6DBBEAD23E8C860CF8B47F74FBFCA5204DE3E28B881313BB1D1ECCDC4747934E",
    "72C26F827CEB92989798961BC6AE748D141E05D3EBCFB65D9041B266C920BE82",
    "9063F5FBC5E57AB6DE6C9488146020E172B176D5AB57D4C89F0F600E17FE2DE2",
    "91656AA4EF493B3824A0B7263248E4E2D657A5C8488D880CB65B01730932FB53",
    "97A51A094444620DF38CD8C6512CAC909A75FD437AE1E4D22929807661238127",
    "9BAF4F76D76BF5D6A897BFBD5F429BA14D04E08B48C3EE8D76930A828FFF3891",
    "9ED33F0FBC180BC032F8909CA2C4AB3418EDC33A45A50D2521A3B5876AA3EA2C",
    "B8D6B5E7857B45830E017C7BE3D856ADEB97C7290EB0665A3D473A4BEB51DCF3",
    "BB01DA0333BB639C7E1C806DB0561DC98A5316F22FEF1090FB8D0BE46DAE499A",
    "C2469759C1947E14F4B65F72A9F5B3AF8B6F6E727B68BB0D91385CBF42176A8A",
    "C42D11C70CCF5E8CF3FB91FDF21D884021AD836CA68ADF2CBB7995C10BF588D4",
    "C69D64A5B839E41BA16742527E17056A18CE3C276FD26E34901A1BC7D0E32219",
    "D9668AB52785086786C134B5E4BDDBF72452813B6973229AB92AA1A54D201BF5",
    "040B3BC339E9B6F9ACD828B88F3482A5C3F64E67E5A714BA1DA8A70453B34AF6",
    "1142A0CC7C9004DFF64C5948484D6A7EC3514E176F5CA6BDEED7A093940B93CC",
    "288878F12E8B9C6CCBF601C73D5F4E985CAC0FF3FCB0C24E4414912B3EB91F15",
    "2EA4CB6A1F1EB1D3DCE82D54FDE26DED243BA3E18DE7C6D211902A594FE56788",
    "40D6CAE02973789080CF4C3A9AD11B5A0A4D8BBA4438AB96E276CC784454DEE7",
    "4F0214FCE4FA8897D0C80A46D6DAB4124726D136FC2492EFD01BFEDFA3887A9C",
    "5C2AFE34BD8A7AEBBB439C251DFB6A424F00E535AC4DF61EC19745B6F10E893A",
    "99D7ADA0D67E5233108DBD76702F4B168087CFC4EC65494D6CA8ABA858FEBADA",
    "A608A87F51BDF7532B4B80FA95EADFDF1BF8B0CBB58A7D3939C9F11C12E71C85",
    "BDD4086C019F5D388453C6D93475D39A576572BAFF75612C321B46A35A5329B1",
    "CB994B400590B66CBF55FC663555CAF0D4F1CE267464D0452C2361E05EE1CD50",
    "D6EE8DB782E36CAFFB4D9F8207900487DE930AABCC1D196FA455FBFD6F37273D",
    "DDA0121DCF167DB1E2622D10F454701837AC6AF304A03EC06B3027904988C56B",
    "E42572AFAC720F5D4A1C7AAAF802F094DACEB682F4E92783B2BB3FA00862AF7F",
    "E6236DC1EE074C077C7A1C9B3965947430847BE125F7AEB71D91A128133AEA7F",
    "EF87BE89A413657DE8721498552CF9E0F3C1F71BC62DFA63B9F25BBC66E86494",
    "F5E892DD6EC4C2DEFA4A495C09219B621379B64DA3D1B2E34ADF4B5F1102BD39",
    "D4241190CD5A369D8C344C660E24F3027FB8E7064FAB33770E93FA765FFB152E",
    "23142E14424FB3FF4EFC75D00B63867727841ABA5005149070EE2417DF8AB799",
    "91721AA76266B5BB2F8009F1188510A36E54AFD56E967387EA7D0B114D782089",
    "DC8AFF7FAA9D1A00A3E32EEFBF899B3059CBB313A48B82FA9C8D931FD58FB69D",
    "9959ED4E05E548B59F219308A45563EA85BB224C1AD96DEC0E96C0E71FFCCD81",
    "47B31A1C7867644B2EE8093B2D5FBE21E21F77C1617A2C08812F57ACE0850E9F",
    "FABC379DF395E6F52472B44FA5082F9F0E0DA480F05198C66814B7055B03F446",
    "E37FF3FC0EFF20BFC1C060A4BF56885E1EFD55A8E9CE3C5F4869444CACFFAD0B",
    "4CDAE3920A512C9C052A8B4ABA9096969B0A0197B614031E4C64A5D898CB09B9",
    "5B89F1AA2435A03D18D9B203D17FB4FBA4F8F5076CF1F9B8D6D9B826222235C1",
    "007F4C95125713B112093E21663E2D23E3C1AE9CE4B5DE0D58A297332336A2D8",
    "E060DA09561AE00DCFB1769D6E8E846868A1E99A54B14AA5D0689F2840CEC6DF",
    "48F4584DE1C5EC650C25E6C623635CE101BD82617FC400D4150F0AEE2355B4CA",
    "AF79B14064601BC0987D4747AF1E914A228C05D622CEDA03B7A4F67014FEE767",
    "C55BE4A2A6AC574A9D46F1E1C54CAC29D29DCD7B9040389E7157BB32C4591C4C",
    "E9D873CBCEDE3634E0A4B3644B51E1C8A0A048272992C738513EBC96CD3E3360",
    "66D0803E2550D9E790829AE1B5F81547CC9BFBE69B51817068ECB5DABB7A89FC",
    "284153E7D04A9F187E5C3DBFE17B2672AD2FBDD119F27BEC789417B7919853EC",
    "EDD2CB55726E10ABEDEC9DE8CA5DED289AD793AB3B6919D163C875FEC1209CD5",
    "90AEC5C4995674A849C1D1384463F3B02B5AA625A5C320FC4FE7D9BB58A62398",
    "CA65A9B2915D9A055A407BC0698936349A04E3DB691E178419FBA701AAD8DE55",
    "1788D84AA61EDE6F2E96CFC900AD1CAB1C5BE86537F27212E8C291D6ADE3B1E9",
    "6A0E824654B7479152058CF738A378E629483874B6DBD67E0D8C3327B2FCAC64",
    "1EAED62C4ABCB2524643E1723F6AADCC31A74AF4D2285D3B13880CC44C22DEC5",
    "21F27D89F2E77DEE7CD4336E3A3ADE362A2AAE9FB2EFE2079491A518F3D51FED",
    "250AE0BA860D6D46894491D630D58B1CA008F695C92CE2084A295486F71F985B",
    "399F9DA6CF5A87839637B55F62BB2CC6A93FA5AF7FE7AD76B4AF0FB320C98127",
    "3B30C3E6A923CBB7CF65B539025F12B1C810D74480F25CBFCB9A7BFD633F06ED",
    "3FE9F8D11EDCA3FC1899100484DE4CC2C626ABB38B73985A441B7C3A0D39CA54",
    "459457C48E1B450D8F22858FFB392FCA78BB6F4DA837862889AB798BDCBDF08F",
    "5A184E740657E218D635168286F0F70BB5672E4EDB78717550C70686C232EA5B",
    "5E2BB7BC8B16E0B9DDFF75606668E69D76AF1219C17180EF0A5B9B383F00B995",
    "7FDDFE06C44DC4302DA54577353C18FDBE11B41CB3E6064EC1C116EE102FE080",
    "9141EA1A4E6BF1F4D72C28A1D0D124A928D5A7D36B14FC7E7E53EF442360FF99",
    "93F5233E9970A7DB1E4C9AA2DE2404636728E7C66C03F2BBE74B18B20A93BA96",
    "AE1DCA8AAB7C4BDD21C5AA19A323F597BD1850445D76695CB2910CCCB5F163B8",
    "BFCAA41445F20B54AEA650D03D7C39B77CD82A7A14824DC55AA587C4C0F742A3",
    "C3297E35C3A9EFC4C051706AAB77D29A26E62D9A38DE256DFFEB77A0EEC8666A",
    "C875AE8A8DB5441A577172869A4EC6E71DACE7A875F42A2FBBA4B52F293499DE",
    "DB1E5C6152A28D3EB6B1AFEAAD4974F3654AC6FBBE769D870ABB74EDE632B9E5",
    "DBB424CB8AD35EE68546092645C4689D6027A97FEDF3C5AF842B9572F1276997",
    "E11BDBFBAC4736918C497798D6ED018F529726A6B1894BE0658D1B9519538B22",
    "E637002526221BC32E477455B12F864F20B27C44679A2E78E5C56DA1FFCE8B41",
    "F4D8EAD6C325030538D10EBB39F0EFDC2F553794C14A5E45F9555C335925D9D3",
    "F51BC0B8FCE1BAE71B76CB3ADE28B712669D4E938FD37C9F5872493ACC25FAE1",
    "FD4591ADD2E5B0664363720C71492982D5B223A141A6248246CD2381F67E926C",
    "1364B7B94AB2A93E79D297EBF6CE0A30F7997E5929E408EF0D3B5D54C64E7B90",
    "1510988D3DCCE120F22696A9E87B02E7FAD6367EF4AE8BFD54CDB528A5C48E99",
    "3860B7C7FF6F4BCD5865843B2E86B2ECA5FF4FB071999F2129D4C7753B806F34",
    "47F7A5F3821286A9C677F66CFE2A84D5CA94CB6FC1EBE8E1986E91EDD58CBE33",
    "52A3CA4DB923C0648AC04BE86CE02DBC6A3AAAC8312366B106205DEC6E2CA2D9",
    "57692FC2B80D809A3BE409B44475DDED7225C76FDD5FF09E4ED7D330A58733A5",
    "7836465BDFFAE768EFAEDCBAA8B5787BAF51B2792A020E80E341A3F824FF82CA",
    "7A0294BA07A2AEE3648AFC0DAF2EFD526A5B76349EC906F819C03BC217257638",
    "85255700890931C5B71A73DFF09EA5125CD702EA65F45B4054C1463E00173FDC",
    "8D5332B350577AB7B1987F93FDA104B2090F6A62E262214264F554B6163E8050",
    "8ED8AA03199DE7D541CCBB3009A2B1FF575219662D8B23FBA7FDFF02D80ABD29",
    "9335C9DD7001A2EC4E322AB6A2D11E6C4CD4EF1644C00D6314B7BA5A26F9EB7D",
    "9AF92541E63EACBC5784BB44DB66F9B60726174F4EC178C6CE32EAF647EEBCA2",
    "A4B3FEE324D25C53FB5CB48630DC80DD7EE78C1AAC8C8DEEA927396997E33BCE",
    "A983E73E57BDF014C9A29331290EE87DF37F97C81DBCC43C6C933FE2209C0BD5",
    "B420509D0D69B294633FD7AE2C36B2B549D45A6A863EF16843A1116A11127F56",
    "CE8C44E185FAAA03959CF23229607854EF7E316ED0773D66D7BE5E0A48061DE5",
    "E808A337ED6911EF561C27CABACABF4EA6D6E20FB70F5413B121AC251ABCC10C",
    "E9C71B7CD5A4DF0BA48D2CA48E6C468E657257F73F66017DE45E18EE746ED7D5",
    "FD3062358E0E1DC4C3A60380EF1BDFD4C51F4473B8600937D921DF472FBF9B65",
    "65625A143D220EA184DBD5CDFB1B9E9C3BD9654294EAA2B98628BC273EBC18B5",
    "800423CEB7E4759621A62C729BABC81F53259D95F76457224AD601542B7B26D4",
    "0328F7DD12B552EFA7A9E083730333B85F3F4E83D39387FC531863B422F75CC8",
    "03DF4500273C43189296F09D734977C882A008FC056F43C309B9D2351F31792E",
    "065D94B9EA00397A2ADDB747E1E0978E4DE6BF175339778FB9B0760FEC3D3B61",
    "09F7699631C18DB0C33491EB4B3C65B8F279238C5FC5E3AB0BA52737DBBD26F3",
    "0A3C2072EF4FBDBF045E1876E855BB8AD5DD0809F66AD1442239A7D856AD908E",
    "0A620707ACF23A4E6CDC357A1499E14852B605D9EB6186422F57D458E627D6C0",
    "16598EE39B716ED9E4765A44ABF86906C9B25C25ABF631CC78ECE6F7211B0365",
    "17C2B5B96693CDC2951C89DDE641D14716063F5FC8795CEBC635378B73044E8B",
    "19F4C7030AD74035F5BC07ACE285BD7538F231D25787755D72071EDE879C6978",
    "245E9B81342E45E1BAF4F8D830D18EA7FAE9FDFF05497290EA6442C4EF0FFA57",
    "3153B3E305575439914605D976CF6EAD5A500E54D0B6ABCDAAFCCED1BC47E04F",
    "36B7CDB6564C58CB54895B6D2C73F88D2908BCBD693BFD253945BD31E3EE81BC",
    "39ABED2935891EEF96E2B733BBC6951DAFAD1A4C6B500D2D9B28C358355A6AB8",
    "4A4873A319A3A3DE35EA325771DFFCBB31EC14550A4E029CF0FEB9CD686B8C92",
    "50871141459A21FABA3DBBF63DA5AAC8863FA3D8A9891F182ED72E3A74B64FDC",
    "54C7D9C28672A1306E43ED7FEED38B295F8EEC279251F996FA293F68FC6CFB12",
    "5EB2C76843B253ACBCECBB84767697128F000C18358C78C5BAF135A5996C037F",
    "6582DCCB8B305EFE0BBBAFDCC7D295A6A8BF1DF0397E1A8AC736E9098A2A64C0",
    "6730C911E6D91009420D202FB6F394568A06AA97E9F33F30C7E92AAA71332D68",
    "6F53CD5BF434B19B4E14CA127C596752079D989FCC98BB7D7CF3155619EC347D",
    "71B601EE3746DA7177726DB84F5B417C9721583D2D88AD857BF368A54FF76BFA",
    "77CDCFC9644F8F80FF407CDE316AC235DDD1ADA9C3B6A5AA9544DB2D64B79FED",
    "7C09D8B90B72B7C2CCF1A413E335C2D1A25D75BB8541F9BC16B4C4E26BDA6855",
    "7F964730CFB7B8CEA284E2E810212FF9B0EE18227F64427A095D6886493DB0C4",
    "84D75F7A8913D66DB946EAF1480EADDEC3063D27A6F625F040B406718ABCAC44",
    "87176A15E766BD06528ED91A61481C3B3CDE65EE95115403F9FFC6D3A26D43D0",
    "8CB4FDAE88F4F492AC6C87716602366DF1AC84224B85AB2D3949F5AEE79CEFEB",
    "90A483526B4238C55BC5DED289D7C1D376109B9D5F3E93529EDA75C4D451523A",
    "915009D1CF9D68B9E53064DE82D4B70B58D2F014A03805CC406427D323D9FC35",
    "A0107A564E93989C57044FD18AA85BEB1258101AC3D9F6E10BF12C1C6573BC2B",
    "A330FDE65C067A5F0B75C80D0A300767C301EB75E0CF9B4EE240F0D60B3DC503",
    "B149B29E8211E24827FBE0168D30CB2619CD3365BD6F8173E7A731C5F702DCD9",
    "B97915DA9F05277FA5687F8C41132DF69152517F2BA252D466395B40D4F2D155",
    "BB44FD8CD04ABC3B54E5CCEA97EF81E70FD3933C34288D8B86F6ECB4F3ED1FDE",
    "C1547CF902570207A9694B6B8E353FE41419DB6A3802221DDF10FB8F86947804",
    "CEF75D1DA8E991AC96D36F8A14562849207F9DD50FC63028BA83277D5C27D00B",
    "D5BC11FB619BFCED64249B930C785EAD5FCA3927F0CE3C5EFD3F1D9AF04B37BF",
    "DA9943277174960B0D7D3F0D656176F3723ED2F03A90518BEB3C6C202B88CC14",
    "EA9C72C1CE865E6044ABFF576FD712D4DF3F5114318753EFCFEFED70EE586884",
    "F1CAD3AC005B57D6E22EA57B9EBE1EE9E5052BDDA499F5F2C1364317DE87A794",
    "F74947590A87A005023E9EF89CDF0C38D8D582CA4173F8201CEBC443EF796790",
    "FB0BBC256AEA5CF93DA99CF26481CC42F4E7BA6B32DB63B827620807E79E805C",
    "0C0C78837FA767EB045B8199E1E20AD666F90928DAEEB8F5E5253D8E7877FCB4",
    "0E44212BADF40D6B8DE3311E632045370588E0B23B7A480EB5DC10DB65D1B4B3",
    "13DBA28447FDBE3C8A24FEE3EB88638CE1D8F97CD4925056C0AD0E91CA51237D",
    "1DA53F3A2C7C41C93099737266B5619FF616A433FB3B870234622D7AAFAB9A7A",
    "23FCD6BF3084CEE6A9F9885E5239230B0ADDE0C870589EE461551D1CA8F4E85B",
    "264CBC5765718A0BCCB0F79C0FDD133A898203FB6F4F2052CB0647FBF6000ED0",
    "266C1429C8DC389481B3814BC3AF8723DB28EECEB0BB026BBBEDA0CC41D36BC3",
    "2B1B9ECCF585B11C5122651D7B94534BB131AA7C874E2262038B85DB3EE83E4D",
    "326967C7FFC1B86DB8B32B0570E88A89CC1534CFCF300B98C077E473F9B18FA1",
    "332450890F9C8FFF7EC15C53921BF27227AB9EA06B0E1C816D819F8E21CFB55F",
    "3B7696DF627ADE30BB15BDC5CE3F3C27240C973353E8551E7B036C90D01280C9",
    "54061FF50D91296F2F44D8B338AEEDFBBE86DF49DB5DE8A45191AAA931F5BCF6",
    "586898C60CFF539B76D23DBF2C92E4105F6A7549E13F53D293708B793CA90D2D",
    "5A47B0B11D2FD9CD39C627D1E6BF4AFED9601AA15D6A5D84FB10F39755D2D323",
    "5E67BF240B1D05F6F618908868A494C50A30AB255B06619FA28411EB260F674A",
    "61535CAA144761FC48CC9D7A835DFAF020B569EDFC7FA628F983D58A3AC25F2A",
    "691BA3414E78622581BC519BAF0BCB16FB262D3ABBD8639F3E0ECA2A29F99406",
    "6CE1F2986F0C46683BA07D296D0A84448ECF76C69DB183FE29C36EED8F8E8F2F",
    "6CFDDB6203F254D38A5BCDD4173D51647A487CA70AB21326ACA0A03BB3D2BAC0",
    "736AFB5DF29EC9C88532BE9C620EF80901BF23E72F2D3488B757AFF17E734ACE",
    "74B39C206DC8A11CD196D5998D2996B6AD477D72EAF86E19A3DC14EC0EAB0F1E",
    "7C7372A60D71E04879B8930C164944D96D3753E0A2924A31231D1D5FB97882F2",
    "7F292BCE8DC97B601EF1EA72BDF7D96A12A87782BB1B1C547F85C55C7B3FF035",
    "812EB0FA2DF13A889549729CADBF1720B68F6C9E21955741B72802590AF1B5CA",
    "815D98AEE498CF27FD6648C7E02CFC0A4A88AA73237CBB2352FE38384A72683D",
    "8A305C5FBE7C56F9E3214D7ADB8F176341F4020F234F3C14E52335967A2D365F",
    "92185C264285741FA7F198CAD8F307C60891AD932D9E3C2A08D92546FF7099ED",
    "92F858F6A02BD2014618B05D7759E34E7781B15C34C8814BA4C930B320F8DB09",
    "9414F5FA5853978C07FC6BB17A1CA9460FE443FFCA021FA52C8672A94460F44F",
    "9EBDA9554AD5BB9E3D5CE700F7C86D4F5B0D782BF1DBF30A6A7234749A5DD517",
    "AD16DE1E2BA27196395124683B80EFC186EE7E51D434F8FF67D973F46E8E602F",
    "B4938ED2FF001B73EF31E5BBBEBE1D6DBB7D9888A9FBE5251A52A5ED016652CF",
    "B67DB8D53C925FEBADAFCE4356206C85F73E22456EAE4ED6EE77F6A9E11A078C",
    "C470161A06E6B452253A623536924979CDD11838E08D8E4DC86F763732E64B0B",
    "CC7396D1C306ADFCE49E70D7DAF32D093A8F2FEBE2AC0576BA853770E11B3EF2",
    "CE1AF9FCCE6AD19C00D8236B23B03CF83C593C6184A08266E58FE95C6CAA4D13",
    "D417C004525C7BB57523836278CEE120FD66147983BA738AAC011E24BE75E6E2",
    "E2CF881CF07195454505047D74810ED79AE20DFD0F1593AFBBF08270A486C038",
    "E7D9BDBCC68B5BED590C29B72DCA2B96779B8B68B12A47DED074B8F1B32F8FBE",
    "F197A171A09AB640AA8AC4FF7DDFC88377A89FDBB3FEE014ABB9097D92575B67",
    "FFD7688E7D2B8C3C3140B415E728BBE7663C54E23BD288FF2CF4617835088F39",
    "450EFFC827CA535A79D5C4FF3E1A3F614CA9126B3792F997D38791CA7399320C",
    "8EDE7732284DAB4AA384606CA07BE29E72FDED094597261A2F6473494A8ACA0A",
    "CF7F9E7D091023A1A1C3F5CBF7DDACF7B18F03A4D07961F71506FE9DF4388EEE",
    "2B21029FA033526D1DCD9E87AD8893F9B5A08987C3271B8A86716865DE53D958",
    "13A1F37BEDFB5417B6B737E2A3816C8FD587D74D836914B2B2EDC9FD6CA30E58",
    "ABEE522892FA10B22208B4D1540184617BC9875C9E03E5353B4FF476577D918B",
    "F254087746FDB5D9D9EAE6DF458485752BEB0FCF295C36D273511B45F7480287",
    "996C1D55955DFB3698869BDC2A700E6BCC762468716B5CBDA7295CF98841220A",
    "6B54497FF9915A6977428BDF8F45B116D874C4F8A836B5BDFC373D05F4C0EF87",
    "6D174DC1673F7CFB6F1EA75D71739AFDE2B784E214E41AE6F5AA30F622A400C4",
    "CB95A4D2E0E02A5B56D059C9F223C2326753EA8C44D2E3FA6C4486629BE387A9",
    "DC7CC8D1DC11E304ABDF6E6227838F35B223B780F030DE7B341E88A3F6A361B4",
    "8806CF0C7BD5DF7E01D120F56734113BE916E183755577BD48026C25DB268680",
    "CE65C29521CD8498FAD962E5F70D55C5044366EC09C761A60CC7C4A2001776A4",
    "2992068E4F616F2D7253E9D58116A97F22923F4DC1B78A58BE4499B982ECF270",
    "D87817F76309B1E420547808CB573AEA0C8E7DE14123793A42388582184286B7",
    "CC202E8F2753EC75C9EEAAC65C9D39EEA6FAED570664E930E3815976CD332D91",
    "7B94F0505F37B19B432ABA08BE2E3E003038C02CEB531E169D460DB60C351649",
    "CFD2A8F23BBCE7424F4A6E27DEF368F17B086FFA226528900FA092736E705EF9",
    "F0B3D0D4C5457880E2D9B7728EB64BD288B5D4A26EC883F3C0941D8AF29D9466",
    "E8818666B7E014B6E4820AFAA84D5A84FA42CB5D2663C848D358B2913274BA21",
    "21554D1F3BF9F52D3CD297D27DF56215C0FD08A0BF673868F3D8C6C064DC5609",
    "F8F38C4FEBE9D8E45E71A459C5BFF171755C348D5F619F3C6EF30A3F8FD02BD1",
    "BB4919D8F38DBA90154F963C47BE83B665076C6EB4B230B3CEE91E4B7706CC12",
    "15DD2FF6416858790A5241C335F675540750F611110A5D2D67B4517D08260AF9",
    "B1BC5EF4F5C7E8F683601217650F42E7D69EFC0098C22A4989C7990B7771C277",
    "39E7DA89CA9899B8CA2CB826D7FD910E525AC9E6784D54D8316E00650156A341",
    "20082B6101F8D7DADE206F4FDEB367622C11F809C4CF2D215D834460179EF2DD",
    "1E73F9DCF231163C9B99C9632B0C379B94209B068EDA8945951F125EDD6ACC9F",
    "08D13A5AB1795D47A3830FB3E34437882514E0FFC9BCEE122227C354D29FFD1D",
    "9E531D100AC08C28833FAD3CA5D3B863BD1323D2F118F83D9DB2B21407CA9E64",
    "73782E2981C4EED10CA0170DD06B2ADF54B1B6E95112FC60DB610C1039E3931A",
    "4561A888723EF5D879B44B02144125C9566D4FC7C674EE5A6E3246E6457F3DF9",
    "DB34CFA2F5239656EFEB51537A7EACB98AEC10ED2B40209C0F50DCD3DF6B50CD",
    "0690EADBD2302957BF7912C2851C33463C855C10AD226A11BBFDC8D69D8A14B3",
    "FA0D9315715290276F4558DAC2368BD828789F42214F5707A932E5C518E59F80",
    "9B4BF870DCB0610A34E441D32669DCCE2ABE5E697C67B7C4328A891397F4DB0C",
    "F41DA7DEB9A214E653F738BBF4DC9168C606E71E8095E7D50215B0DCC2CF71A3",
    "48BEFA8CAB6DBE7493EDE483396BB41BA9D46594606174B7FBCA3C0D17E2B6AA",
    "6CCA75EA065B35B9AAC96999DC3A4254CDE518139169C4BD160797F8E63E29ED",
    "109C91802D4EECA88BF607CBFA6A67449CC63F6E6E9BD0BE6B20EED263420C04",
    "E261C78511A77E74801F273919B0852BF44A31BC0600D188C535D88BE7ABA052",
    "D12924557C7E2714A9C77F64D6CD391FDD6509FC138CCDE16512EF226D15FA7F",
    "6C611BD22926D8778F0A6B0A095A839D6BBC40D5AD23F55B9F8560647361FFC7",
    "080A627E31BDC90041AD30B5604DE9EAE8C85ABDB621B5B55D25CD13ED182D06",
    "8A6E68D85AB00FD79783BFB955CF989BD1938F02DC57E371FB07EB1FAAF55901",
    "28412FA02802A3939A709F518798404582FF601E67EA9C542C78963F2EAE18FF",
    "EE606FA2CD686DB7554C99C4BB37D87E64F89153EF26B4CFF41834DA74EB4C1C",
    "136089AB3A7DC68C19F139558F0644DC57D32E9CEB79D6E54D9D6492AD2DE614",
    "F5A5415ACA106C63AA6595D58861F8D7E87143BA9C742E2E2819E3411D685496",
    "DECF57D609F02AB417FE4DA0D96EE4388181A3C6593083AE57C5DF05F5F918F3",
    "1E91FC3FEE40BB2B6077F7E9A31F26C2E887CE91B41E5268EE795BE53F11329B",
    "FF6ACFBD5962499FB8846DAF87B88320C115D7711EA645BA6742E8598E884BD8",
    "8C1EDB6A3F46D13CC6E58F6D2C7EFD958EC079AA029478BABA9AA9F53DB9F0E3",
    "5E41B89F7F471806E1917EFDD040953CC22F3F362E7B71423FF70E55B98ADB13",
    "8CE986614E7037218A61DB51B876341898817741ADE85156CF54BD1CD17999A6",
    "D9247336AC0D12CABF04DFD88227D1E640C0DC59739BD5B3CA17DF90B3331C3B",
    "ECB789C173E1FA4E604FF45A57A45B2868D8ACB1CE616D8AEEF08D5E252CCD6F",
    "4AA5F09F5022EEFBEE350D0DED72654D21A9E77DEEC49FEFB45994708BE11703",
    "ACD9B08302C0FA9C87D14920BEEE724B92144774DC095A22EE5D8F023E80D677",
    "7AC0BD56947B20B82303E2F47D4876540989872EC39D08DAF5635240B5EE7E9F",
    "2D59C29B059FE54A4F218BE5B1F37723BE29BA47CCDDF07FDEE604ECC57B3F62",
    "E427068FBA7A44C96515C47E9871798284A06397D4C8687DFDAFD0738026DDBB",
    "CDB7C90D3AB8833D5324F5D8516D41FA990B9CA721FE643FFFAEF9057D9F9E48",
    "363384D14D1F2E0B7815626484C459AD57A318EF4396266048D058C5A19BBF76",
    "E6CA68E94146629AF03F69C2F86E6BEF62F930B37C6FBCC878B78DF98C0334E5",
    "075EEA060589548BA060B2FEED10DA3C20C7FE9B17CD026B94E8A683B8115238",
    "07E6C6A858646FB1EFC67903FE28B116011F2367FE92E6BE2B36999EFF39D09E",
    "09DF5F4E511208EC78B96D12D08125FDB603868DE39F6F72927852599B659C26",
    "0BBB4392DAAC7AB89B30A4AC657531B97BFAAB04F90B0DAFE5F9B6EB90A06374",
    "0C189339762DF336AB3DD006A463DF715A39CFB0F492465C600E6C6BD7BD898C",
    "0D0DBECA6F29ECA06F331A7D72E4884B12097FB348983A2A14A0D73F4F10140F",
    "0DC9F3FB99962148C3CA833632758D3ED4FC8D0B0007B95B31E6528F2ACD5BFC",
    "18333429FF0562ED9F97033E1148DCEEE52DBE2E496D5410B5CFD6C864D2D10F",
    "2BBF2CA7B8F1D91F27EE52B6FB2A5DD049B85A2B9B529C5D6662068104B055F8",
    "2C73D93325BA6DCBE589D4A4C63C5B935559EF92FBF050ED50C4E2085206F17D",
    "306628FA5477305728BA4A467DE7D0387A54F569D3769FCE5E75EC89D28D1593",
    "3608EDBAF5AD0F41A414A1777ABF2FAF5E670334675EC3995E6935829E0CAAD2",
    "3841D221368D1583D75C0A02E62160394D6C4E0A6760B6F607B90362BC855B02",
    "4397DACA839E7F63077CB50C92DF43BC2D2FB2A8F59F26FC7A0E4BD4D9751692",
    "518831FE7382B514D03E15C621228B8AB65479BD0CBFA3C5C1D0F48D9C306135",
    "5AE949EA8855EB93E439DBC65BDA2E42852C2FDF6789FA146736E3C3410F2B5C",
    "6B1D138078E4418AA68DEB7BB35E066092CF479EEB8CE4CD12E7D072CCB42F66",
    "6C8854478DD559E29351B826C06CB8BFEF2B94AD3538358772D193F82ED1CA11",
    "6F1428FF71C9DB0ED5AF1F2E7BBFCBAB647CC265DDF5B293CDB626F50A3A785E",
    "726B3EB654046A30F3F83D9B96CE03F670E9A806D1708A0371E62DC49D2C23C1",
    "72E0BD1867CF5D9D56AB158ADF3BDDBC82BF32A8D8AA1D8C5E2F6DF29428D6D8",
    "7827AF99362CFAF0717DADE4B1BFE0438AD171C15ADDC248B75BF8CAA44BB2C5",
    "81A8B965BB84D3876B9429A95481CC955318CFAA1412D808C8A33BFD33FFF0E4",
    "895A9785F617CA1D7ED44FC1A1470B71F3F1223862D9FF9DCC3AE2DF92163DAF",
    "8BF434B49E00CCF71502A2CD900865CB01EC3B3DA03C35BE505FDF7BD563F521",
    "9998D363C491BE16BD74BA10B94D9291001611736FDCA643A36664BC0F315A42",
    "9E4A69173161682E55FDE8FEF560EB88EC1FFEDCAF04001F66C0CAF707B2B734",
    "A6B5151F3655D3A2AF0D472759796BE4A4200E5495A7D869754C4848857408A7",
    "A7F32F508D4EB0FEAD9A087EF94ED1BA0AEC5DE6F7EF6FF0A62B93BEDF5D458D",
    "AD6826E1946D26D3EAF3685C88D97D85DE3B4DCB3D0EE2AE81C70560D13C5720",
    "AFE2030AFB7D2CDA13F9FA333A02E34F6751AFEC11B010DBCD441FDF4C4002B3",
    "B54F1EE636631FAD68058D3B0937031AC1B90CCB17062A391CCA68AFDBE40D55",
    "B8F078D983A24AC433216393883514CD932C33AF18E7DD70884C8235F4275736",
    "B97A0889059C035FF1D54B6DB53B11B9766668D9F955247C028B2837D7A04CD9",
    "BC87A668E81966489CB508EE805183C19E6ACD24CF17799CA062D2E384DA0EA7",
    "CB6B858B40D3A098765815B592C1514A49604FAFD60819DA88D7A76E9778FEF7",
    "CE3BFABE59D67CE8AC8DFD4A16F7C43EF9C224513FBC655957D735FA29F540CE",
    "D8CBEB9735F5672B367E4F96CDC74969615D17074AE96C724D42CE0216F8F3FA",
    "E92C22EB3B5642D65C1EC2CAF247D2594738EEBB7FB3841A44956F59E2B0D1FA",
    "FDDD6E3D29EA84C7743DAD4A1BDBC700B5FEC1B391F932409086ACC71DD6DBD8",
    "FE63A84F782CC9D3FCF2CCF9FC11FBD03760878758D26285ED12669BDC6E6D01",
    "FECFB232D12E994B6D485D2C7167728AA5525984AD5CA61E7516221F079A1436",
    "CA171D614A8D7E121C93948CD0FE55D39981F9D11AA96E03450A415227C2C65B",
    "55B99B0DE53DBCFE485AA9C737CF3FB616EF3D91FAB599AA7CAB19EDA763B5BA",
    "77DD190FA30D88FF5E3B011A0AE61E6209780C130B535ECB87E6F0888A0B6B2F",
    "C83CB13922AD99F560744675DD37CC94DCAD5A1FCBA6472FEE341171D939E884",
    "3B0287533E0CC3D0EC1AA823CBF0A941AAD8721579D1C499802DD1C3A636B8A9",
    "939AEEF4F5FA51E23340C3F2E49048CE8872526AFDF752C3A7F3A3F2BC9F6049",
    "C54A4060B3A76FA045B7B60EAEBC8389780376BA3EF1F63D417BA1B55BE3A093",
    "CBFA2A86144EB21D65A6B17245BAD4F73058436C7292BE56DC6EBAB29DA61606",
    "9D7E7174C281C6526B44C632BAA8C3320ADD0C77DC90778CC148938829F45E5E",
    "9B1F35052CFC5FB06DAB5E8F7B47F081DA28D722DB59ADE253B9E38AB5A19847",
    "E3C5E55E84371D3F2FBCA2241EF0711FF80876EBF71BAB07D8E6E45AAA8B45AF",
    "EE093913ABBD3D4CB85EA31375179A8B55A298353C03AFE5055AA4E8EBD10EC2",
    "B4E1880425F7857B741B921D04FD9276130927CF90A427C454B970E7A28EB88B",
    "CDA0B4A59390B36E1B654850428CBB5B4C7B5E4349E87ACDE97FB5437D64D9FC",
    "C87EFD057497F90321D62A69B311912BE8EF8A045FE9C5E6BD5C8C1A41D6B295",
    "9E19DD645235341A555DA6C065594543AE1E3918ECD37DF22DFEBE91E71C3A59",
    "63F67824FDA998798964FF33B87441857DA92F3A8EE3E04166EEC315E6600FD1",
    "0BC4F078388D41AB039F87AE84CF8D39302CCBDD70C4ADE02263EBFCE6DEF0F5",
    "E2AEC271B9596A461EB6D54D8B1785E4E4C615CFAD5F4504BCC0A329433A9747",
    "6B4328EBCBE46ED9118FF2D4472DE329D70BA83016DF7A6F50F8AF923883BC54",
    "E14C88DC48339C0555686849A4E3F8986D558E65C4FC863A1A4F1D40478BD47C",
    "D013BA511AEE89BA3285D1CAC0C9F4F21EF4810873C2EBBFFE7712BF0BE8CED3",
    "AE75F0D82BA3DF824FBFC69340CC3B4D66C598373B1AB54CDB6C8BFD83A6B961",
    "7B2A3F5C96F95BD8086CE54B0825E300F9C8F11FE3401BB631B3215C8DE9EB10",
    "EB86FA1386FE6E4533B8B938DCC1250616D2F1C14C15E2FCF80834A161018A0A",
    "FD23D6E57DE6F4E1F9D7118DA1C5F31A8AF6BE5E5D9E8170F9493447268D50C5",
    "A0DE9333442C1BF9349A460141AE5E80F911955C6506040FA3D021BF6C1AE3E4",
    "95B6D71FC0C0F8C5E1533A37AEF92CF6B0C961E2CC612A97117FA6759CE5FC06",
    "236A9CB0D71951C36398A32EB660CE2CD4A52CCFA7CF751CC6A35D9DE549E19B",
    "5E594C448760A3135B1A3A83E07A4F2E6FBE49414EF2C7CAB1CBA77F284FA63B",
    "8A964D5F8373948D20A1D4296FB92E545DAD4617A0C810F3B934B53D98AE8963",
    "410260B1B6F5AF5FBEEB9EA3220658435E876CB3247126EE907A437F312DB373",
    "96275DFD6282A522B011177EE049296952AC794832091F937FBBF92869028629",
    "86A9482509A434CA61EA4D12B6010A9013E5D3FBFF09B14799EBC87C124BCFF0",
    "2EA557C44B83C0AD6B71EFB7EDCC18B6337AD1C1D682155DD9451B051B62FF40"
)


# =========================================================================
# GUI FORM
# =========================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-TpmGuiFormMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $AttestationPass
    )

    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

    $exceptionHandler = {
        param($sender, $eventArgs)
    }
    [System.Windows.Forms.Application]::add_ThreadException($exceptionHandler)

    try {
        $ColorMap = @{
            "Cyan"       = [System.Drawing.Color]::Cyan
            "DarkRed"    = [System.Drawing.Color]::Crimson
            "DarkYellow" = [System.Drawing.Color]::Gold
            "Blue"       = [System.Drawing.Color]::DeepSkyBlue
            "Green"      = [System.Drawing.Color]::Lime
            "Red"        = [System.Drawing.Color]::OrangeRed
            "Yellow"     = [System.Drawing.Color]::Yellow
            "White"      = [System.Drawing.Color]::White
        }

        $bgColor       = [System.Drawing.ColorTranslator]::FromHtml("#F1F5F9")
        $cardBgColor   = [System.Drawing.Color]::White
        $textDark      = [System.Drawing.ColorTranslator]::FromHtml("#0F172A")
        $darkGreyBtn   = [System.Drawing.ColorTranslator]::FromHtml("#334155")
        $greenCloseBtn = [System.Drawing.ColorTranslator]::FromHtml("#16A34A")
		
        if ($AttestationPass -eq 1) {
            $statusText    = "PASSED"
            $statusBg      = [System.Drawing.ColorTranslator]::FromHtml("#DCFCE7")
            $statusFg      = [System.Drawing.ColorTranslator]::FromHtml("#166534")
        } elseif ($AttestationPass -eq 0) {
            $statusText    = "FAILED"
            $statusBg      = [System.Drawing.ColorTranslator]::FromHtml("#FEE2E2")
            $statusFg      = [System.Drawing.ColorTranslator]::FromHtml("#991B1B")
        } else {
            $statusText    = "UNKNOWN"
            $statusBg      = [System.Drawing.ColorTranslator]::FromHtml("#FEF3C7")
            $statusFg      = [System.Drawing.ColorTranslator]::FromHtml("#92400E")
        }

        $form = New-Object System.Windows.Forms.Form -Property @{
            Text            = "TPM Diagnostics Tool"
            Size            = New-Object System.Drawing.Size(620, 370)
            StartPosition   = "CenterScreen"
            FormBorderStyle = "FixedSingle"
            MaximizeBox     = $false
            MinimizeBox     = $true
            BackColor       = $bgColor
            TopMost         = $true
        }

        $pnlHeader = New-Object System.Windows.Forms.Panel -Property @{
            Location  = New-Object System.Drawing.Point(0, 0)
            Size      = New-Object System.Drawing.Size(620, 75)
            BackColor = $cardBgColor
        }

        $lblTitle = New-Object System.Windows.Forms.Label -Property @{
            Location  = New-Object System.Drawing.Point(24, 22)
            Size      = New-Object System.Drawing.Size(300, 32)
            Text      = "TPM Attestation Status"
            Font      = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
            ForeColor = $textDark
        }

        $lblStatus = New-Object System.Windows.Forms.Label -Property @{
            Location  = New-Object System.Drawing.Point(440, 18)
            Size      = New-Object System.Drawing.Size(130, 38)
            Text      = $statusText
            Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
            ForeColor = $statusFg
            BackColor = $statusBg
            TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        }

        $pnlHeader.Controls.Add($lblTitle)
        $pnlHeader.Controls.Add($lblStatus)
        $form.Controls.Add($pnlHeader)

        $checkmarkChar = [char]0x2713
        $lblNotice = New-Object System.Windows.Forms.Label -Property @{
            Location  = New-Object System.Drawing.Point(24, 88)
            Size      = New-Object System.Drawing.Size(560, 28)
            Text      = "$checkmarkChar Full report copied to clipboard. Ready to paste into support forums."
            Font      = New-Object System.Drawing.Font("Segoe UI", 11.5, [System.Drawing.FontStyle]::Bold)
            ForeColor = [System.Drawing.Color]::Black
        }
        $form.Controls.Add($lblNotice)

        $currentY = 126
        if ($global:EnableUploadFeature) {
            $btnUpload = New-Object System.Windows.Forms.Button -Property @{
                Location  = New-Object System.Drawing.Point(24, $currentY)
                Size      = New-Object System.Drawing.Size(550, 44)
                Text      = "Upload Diagnostic Data for Research"
                Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
                FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0D6EFD")
                ForeColor = [System.Drawing.Color]::White
                Cursor    = [System.Windows.Forms.Cursors]::Hand
            }
            $btnUpload.FlatAppearance.BorderSize = 0

            $btnUpload.Add_Click({
                try {
                    $msgResponse = [System.Windows.Forms.MessageBox]::Show(
                        "Can you launch/play Call of Duty without attestation errors?",
                        "Research Verification",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question
                    )

                    $doesCodWork = if ($msgResponse -eq [System.Windows.Forms.DialogResult]::Yes) { "true" } else { "false" }
                    $machineHash = Get-PC-ID
                    $formattedId = "{0}-{1}" -f $machineHash.Substring(0,3), $machineHash.Substring(3,4)

                    $btnUpload.Text      = "Code: $formattedId"
                    $btnUpload.BackColor = [System.Drawing.Color]::Transparent
                    $btnUpload.Enabled   = $false

                    $bufferText = ($global:ImageBuffer | ForEach-Object { $_.Text }) -join "`r`n"
                    $ms = New-Object System.IO.MemoryStream
                    $gzip = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
                    $writer = New-Object System.IO.StreamWriter($gzip, [System.Text.Encoding]::UTF8)
                    $writer.Write($bufferText)
                    $writer.Close()
                    $gzip.Close()
                    $compressedData = [Convert]::ToBase64String($ms.ToArray())
                    $ms.Close()

                    $body = @{
                        powershell_data = $compressedData
                        id              = $machineHash
                        doesCODwork     = $doesCodWork
                    }

                    $response = Invoke-RestMethod -Uri (Get-URL) -Method Post -Body $body -TimeoutSec 7 -ErrorAction SilentlyContinue
                } catch {}
            })
            $form.Controls.Add($btnUpload)
            $currentY += 54
        }

        $btnSaveImg = New-Object System.Windows.Forms.Button -Property @{
            Location  = New-Object System.Drawing.Point(24, $currentY)
            Size      = New-Object System.Drawing.Size(268, 42)
            Text      = "Save Report Image"
            Font      = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
            FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            BackColor = $darkGreyBtn
            ForeColor = [System.Drawing.Color]::White
        }
        $btnSaveImg.FlatAppearance.BorderSize = 0

        $btnSaveImg.Add_Click({
            try {
                $saveDialog = New-Object System.Windows.Forms.SaveFileDialog -Property @{
                    Filter   = "PNG Image|*.png|JPEG Image|*.jpg"
                    Title    = "Save Diagnostic Report"
                    FileName = "TPM_Attestation_Report.png"
                }

                if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $textFont    = New-Object System.Drawing.Font("Courier New", 12)
                    $bitmapWidth = 1100
                    $padding     = 20

                    $testBitmap   = New-Object System.Drawing.Bitmap(1, 1)
                    $testGraphics = [System.Drawing.Graphics]::FromImage($testBitmap)

                    $currentX = $padding
                    $currentY = $padding
                    $lineHeight = [Math]::Ceiling($testGraphics.MeasureString("X", $textFont).Height)

                    foreach ($item in $global:ImageBuffer) {
                        $lines = $item.Text -split "`r`n" -split "`n"
                        for ($i = 0; $i -lt $lines.Count; $i++) {
                            $lineText = $lines[$i]
                            $textSize = $testGraphics.MeasureString($lineText, $textFont)

                            if ($i -gt 0) {
                                $currentX = $padding
                                $currentY += $lineHeight
                            }

                            if ($i -eq ($lines.Count - 1) -and $item.NoNewLine) {
                                $currentX += $textSize.Width
                            } else {
                                $currentX = $padding
                                $currentY += $lineHeight
                            }
                        }
                    }
                    $bitmapHeight = $currentY + $padding

                    $testGraphics.Dispose()
                    $testBitmap.Dispose()

                    $bitmap   = New-Object System.Drawing.Bitmap($bitmapWidth, $bitmapHeight)
                    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

                    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                    $graphics.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.Clear([System.Drawing.Color]::Black)

                    $currentX = $padding
                    $currentY = $padding

                    foreach ($item in $global:ImageBuffer) {
                        $drawingColor = $ColorMap[$item.Color]
                        if ($null -eq $drawingColor) { $drawingColor = [System.Drawing.Color]::White }
                        $brush = New-Object System.Drawing.SolidBrush($drawingColor)

                        $lines = $item.Text -split "`r`n" -split "`n"
                        for ($i = 0; $i -lt $lines.Count; $i++) {
                            $lineText = $lines[$i]

                            if ($i -gt 0) {
                                $currentX = $padding
                                $currentY += $lineHeight
                            }

                            $graphics.DrawString($lineText, $textFont, $brush, $currentX, $currentY)
                            $textSize = $graphics.MeasureString($lineText, $textFont)

                            if ($i -eq ($lines.Count - 1) -and $item.NoNewLine) {
                                $currentX += ($textSize.Width - ($textFont.Size * 0.4))
                            } else {
                                $currentX = $padding
                                $currentY += $lineHeight
                            }
                        }
                        $brush.Dispose()
                    }

                    $graphics.Flush()

                    $extension = [System.IO.Path]::GetExtension($saveDialog.FileName).ToLower()
                    $imageFormat = [System.Drawing.Imaging.ImageFormat]::Png
                    if ($extension -eq ".jpg" -or $extension -eq ".jpeg") {
                        $imageFormat = [System.Drawing.Imaging.ImageFormat]::Jpeg
                    }

                    $bitmap.Save($saveDialog.FileName, $imageFormat)

                    $textFont.Dispose()
                    $graphics.Dispose()
                    $bitmap.Dispose()

                    $btnSaveImg.Visible = $false
                }
                $saveDialog.Dispose()
            } catch {}
        })
        $form.Controls.Add($btnSaveImg)

        $btnCloseClear = New-Object System.Windows.Forms.Button -Property @{
            Location  = New-Object System.Drawing.Point(306, $currentY)
            Size      = New-Object System.Drawing.Size(268, 42)
            Text      = "Clear Clipboard and Close"
            Font      = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
            FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            BackColor = $darkGreyBtn
            ForeColor = [System.Drawing.Color]::White
        }
        $btnCloseClear.FlatAppearance.BorderSize = 0

        $btnCloseClear.Add_Click({
            try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
            try { $form.Close() } catch {}
        })
        $form.Controls.Add($btnCloseClear)

        $currentY += 52

        $btnClose = New-Object System.Windows.Forms.Button -Property @{
            Location  = New-Object System.Drawing.Point(24, $currentY)
            Size      = New-Object System.Drawing.Size(550, 44)
            Text      = "Close"
            Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
            FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            BackColor = $greenCloseBtn
            ForeColor = [System.Drawing.Color]::White
            TabIndex  = 0
        }
        $btnClose.FlatAppearance.BorderSize = 0

        $btnClose.Add_Click({
            try { $form.Close() } catch {}
        })
        $form.Controls.Add($btnClose)

        $form.ShowDialog() | Out-Null
    }
    catch {
    }
    finally {
        [System.Windows.Forms.Application]::remove_ThreadException($exceptionHandler)
        if ($null -ne $form) { $form.Dispose() }
    }
}

# =========================================================================
# USER RECOMMENDATION PIPELINE
# =========================================================================

function Show-UserRecommendedSteps ($Data) {
    Log-Output "`n--- USER RECOMMENDED STEPS ---" 'Cyan'
    $hasIssues = $false

	function Has-Issue {
		Set-Variable -Name 'hasIssues' -Value $true -Scope 1
		Log-Output ""
	}

    if ($Data.CpuInfo.OldAMD) {
        Log-Output "[WARNING] Incompatible CPU detected" 'Yellow'

		if ($Data.CpuInfo.FakeOldAMD) {
			Log-Output "CPU is branded as 3rd gen, but is really a 2nd gen." 'Yellow'
		}

		Log-Output "-> Please manually confirm your CPU is not a 1st or 2nd gen Ryzen, as these CPUs do not support TPM Attestation." 'Yellow'
		Log-Output "-> FIX: You will need to upgrade your CPU to a Ryzen 4th gen or later." 'Yellow'
		Log-Output "-> (Most 3rd Gens work, but best to get 4th)" 'Yellow'
        Has-Issue
    }

	if ($Data.TpmInfo.AmdFixRequired) {
        if ($Data.BitLocker -and $Data.BitLocker.Passed -eq $false) {
            Log-Output "Your current AMD TPM firmware version requires an update. If you have done this, you may need to reset/clear the TPM keys. (press Windows Key + R, type 'tpm.msc', hit Enter, and click 'Clear TPM')" 'Yellow'
        } else {
            Log-Output "Your current AMD TPM firmware version requires an update, but you have bitlocker." 'Yellow'
        }
        Has-Issue
    }

    if (!$Data.SecureBoot.Passed) {
        Log-Output "SECURE BOOT is showing OFF: Check its on." 'Yellow'
        Has-Issue
    }

    if (!$Data.CsmInfo.Passed) {
        Log-Output "Your system is running in Legacy/CSM mode instead of modern UEFI mode." 'Yellow'
        Has-Issue
    }

    if (!$Data.BiosInfo.Passed) {
		if ($Data.CpuInfo.Socket -eq "AM4") {
			Log-Output "ALL AM4 systems need a BIOS update after ~August 2025. Check if there is a newer BIOS" 'Yellow'
		} else {
			Log-Output "Check if there is a newer BIOS" 'Yellow'
		}
        Has-Issue
    }

	if ($Data.IntelBiosInfo.IsIntel -and $Data.IntelBiosInfo.RequiresFirmwareUpdate) {
        Log-Output "Your Intel PTT Firmware version ($($Data.IntelBiosInfo.Version)) appears to be outdated. Update BIOS/Firmware" 'Yellow'
        Has-Issue
    }

	if (!$Data.CompatibilityFlags.Passed) {
        Log-Output "COD is intended to run without any compatibility or admin flags." 'Yellow'
        Has-Issue
    }

	if ($Data.doesThirdPartySecurityExist.Passed -and $Data.OverallPassResult -eq 1) {
        Log-Output "[WARNING] A third-party Antivirus was detected!" 'Yellow'
        Log-Output "-> WHY: Aggressive third-party security software can block CoD." 'Yellow'
		Log-Output "-> WHEN: If you have problems."
        Log-Output "-> HOW TO FIX: Whitelist CoD. [cod.exe, CODBrokerInstaller.exe, CODBrokerService.exe]" 'White'
        Has-Issue
    }

	if (!$Data.CodBroker.Passed) {
        Log-Output "[FIX REQUIRED] The COD Broker Service is broken" 'Red'
        Has-Issue
    }

	if ($Data.SecureBoot.Passed -and !$Data.SecureBootType.Passed) {
        Log-Output "WARNING] Secure Boot is active but stuck in 'Setup Mode'!" 'Yellow'
        Log-Output "-> [WHY: The motherboard hasn't loaded its default factory platform certificates, meaning Secure Boot isn't actively enforcing rules." 'Yellow'
        Log-Output "-> [HOW TO FIX: Enter your BIOS, navigate to Secure Boot, and look for an option to 'Install Default Factory Keys' or reset Key Management." 'White'
        Has-Issue
    }

	if ($Data.Pluton -and -not $Data.OverallPassResult -eq 1) {
        Log-Output "[WARNING] This PC uses a Pluton TPM (which often don't work). Some devices let you turn this off in the BIOS" 'Yellow'
		Log-Output "-> On selected MSI_BIOS->Advanced->AMD fTPM switch->Change 'AMD CPU HSP' to AMD CPU fTPM" 'Yellow'

		if ($Data.TestMSI.IsMSI){
			Log-Output "->https://www.msi.com/faq/faq-12386 Resolve the 'BIOS Firmware Update Required' Prompt When Running Call of Duty" 'Yellow'
		}
		Has-Issue
    }

	if ($Data.NameResolutionFailure) {
		Log-Output "Cannot connect to the cloud attestation server. Firewall or ISP may be blocking certreq" 'Red'
		Log-Output "-> Check you have internet" 'Red'
		Has-Issue
	}

	if (!$Data.MicrosoftCa.Passed) {
		Log-Output "[WARNING] Windows UEFI CA 2023 not found"  'Yellow'
		Log-Output "-> COD MAY need this updated. However, irrespective of COD, its best practice to have this."
		Has-Issue
	}

    if ($Data.CpuInfo.Socket -eq "AM5" -and $Data.OverallPassResult -eq 0 -and -not (Is-NextGenTPM -Data $Data) ) {
		Log-Output "Potential TPM 'state mismatch'." 'Yellow'
		BIOS_TPM_ResetMessage
        Has-Issue
    }

	if (($Data.CpuInfo.Socket -eq 'AM4') -and (-not $Data.TpmInfo.AmdFixRequired) -and($global:HasPCRFailures) ) {
		Log-Output "PCR MISMATCH'." 'Yellow'
		Log-Output "-> TRY: MSI AM4 BIOS. Settings → Advanced → Windows OS Configuration → Secure Boot."
		Log-Output "-> Change:Secure Boot Security Mode From: Standard To: Custom > Maximum Security"
		Has-Issue
	}

    if (!$hasIssues) {
        Log-Output "NA" 'Green'
    }
}

# =========================================================================
# UI RENDERING PIPELINE
# =========================================================================

function Show-Banner {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $OverallPassResult,

        [switch]$ConsoleOnly
    )

	$LogCmd = if ($ConsoleOnly) {
        { Write-Host $args[0] -ForegroundColor $args[1] }
    } else {
        { Log-Output -Text $args[0] -Color $args[1] }
    }

    if ($OverallPassResult -eq 1) {
        $statusText = "PASS"
        $color      = "Green"
        $padding    = " " * 17
    } elseif ($OverallPassResult -eq 0) {
        $statusText = "FAIL"
        $color      = "Red"
        $padding    = " " * 17
    } else{
        $statusText = "UNKNOWN"
        $color      = "Yellow"
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

    } elseif ($result -eq 'FAIL') {
        $ascii = @'
  _____ _   ___ _     
 |  ___/ \ |_ _| |    
 | |_ / _ \ | || |    
 |  _/ ___ \| || |___ 
 |_|/_/   \_\___|_____|
'@
        Write-Host $ascii -ForegroundColor Red

	} elseif ($result -eq 'UNKNOWN') {
		$ascii = @'
 _   _ _   _ _  ___   _  _____        _   _ 
| | | | \ | | |/ / \ | |/ _ \ \      / / | \ | |
| | | |  \| | ' /|  \| | | | \ \ /\ / /  |  \| |
| |_| | |\  | . \| |\  | |_| |\ V  V /   | |\  |
 \___/|_| \_|_|\_\_| \_|\___/  \_/\_/    |_| \_|
'@

		Write-Host $ascii -ForegroundColor Yellow
	}
}

function Show-UIOutput ($Data) {
    Clear-Host

    Show-Banner -OverallPassResult $Data.OverallPassResult -ConsoleOnly

    Log-Output "TPM INFO TOOL - $ScriptVersion - PowerShell: $($Data.PowerShellVer)"
    Log-Output '--- HARDWARE SPECIFICATIONS ---' 'Cyan'
    Log-Output "OS:           $($Data.currentOS) ($($Data.OSSubVersion)) - (Original Install: $($Data.OriginalOSBuild)) - Supported: $($Data.OSSupported)"
    Log-Output "CPU:          $($Data.CpuInfo.Name) $($Data.CpuInfo.Gen)"
	Log-Output "GPU ver:      Nvidia: $($Data.NvidiaDriver) AMD: $($Data.AmdDriver)"
	Log-Output "PC Model:     $($Data.PcModel)"
    Log-Output "Motherboard:  $($Data.Mobo)"
    Log-Output "BIOS:         $($Data.BiosInfo.String)"
	if ($Data.AgesaVersion) {
		Log-Output "Agesa:        $($Data.AgesaVersion)"
	}
	Log-Output "RAM Type:     $($Data.RamSlots)"
    Log-Output "TPM Version:  $($Data.TpmInfo.Text)"
    Log-Output "TPM Status:   $($Data.TpmOwnership.Text)"

    Log-Output "`n--- COMPLIANCE REPORT ---" 'Cyan'
    if ($Data.CpuInfo.OldAMD) { Log-Output 'CRITICAL: AMD pre Zen 2 CPUs do not work.' 'Red' }
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

	if ($Data.CodBroker.StartType -eq 'Automatic') {
		Log-Output 'WARNING: COD.Broker.Service is set to Automatic' 'DarkYellow'
	} elseif ($Data.CodBroker.Passed) {
		Log-Output 'RESULT: COD Broker Service Pass' 'Green'
	} else {
		Log-Output "ERROR: COD.Broker.Service is $($Data.CodBroker.Text)" 'Red'
	}
	Print-CodBrokerCycleStatus -CycleResult $Data.CodBrokerCycleStatus

	if ($Data.BrokerExe) {
		Log-Output "RESULT: CODBrokerService.exe Binary Exists (v$($Data.BrokerExe.Version)) [$($Data.BrokerExe.MD5ShortHex)] (Pass)" 'Green'
	} else {
		Log-Output 'WARNING: CODBrokerService.exe Binary Missing (Fail)' 'Yellow'
	}

	if ($Data.Randgrid.RegKeyExists -and $Data.Randgrid.RandgridFileExists) {
		Log-Output "[PASS] Randgrid File & Registry Key Exists: [$($Data.Randgrid.FirstChars)] : [$($Data.Randgrid.PlatformsFound)] : [$($Data.Randgrid.AllMd5s)]" 'Green'
	} else {
		if (-not $Data.Randgrid.RegKeyExists) {
			Log-Output 'CRITICAL: Randgrid Registry Key Missing' 'Red'
		}

		if (-not $Data.Randgrid.RandgridFileExists) {
			Log-Output 'CRITICAL: Randgrid.sys File Missing from Path' 'Red'
		}
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

	if ($Data.UACLevel -eq "Default") {
		Log-Output "[PASS] UAC $($Data.UACLevel)" Green
	} else {
		Log-Output "UAC $($Data.UACLevel)" Yellow
	}

	if ($Data.TestLocalAttestation) {
		Log-Output "[PASS] Local Attestation Test" Green
	} else {
		Log-Output "[FAIL] Local Attestation Test" Red
	}

	if ($Data.MicrosoftCa.Passed) {
		Log-Output "[PASS] CA 2023: $($Data.MicrosoftCA.OverallState)" Green
	} else {
		Log-Output "[INFO] No CA 2023: $($Data.MicrosoftCA.OverallState)"
	}

	if (!$Data.GetEvent1040Details.Found){
		Log-Output "[PASS] Event 1040" 'Green'
	}else{
		Log-Output "[INFO] Event 1040 $($Data.GetEvent1040Details.Filename)"
	}

	if ($Data.Sha256 -eq $false) {
		Log-Output "[CHECK] IntegrityServices Sha256" Yellow
	}

	Log-Output "Third-Party AV: $($Data.doesThirdPartySecurityExist.Passed) - $($Data.doesThirdPartySecurityExist.Name)"
    Log-Output "Battery: $($Data.BatteryInfo.Text)"
    Log-Output "Partition: $($Data.PartitionStyle)"
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
                Log-Output "[WARN] BIOS & IME dates are over 6 months apart! ($([Math]::Round($dateDiff)) days difference)" 'Yellow'
            } else {
                Log-Output "[PASS] IME Sync: (Dates are within 6 months)" 'Green'
            }
        }catch { }
    }

	Log-Output "Windows Age:  $($Data.DaysSinceInstall) days"
	if ($Data.BitLocker -and $Data.BitLocker.Passed) {
        Log-Output "BitLocker Enabled: Yes" 'Red'
    } else {
        Log-Output "BitLocker Enabled: No"
    }

    Log-Output "$($Data.TpmEndorsement.Text)"

	if ($Data.Pluton){
		Log-Output "RESULT: Pluton detected" 'DarkYellow'
	}

	if ($Data.SocialMedia_UEFICA2023){
		Log-Output "RESULT: Why is CA2023 in Trusted Root Cert?" 'DarkYellow'
	}

	Log-Output "INFO: EK: $($Data.HasEK)"
	Log-Output "Win Update: $($Data.LatestUpdatesSummary)"

    Log-Output "`n--- SECURE BOOT KEYS ---" 'Cyan'

	Log-Output "PK" -Color "Cyan"
	$Data.SbKeys.PlatformKey | Select-Object -ExpandProperty CN | Where-Object { $_ } | ForEach-Object {
		Log-Output $_
	}
	Log-Output "KEK" -Color "Cyan"
	$Data.SbKeys.KeyExchangeKey | Select-Object -ExpandProperty CN | Where-Object { $_ } | ForEach-Object {
		Log-Output $_
	}
	Log-Output "DB" -Color "Cyan"
	$Data.SbKeys.DbKey | Format-Table -AutoSize -HideTableHeaders | Out-String -Stream | Where-Object { $_ -match '\S' } | ForEach-Object {
		Log-Output $_
	}

	Log-Output "`n--- CERTREQ ---" 'Cyan'
    $certOut = $Data.certRaw | Protect-AIKPrivacy
    Log-Output $certOut 'Green'

	Log-Output "Old Events" 'Cyan'
	$Data.EventId87 | ForEach-Object {
		Log-Output $_
	}

	if ($Data.IsOverallAIKPass) {
		Log-Output "[PASS] OverallAIKResult" 'Green'
	}else{
		Log-Output "[FAIL] OverallAIKResult" 'Yellow'
	}
	if ($data.failureMessage) {
		if ($data.OverallPassResult -eq 1) {
			Log-Output $data.failureMessage 'Red'
		}else{
			Log-Output $data.failureMessage 'Yellow'
		}
	}

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

	foreach ($Status in $Data.CodBootstrapperStatus) {
		if ($Status.Found) {
			if ($Status.Passed) {
				Log-Output "PASS: bootstrapper.log" 'Green'
			} else {
				Log-Output "INFO: bootstrapper.log"
				foreach ($Line in $Status.BottomLines) {
					Log-Output "  $Line" 'White'
				}
			}
		} else {
			$SkipReason = if ($Status.BottomLines) { $Status.BottomLines[0] } else { "Path not found" }
			Log-Output "RESULT: bootstrapper.log skipped: ($SkipReason)" 'White'
		}
	}
	Log-Output ""

	#Print-PCRTable

	Show-TcgAttestationAudit -Data $Data

    Show-Banner -OverallPassResult $Data.OverallPassResult

	if (-not ($Data.EnrollSuccess)) {
		Log-Output "EnrollSuccess Fail." 'Red'
	}

    if ($Data.OverallPassResult -eq 1) {
		Write-Host "Reminder - Ensure you are on the latest BIOS and have reset/cleared the TPM. Start Menu->type tpm.msc and Clear TPM." -ForegroundColor Yellow
    }

    if ($Data.OverallPassResult -eq 0) {
        Log-Output "FAILED: TPM Attestation is not working on this pc.`n" 'Red'
		Write-Host "Reminder - Ensure you are on the latest BIOS and have reset/cleared the TPM. Start Menu->type tpm.msc and Clear TPM." -ForegroundColor Yellow

        if ($Data.certRaw) {
            $certOut -split "`r?`n" | ForEach-Object {
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
		SocialMedia_UEFICA2023= $(Step-Progress; Test-SocialMedia_UEFICA2023)
		CsmInfo               = $(Step-Progress; Get-CsmStatus)
		TpmInfo               = $(Step-Progress; Get-TpmStatus)
		TpmOwnership          = $(Step-Progress; Get-TpmOwnershipState)
		ActivisionKey         = $(Step-Progress; Get-ActivisionKeyStatus)
		GetEvent1040Details   = $(Step-Progress; Get-Event1040Details)
		TestLocalAttestation  = $(Step-Progress; Test-LocalAttestation)
		CodBroker             = $(Step-Progress; Get-CodBrokerStatus)
		Randgrid              = $(Step-Progress; Get-RandgridRegistryAndDriverInfo)
		BrokerExe             = $(Step-Progress; Get-CODBrokerInfo)
		BatteryInfo           = $(Step-Progress; Get-BatteryStatus)
		PartitionStyle        = $(Step-Progress; Get-DiskPartitionStyle)
		CoreIsolation         = $(Step-Progress; Get-CoreIsolationHardwareStatus)
		IntelMeVersion        = $(Step-Progress; Get-IntelMeVersion)
		EventId87			  = $(Step-Progress; Get-EventId87)
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
		CodBrokerCycleStatus  = $(Step-Progress; Invoke-CodBrokerCycle)
		UACLevel              = $(Step-Progress; Get-UacStatus)
		LiveTpmKeyId          = $(Step-Progress; Get-LiveTpmKeyId)
		Sha256                = $(Step-Progress; Test-TPMSha256Support)
		TestMSI               = $(Step-Progress; Test-MSI)
		AgesaVersion          = $(Step-Progress; Get-AgesaVersion)
		HasEK			      = $(Step-Progress; HasEK)
		LatestUpdatesSummary  = $(Step-Progress; Get-LatestUpdatesSummary)
		ScoreShims 		      = $(Step-Progress; Get-DbxRevocationScore -Hashes $RevokedShims)
		ScoreRecentShims      = $(Step-Progress; Get-DbxRevocationScore -Hashes $RevokedRecentShims)
		EfiBootSignature      = $(Step-Progress; Get-EfiBootSignature)
    }

	$CertreqAttestation = Get-CertreqAttestation -Data $systemData
	$Pluton             = (Test-CertutilPluton -CertutilText $CertreqAttestation.CertRaw) -or (Is-Pluton)
	$ComparedKeyId      = Compare-TpmKeyId -certData $CertreqAttestation.CertRaw -tpmKeyId $systemData.LiveTpmKeyId

	$systemData | Add-Member -NotePropertyName "certRaw" -NotePropertyValue $CertreqAttestation.CertRaw
	$systemData | Add-Member -NotePropertyName "OverallPassResult" -NotePropertyValue $CertreqAttestation.OverallPassResult
	$systemData | Add-Member -NotePropertyName "IsOverallAIKPass" -NotePropertyValue $CertreqAttestation.IsOverallAIKPass
	$systemData | Add-Member -NotePropertyName "EnrollSuccess" -NotePropertyValue $CertreqAttestation.EnrollSuccess
	$systemData | Add-Member -NotePropertyName "nameResolutionFailure" -NotePropertyValue $CertreqAttestation.NameResolutionFailure
	$systemData | Add-Member -NotePropertyName "failureMessage" -NotePropertyValue $CertreqAttestation.FailureMessage

	$systemData | Add-Member -NotePropertyName "Pluton" -NotePropertyValue $Pluton
	$systemData | Add-Member -NotePropertyName "ComparedKeyId" -NotePropertyValue $ComparedKeyId

    Show-UIOutput -Data $systemData
	return $systemData
}

if ($TestFile -eq "-fix") {
	Show-FixMenu
}else{
	$Data = Invoke-MainExecution
	Show-UserRecommendedSteps -Data $Data
	Check-CodBrokerService -Data $Data
	Show-TpmGuiFormMessage -attestationPass $Data.OverallPassResult
}
