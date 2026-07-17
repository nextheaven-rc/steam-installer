cls
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'   # acelera muito o Invoke-WebRequest no PS 5.1

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

# Fecha a Steam INTEIRA (nao so "steam") e espera os handles liberarem.
# Sem isso, algum processo da Steam (steamwebhelper etc.) pode segurar o
# xinput1_4.dll e a escrita do injetor falha.
function Stop-SteamCompletely {
    $names = @('steam','steamwebhelper','steamservice','steamerrorreporter','GameOverlayUI')
    foreach ($n in $names) {
        Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 20; $i++) {                 # espera ate ~10s liberar os handles
        if (-not (Get-Process $names -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
}

# Mata instancias de PowerShell DIFERENTES desta. Libera arquivos travados por um
# powershell pendurado (ex.: um zumbi de uma execucao anterior segurando o
# xinput1_4.dll de 0 bytes). Nunca mata a si mesmo aqui (o script ainda esta rodando).
function Stop-OtherPowerShell {
    foreach ($n in @('powershell','pwsh','powershell_ise')) {
        Get-Process $n -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID } |
            ForEach-Object { try { $_.Kill() } catch {} }
    }
}

# Baixa um DLL de forma SEGURA e a prova do bug do "0 bytes travado":
#   1) baixa pro TEMP com TIMEOUT (nunca fica pendurado segurando o arquivo final)
#   2) valida TAMANHO MINIMO (nunca instala DLL de 0 bytes / incompleto)
#   3) so entao MOVE por cima do destino (rename atomico no mesmo disco), com retry
# Retorna $true se instalou um DLL valido; $false caso contrario.
function Install-ProxyDll {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MinBytes = 10240,
        [int]$TimeoutSec = 30,
        [int]$Retries = 3
    )
    $tmp = "$Destination.download.tmp"
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        try {
            Invoke-WebRequest -Uri $Url -OutFile $tmp -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        } catch {
            Start-Sleep -Seconds 2; continue
        }
        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt $MinBytes) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2; continue
        }
        for ($mv = 1; $mv -le 5; $mv++) {
            try {
                Move-Item -Path $tmp -Destination $Destination -Force -ErrorAction Stop
                return $true
            } catch {
                Start-Sleep -Milliseconds 800    # alvo momentaneamente travado: tenta de novo
            }
        }
    }
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return $false
}

function CheckAndPromptProcess($processName, $message) {
    while (Get-Process $processName -ErrorAction SilentlyContinue) {
        Write-Host $message -ForegroundColor Red
        Start-Sleep 1.5
    }
}

$filePathToDelete = Join-Path $env:USERPROFILE "get.ps1"
Remove-ItemIfExists $filePathToDelete

Stop-SteamCompletely   # fecha a Steam inteira antes de mexer no injetor
Stop-OtherPowerShell   # mata outras instancias de PowerShell (libera locks) antes de instalar
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
    exit 1
}

if (-not (Test-Path $steamPath -PathType Container)) {
    Write-Host "Official Steam client is not installed on your computer. Please install it and try again." -ForegroundColor Red
    Start-Sleep 10
    exit 1
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

        $versionDllPath = Join-Path $steamPath "version.dll"
        Remove-ItemIfExists $versionDllPath

        $hidPath    = Join-Path $steamPath "xinput1_4.dll"
        $dwmapiPath = Join-Path $steamPath "dwmapi.dll"

        # exclusoes do Defender (best-effort)
        try { Add-MpPreference -ExclusionPath $hidPath    -ErrorAction SilentlyContinue } catch {}
        try { Add-MpPreference -ExclusionPath $dwmapiPath -ErrorAction SilentlyContinue } catch {}

        # Download SEGURO dos DLLs (temp + timeout + validacao de tamanho + move atomico).
        # Substitui o Invoke-RestMethod -OutFile direto, que na rede instavel deixava
        # um xinput1_4.dll de 0 bytes travado e o app achava que tinha dado certo.
        $downloadHidDll = "https://raw.githubusercontent.com/nextheaven-rc/steam-installer/main/update"
        $downloadDwmapi = "https://raw.githubusercontent.com/nextheaven-rc/steam-installer/main/dwmapi"

        $okHid = Install-ProxyDll -Url $downloadHidDll -Destination $hidPath
        $okDwm = Install-ProxyDll -Url $downloadDwmapi -Destination $dwmapiPath

        if (-not ($okHid -and $okDwm)) {
            Write-Host "[ERROR] Failed to install activation files. Check your connection / close Steam and try again." -ForegroundColor Red
            Start-Sleep 8
            exit 1    # codigo != 0 para o app (C#) saber que FALHOU
        }

        if (!(Test-Path $steamToolsRegPath)) {
            New-Item -Path $steamToolsRegPath -Force | Out-Null
        }

        Remove-ItemProperty -Path $steamToolsRegPath -Name "ActivateUnlockMode" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $steamToolsRegPath -Name "AlwaysStayUnlocked" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $steamToolsRegPath -Name "notUnlockDepot" -ErrorAction SilentlyContinue

        Set-ItemProperty -Path $steamToolsRegPath -Name "iscdkey" -Value "true" -Type String

        # ===================== FIM: ABRE STEAM + FECHA POWERSHELL =====================
        # Reabre a Steam (ativacao) — ela fica ABERTA ao terminar.
        $steamExePath = Join-Path $steamPath "steam.exe"
        Start-Process $steamExePath
        Start-Process "steam://"
        Write-Host "[Successfully connected to official activation server. Please login to Steam to activate]" -ForegroundColor Green

        # Da um instante pra Steam subir e entao fecha o PowerShell (outras janelas + esta).
        # Sem contagem regressiva e sem "press any key" — finaliza direto. A Steam continua aberta.
        Start-Sleep -Seconds 2
        Get-Process powershell, pwsh, powershell_ise -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID } |
            ForEach-Object { try { $_.Kill() } catch {} }
        Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue

        exit 0

    } catch {
        # Nao engole mais o erro em silencio: mostra e sinaliza falha (exit != 0) pro app.
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep 5
        exit 1
    }
}

PwStart
