<# : chooser
@echo off

:: # Name: TPM INFO TOOL
:: # Updates: Check https://github.com/ArrowGamingCode/TPM-INFO-TOOL for updates.
:: # Purpose: An experimental tool that displays technical information to help troubleshoot TPM-related settings for gaming.
:: # Use official tools and troubleshooting first!
:: # License: GNU General Public License version 3
set "TPM_TOOL_VERSION=1.0.7"

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
$global:ImageBuffer     = [System.Collections.Generic.List[PSObject]]::new()
$global:ProgressStep = 0
$global:TotalSteps   = 56
$ScriptVersion = $env:TPM_TOOL_VERSION

# =========================================================================
# FUNCTIONS
# =========================================================================

function Start-TPM-Maintenance {
	#Read TPM from nvram.
	Start-ScheduledTask -TaskPath "\Microsoft\Windows\TPM\" -TaskName "Tpm-Maintenance"
}
Start-TPM-Maintenance

function Step-Progress {
    $global:ProgressStep++
    $PercentComplete = [math]::Min(100, [int](($global:ProgressStep / $global:TotalSteps) * 100))
    Write-Progress -Activity "Loading System Diagnostics" -Status "Progress: $PercentComplete%" -PercentComplete $PercentComplete
}

function Get-CpuCompliance {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cpuName = $cpu.Name.Trim() -replace '\s+', ' '
        $isPassed = $true
        $isAmd = $cpu.Manufacturer -like '*AMD*' -or $cpuName -match 'AMD'

        $genValue = $null
        if ($cpuName -match "Intel") {
            if ($cpuName -match "Core\(TM\) Ultra (\d)") {
                $genValue = "Gen: $($Matches[1])"
            } elseif ($cpuName -match "i\d-(\d+)") {
                $modelNum = $Matches[1]
                if ($modelNum.Length -eq 4) { $genValue = "Gen: $($modelNum.Substring(0, 1))" }
                elseif ($modelNum.Length -eq 5) { $genValue = "Gen: $($modelNum.Substring(0, 2))" }
            }
        } elseif ($cpuName -match "AMD.*Ryzen") {
            if ($cpuName -match "\b(\d)\d{3}\b") {
                $genValue = "Gen: $($Matches[1])"
            } elseif ($cpuName -match "Ryzen AI (\d+)") {
                $genValue = "Gen: $($Matches[1])"
            }
        }

        if ($cpuName -match 'AMD Ryzen' -and $cpuName -match '\b([12]\d{3})[A-Z]*\b') {
            $isPassed = $false
        }

        return [PSCustomObject]@{
            Name   = $cpu.Name
            Gen    = $genValue
            Passed = $isPassed
            Socket = $cpu.SocketDesignation
            IsAMD  = $isAmd
        }
    }
    catch {
        return [PSCustomObject]@{
            Name   = "Unknown"
            Gen    = ""
            Passed = $false
            Socket = "Unknown"
            IsAMD  = $false
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
            }
        } else {
            return [PSCustomObject]@{
                Text           = "Unable to read TPM Ownership properties via Get-Tpm"
                Passed         = $false
                PendingRestart = $null
            }
        }
    } catch {
        return [PSCustomObject]@{
            Text           = "Error executing TPM Ownership query"
            Passed         = $false
            PendingRestart = $null
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


function Show-TcgAttestationAudit ($Data) {
	$TcgData =  $Data.MeasuredBootCompliance

    Log-Output "--- MEASURED BOOT BINARY AUDIT (EXPERIMENTAL) ---" 'Cyan'
	Show-PCR_Message

	if($Data.ComparedKeyId){
		Log-Output $Data.ComparedKeyId
	}

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
        $certRaw = certreq -q -enrollaik -f -config '""' 2>&1 | Out-String
    }
	Write-Progress -Activity "Loading System Diagnostics" -Completed

    $successPatterns = "(?s)(?=.*SCEPDispositionSuccess)(?=.*EnrollStatus\(1\):\s*Enrolled)(?=.*New Certificate:)"
	$enrollSuccess = $certRaw -match $successPatterns
	if ($certRaw -match "Bad Request" -or $certRaw -match "No valid TPM EK") {
        $enrollSuccess = $false
    }

	$nameResolutionFailure = $certRaw -match "The server name or address could not be resolved"
	$failureType1 = $certRaw -match "1168 ERROR_NOT_FOUND"

	$failureMessage = ""
	if($failureType1){
		$failureMessage = "[FAIL] CertReq - registry issue?"
	}

	$isOverallPass = Get-OverallPassStatus -enrollSuccess $enrollSuccess -data $Data

    return [PSCustomObject]@{
        CertRaw       = $certRaw
        IsOverallPass = $isOverallPass
		EnrollSuccess = $enrollSuccess
		NameResolutionFailure = $nameResolutionFailure
		FailureMessage = $failureMessage
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
        return "Key Comp: Pass"
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

# =========================================================================
# GUI FORM
# =========================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-TpmGuiFormMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [bool]$AttestationPass
    )

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

    if ($AttestationPass) {
        $statusText  = "Pass"
        $statusColor = [System.Drawing.Color]::Green
    } else {
        $statusText  = "Fail"
        $statusColor = [System.Drawing.Color]::Red
    }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text            = "TPM INFO TOOL"
        Size            = New-Object System.Drawing.Size(570, 230)
        StartPosition   = "CenterScreen"
        FormBorderStyle = "FixedSingle"
        MaximizeBox     = $false
        BackColor       = [System.Drawing.Color]::White
        TopMost         = $true
    }

    $lblTitle = New-Object System.Windows.Forms.Label -Property @{
        Location = New-Object System.Drawing.Point(30, 30)
        Size     = New-Object System.Drawing.Size(220, 30)
        Text     = "OVERALL: TPM Attestation"
        Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    }
    $form.Controls.Add($lblTitle)

    $lblStatus = New-Object System.Windows.Forms.Label -Property @{
        Location  = New-Object System.Drawing.Point(255, 30)
        Size      = New-Object System.Drawing.Size(100, 30)
        Text      = $statusText
        Font      = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        ForeColor = $statusColor
    }
    $form.Controls.Add($lblStatus)

    $lblNotice = New-Object System.Windows.Forms.Label -Property @{
        Location  = New-Object System.Drawing.Point(30, 75)
        Size      = New-Object System.Drawing.Size(490, 45)
        Text      = "All information has been copied to your clipboard ready to paste into a forum!"
        Font      = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Italic)
        ForeColor = [System.Drawing.Color]::DarkSlateGray
    }
    $form.Controls.Add($lblNotice)

    $btnClose = New-Object System.Windows.Forms.Button -Property @{
        Location = New-Object System.Drawing.Point(30, 135)
        Size     = New-Object System.Drawing.Size(150, 35)
        Text     = "Close"
        Font     = New-Object System.Drawing.Font("Segoe UI", 10)
        TabIndex = 0
    }
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)

    $btnSaveImg = New-Object System.Windows.Forms.Button -Property @{
        Location = New-Object System.Drawing.Point(200, 135)
        Size     = New-Object System.Drawing.Size(160, 35)
        Text     = "Save Results to Image"
        Font     = New-Object System.Drawing.Font("Segoe UI", 10)
    }

    $btnSaveImg.Add_Click({
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog -Property @{
            Filter   = "PNG Image|*.png|JPEG Image|*.jpg"
            Title    = "Save Tool Text Report"
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
    })
    $form.Controls.Add($btnSaveImg)

    $btnCloseClear = New-Object System.Windows.Forms.Button -Property @{
        Location = New-Object System.Drawing.Point(380, 135)
        Size     = New-Object System.Drawing.Size(160, 35)
        Text     = "Close and Clear Clipboard"
        Font     = New-Object System.Drawing.Font("Segoe UI", 9.5)
    }
    $btnCloseClear.Add_Click({
        [System.Windows.Forms.Clipboard]::Clear()
        $form.Close()
    })
    $form.Controls.Add($btnCloseClear)

    $form.ShowDialog() | Out-Null
    $form.Dispose()
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
		if ($Data.CpuInfo.Socket -eq "AM4") {
			Log-Output "ALL AM4 systems need a BIOS update after ~August 2025. Check if there is a newer BIOS" 'Yellow'
		} else {
			Log-Output "-> Check if there is a newer BIOS" 'Yellow'
		}
        $hasIssues = $true
    }

	if ($Data.IntelBiosInfo.IsIntel -and $Data.IntelBiosInfo.RequiresFirmwareUpdate) {
        Log-Output "-> Your Intel PTT Firmware version ($($Data.IntelBiosInfo.Version)) appears to be outdated. Update BIOS/Firmware" 'Yellow'
        $hasIssues = $true
    }

	if (!$Data.CompatibilityFlags.Passed) {
        Log-Output "-> COD is intended to run without any compatibility or admin flags." 'Yellow'
        $hasIssues = $true
    }

	if ($Data.doesThirdPartySecurityExist.Passed -and $Data.isOverallPass) {
        Log-Output "-> [WARNING] A third-party Antivirus was detected!" 'Yellow'
        Log-Output "   WHY: Aggressive third-party security software can block CoD." 'Yellow'
		Log-Output "   WHEN: If you have problems."
        Log-Output "   HOW TO FIX: Whitelist CoD. [cod.exe, CODBrokerInstaller.exe, CODBrokerService.exe]" 'White'
        $hasIssues = $true
    }

	if (!$Data.CodBroker.Passed) {
        Log-Output "-> [FIX REQUIRED] The COD Broker Service is broken" 'Red'
        Log-Output "Please uninstall CoD and then install again." 'White'
        $hasIssues = $true
    }

	if ($Data.SecureBoot.Passed -and !$Data.SecureBootType.Passed) {
        Log-Output "-> [WARNING] Secure Boot is active but stuck in 'Setup Mode'!" 'Yellow'
        Log-Output "   WHY: The motherboard hasn't loaded its default factory platform certificates, meaning Secure Boot isn't actively enforcing rules." 'Yellow'
        Log-Output "   HOW TO FIX: Enter your BIOS, navigate to Secure Boot, and look for an option to 'Install Default Factory Keys' or reset Key Management." 'White'
        $hasIssues = $true
    }

	if ($Data.Pluton -and -not $Data.isOverallPass) {
        Log-Output "-> [WARNING] This PC uses a Pluton TPM (which often don't work). Some devices let you turn this off in the BIOS" 'Yellow'
		Log-Output "-> On selected MSI_BIOS->Advanced->AMD fTPM switch->Change 'AMD CPU HSP' to AMD CPU fTPM" 'Yellow'
        $hasIssues = $true

		if ($Data.TestMSI.IsMSI){
			Log-Output "->https://www.msi.com/faq/faq-12386 Resolve the 'BIOS Firmware Update Required' Prompt When Running Call of Duty" 'Yellow'
		}
    }

	if ($Data.NameResolutionFailure) {
		Log-Output "Cannot connect to the cloud attestation server. Firewall or ISP may be blocking certreq" 'Red'
		Log-Output "->Check you have internet" 'Red'
		$hasIssues = $true
	}

	if (!$Data.MicrosoftCa.Passed) {
		Log-Output "-> [WARNING] Windows UEFI CA 2023 not found"  'Yellow'
		Log-Output "   COD MAY need this updated. However, irrespective of COD, its best practice to have this."
		$hasIssues = $true
	}


    if (!$hasIssues) {
        Log-Output "-> NA" 'Green'
    }
}

# =========================================================================
# UI RENDERING PIPELINE
# =========================================================================

function Show-Banner {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [bool]$isOverallPass,

        [switch]$ConsoleOnly
    )

	$LogCmd = if ($ConsoleOnly) {
        { Write-Host $args[0] -ForegroundColor $args[1] }
    } else {
        { Log-Output -Text $args[0] -Color $args[1] }
    }

    if ($isOverallPass) {
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
    Clear-Host

    Show-Banner -isOverallPass $Data.isOverallPass -ConsoleOnly

    Log-Output "TPM INFO TOOL - $ScriptVersion - PowerShell: $($Data.PowerShellVer)"
    Log-Output '--- HARDWARE SPECIFICATIONS ---' 'Cyan'
    Log-Output "OS:           $($Data.currentOS) ($($Data.OSSubVersion)) - (Original Install: $($Data.OriginalOSBuild)) - Supported: $($Data.OSSupported)"
    Log-Output "CPU:          $($Data.CpuInfo.Name) $($Data.CpuInfo.Gen)"
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

    Log-Output "`n--- SECURE BOOT KEYS DETECTED ---" 'Cyan'
    Log-Output "Platform Key (PK):           $($Data.SbKeys.PK)"
    Log-Output "Key Exchange Key (KEK):    $($Data.SbKeys.KEK)"
    Log-Output "Authorized DB Key:         $($Data.SbKeys.DB)"

	Log-Output "`n--- CERTREQ ---" 'Cyan'
    $certOut = $Data.certRaw | Protect-AIKPrivacy
    Log-Output $certOut 'Green'

	if ($data.failureMessage) {
		Log-Output $data.failureMessage 'red'
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

    Show-Banner -isOverallPass $Data.isOverallPass

	if (-not ($Data.EnrollSuccess)) {
		Log-Output "EnrollSuccess Fail." 'Red'
	}

    if (-not ($Data.isOverallPass)) {
        Log-Output "FAILED: TPM Attestation is not working on this pc.`n" 'Red'
		Write-Host "Reminder - Ensure you are on the latest BIOS and have reset/cleared the TPM. Start Menu->type tpm.msc and Clear TPM." -ForegroundColor Yellow

        if ($Data.certRaw) {
            $Data.certRaw -split "`r?`n" | ForEach-Object {
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
		TestMSI              = $(Step-Progress; Test-MSI)
    }

	$CertreqAttestation = Get-CertreqAttestation -Data $systemData
	$Pluton             = (Test-CertutilPluton -CertutilText $CertreqAttestation.CertRaw) -or (Is-Pluton)
	$ComparedKeyId      = Compare-TpmKeyId -certData $CertreqAttestation.CertRaw -tpmKeyId $systemData.LiveTpmKeyId

	$systemData | Add-Member -NotePropertyName "certRaw" -NotePropertyValue $CertreqAttestation.CertRaw
	$systemData | Add-Member -NotePropertyName "isOverallPass" -NotePropertyValue $CertreqAttestation.IsOverallPass
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
	Show-TpmGuiFormMessage -attestationPass $Data.isOverallPass
}
