<#
.SYNOPSIS
    Windows 10/11 SAMG27 Windows Optimizer v6.9
.DESCRIPTION
    Herramienta completa para optimizar Windows 10/11 (22H2-24H2)
.NOTES
    Compatible: Windows 10 20H2+, Windows 11 22H2/23H2/24H2
    Requiere: Ejecutar como Administrador
#>

#region [INICIALIZACION CON ELEVACION]
$ErrorActionPreference = 'Continue'
$global:ScriptVersion = "6.2"
$global:CurrentJob = $null
$global:RepairRunning = $false
$global:RepairTimer = $null
$global:InstallRunning = $false

# Declaramos LogTextBox global aquí para evitar errores de "variable no definida"
$global:LogTextBox = $null

# Función para verificar y solicitar elevación
function Test-AdminElevation {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Host "Se requieren privilegios de administrador. Solicitando elevacion..." -ForegroundColor Yellow
        
        # Obtener la ruta del script actual
        if ($psISE) {
            $scriptPath = $psISE.CurrentFile.FullPath
        } else {
            $scriptPath = $PSCommandPath
        }
        
        if (-not $scriptPath -or $scriptPath -eq "") {
            Write-Host "No se pudo determinar la ruta del script." -ForegroundColor Red
            Write-Host "Por favor, guarda el script primero y ejecutalo nuevamente." -ForegroundColor Yellow
            Read-Host "Presiona Enter para salir"
            exit 1
        }
        
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $batContent = "@echo off`npowershell.exe $arguments"
        $batPath = [System.IO.Path]::GetTempFileName() + ".bat"
        [System.IO.File]::WriteAllText($batPath, $batContent)
        Start-Process -FilePath $batPath -Verb RunAs -Wait
        Start-Sleep -Seconds 2
        Remove-Item $batPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Write-Host "Ejecutando con privilegios de administrador..." -ForegroundColor Green
    return $true
}

# Detectar si estamos en ISE (arreglado para no fallar en consola normal)
$global:IsISE = ($psISE -ne $null)

Test-AdminElevation

$global:WindowsVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ProductName
$global:WindowsBuild = [Environment]::OSVersion.Version.Build
$global:IsWindows11 = $global:WindowsBuild -ge 22000
$global:Is24H2 = $global:WindowsBuild -ge 26100

$global:WingetAvailable = $false
try {
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetPath) { $global:WingetAvailable = $true }
} catch { $global:WingetAvailable = $false }

$global:LogDir = "C:\Temp\WindowsOptimizer"
$global:DownloadDir = "C:\Temp\WindowsOptimizer\Downloads"
If (!(Test-Path $global:LogDir)) { New-Item -Path $global:LogDir -ItemType Directory -Force | Out-Null }
If (!(Test-Path $global:DownloadDir)) { New-Item -Path $global:DownloadDir -ItemType Directory -Force | Out-Null }

$global:LogFile = "$global:LogDir\optimizer_log.txt"
if (Test-Path $global:LogFile) { Remove-Item $global:LogFile -Force }

function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp] [$Type] $Message"
    Add-Content -Path $global:LogFile -Value $logEntry
    Write-Host $logEntry
    
    # Usamos $global:LogTextBox para que no falle si aún no está creado
    if ($global:LogTextBox -and !$global:LogTextBox.IsDisposed) {
        $global:LogTextBox.Text = Get-Content -Path $global:LogFile -ErrorAction SilentlyContinue | Out-String
        $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length
        $global:LogTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}
#endregion

#region [LISTAS DE BLOATWARE]
$global:Bloatware = @(
    "Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GetHelp", "Microsoft.Getstarted"
    "Microsoft.Microsoft3DViewer", "Microsoft.MicrosoftOfficeHub", "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.MixedReality.Portal", "Microsoft.Office.OneNote", "Microsoft.People", "Microsoft.Print3D"
    "Microsoft.SkypeApp", "Microsoft.WindowsAlarms", "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsMaps"
    "Microsoft.WindowsSoundRecorder", "Microsoft.YourPhone", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo"
    "Microsoft.Todos", "Microsoft.Windows.DevHome", "Microsoft.PowerAutomateDesktop", "Clipchamp.Clipchamp"
    "Microsoft.Xbox.TCUI", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay"
    "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider", "Microsoft.XboxSpeechToTextOverlay"
    "CandyCrush", "Facebook", "Twitter", "Spotify", "Netflix", "Disney"
    "Microsoft.Windows.WebExperiencePack", "MicrosoftWindows.Client.WebExperience"
)

if ($global:Is24H2) {
    $global:Bloatware += @("Microsoft.Windows.AI.Copilot", "Microsoft.Copilot", "Microsoft.Windows.Recall")
}
$global:BloatwareRegex = $global:Bloatware -join '|'
#endregion

#region [FUNCIONES DE LIMPIEZA BASICA]
function Clear-CurrentUserTemp {
    Write-Log "========== LIMPIANDO PERFIL ACTUAL ==========" "TASK"
    try {
        if (Test-Path "$env:USERPROFILE\AppData\Local\Temp") {
            Write-Log "Eliminando archivos de Temp del usuario actual..." "INFO"
            cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null
            cmd /c "rd /s /q `"$env:USERPROFILE\AppData\Local\Temp`"" 2>&1 | Out-Null
            Write-Log "Limpieza de Temp del usuario actual completada" "OK"
        }
    } catch { Write-Log "Error al limpiar Temp del usuario" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Clear-AllUsersTemp {
    Write-Log "========== LIMPIANDO TODOS LOS PERFILES ==========" "TASK"
    if (Test-Path "C:\Users") {
        $userPaths = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
        foreach ($userPath in $userPaths) {
            $tempPath = Join-Path $userPath.FullName "AppData\Local\Temp"
            if (Test-Path $tempPath) {
                Write-Log "Limpiando: $tempPath" "INFO"
                cmd /c "del /f /s /q `"$tempPath\*`"" 2>&1 | Out-Null
                cmd /c "rd /s /q `"$tempPath`"" 2>&1 | Out-Null
                Write-Log "Limpiado perfil: $($userPath.Name)" "OK"
            }
        }
    }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Clear-WindowsTemp {
    Write-Log "========== LIMPIANDO WINDOWS TEMP ==========" "TASK"
    try {
        if (Test-Path "C:\Windows\Temp") {
            Write-Log "Eliminando archivos de C:\Windows\Temp..." "INFO"
            cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null
            cmd /c "rd /s /q C:\Windows\Temp" 2>&1 | Out-Null
            Write-Log "Limpieza de Windows\Temp completada" "OK"
        }
    } catch { Write-Log "Error al limpiar Windows\Temp" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Clear-InternetCache {
    Write-Log "========== LIMPIANDO CACHE DE INTERNET ==========" "TASK"
    Write-Log "Limpiando cache de Internet Explorer/Edge..." "INFO"
    RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null
    RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 4 2>&1 | Out-Null
    RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 2 2>&1 | Out-Null
    RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 1 2>&1 | Out-Null
    Write-Log "Cache de Internet limpiada" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Run-DiskCleanup {
    Write-Log "========== EJECUTANDO LIMPIEZA DE DISCO ==========" "TASK"
    Write-Log "Ejecutando Cleanmgr con configuracion predefinida..." "INFO"
    Cleanmgr.exe /sagerun:64 2>&1 | Out-Null
    Write-Log "Limpieza de disco completada" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Disable-Firewall {
    Write-Log "========== DESHABILITANDO FIREWALL ==========" "TASK"
    Write-Log "Deshabilitando firewall en todos los perfiles..." "INFO"
    netsh advfirewall set domainprofile state off 2>&1 | Out-Null
    netsh advfirewall set privateprofile state off 2>&1 | Out-Null
    netsh advfirewall set publicprofile state off 2>&1 | Out-Null
    Write-Log "Firewall deshabilitado" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Clear-WindowsUpdateCache {
    Write-Log "========== LIMPIANDO CACHE DE WINDOWS UPDATE ==========" "TASK"
    Write-Log "Deteniendo servicios..." "INFO"
    net stop bits 2>&1 | Out-Null
    net stop wuauserv 2>&1 | Out-Null
    net stop cryptsvc 2>&1 | Out-Null
    
    Write-Log "Limpiando carpetas de cache..." "INFO"
    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    if (Test-Path $sdPath) { cmd /c "rmdir /s /q `"$sdPath`"" 2>&1 | Out-Null; Write-Log "  Limpiado SoftwareDistribution" "OK" }
    $catPath = "$env:SystemRoot\system32\catroot2"
    if (Test-Path $catPath) { cmd /c "rmdir /s /q `"$catPath`"" 2>&1 | Out-Null; Write-Log "  Limpiado Catroot2" "OK" }
    
    Write-Log "Reiniciando servicios..." "INFO"
    net start bits 2>&1 | Out-Null
    net start wuauserv 2>&1 | Out-Null
    net start cryptsvc 2>&1 | Out-Null
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Invoke-FullCleanup {
    Write-Log "========== LIMPIEZA COMPLETA ==========" "TASK"
    Clear-CurrentUserTemp
    Clear-AllUsersTemp
    Clear-WindowsTemp
    Clear-InternetCache
    Run-DiskCleanup
    Write-Log "========== LIMPIEZA COMPLETA FINALIZADA ==========" "OK"
}

function Remove-AllBloatware {
    Write-Log "========== ELIMINANDO BLOATWARE ==========" "TASK"
    $removed = 0
    Write-Log "Eliminando aplicaciones del usuario actual..." "INFO"
    $appxPackages = Get-AppxPackage | Where-Object { $_.Name -match $global:BloatwareRegex }
    foreach ($pkg in $appxPackages) {
        try { Remove-AppxPackage -Package $pkg -ErrorAction SilentlyContinue; $removed++; Write-Log "  Eliminado: $($pkg.Name)" "OK" } 
        catch { Write-Log "  Error: $($pkg.Name)" "WARN" }
    }
    
    Write-Log "Eliminando aplicaciones provisionadas..." "INFO"
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $global:BloatwareRegex }
    foreach ($prov in $provisioned) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue; Write-Log "  Eliminado provisionado: $($prov.DisplayName)" "OK" } 
        catch { }
    }
    
    Write-Log "Deshabilitando Telemetria..." "INFO"
    $telemetryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    if (!(Test-Path $telemetryPath)) { New-Item -Path $telemetryPath -Force | Out-Null }
    Set-ItemProperty -Path $telemetryPath -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
    
    Write-Log "Deshabilitando Bing Search..." "INFO"
    $bingPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $bingPath)) { New-Item -Path $bingPath -Force | Out-Null }
    Set-ItemProperty -Path $bingPath -Name "BingSearchEnabled" -Value 0 -ErrorAction SilentlyContinue
    
    Write-Log "Deshabilitando Cortana..." "INFO"
    $cortanaPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    if (!(Test-Path $cortanaPath)) { New-Item -Path $cortanaPath -Force | Out-Null }
    Set-ItemProperty -Path $cortanaPath -Name "AllowCortana" -Value 0 -ErrorAction SilentlyContinue
    
    if ($global:IsWindows11) {
        Write-Log "Deshabilitando Widgets..." "INFO"
        $widgetsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
        if (!(Test-Path $widgetsPath)) { New-Item -Path $widgetsPath -Force | Out-Null }
        Set-ItemProperty -Path $widgetsPath -Name "AllowNewsAndInterests" -Value 0 -ErrorAction SilentlyContinue
    }
    
    if ($global:Is24H2) {
        Write-Log "Deshabilitando Recall..." "INFO"
        $recallPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (!(Test-Path $recallPath)) { New-Item -Path $recallPath -Force | Out-Null }
        Set-ItemProperty -Path $recallPath -Name "EnableRecall" -Value 0 -ErrorAction SilentlyContinue
    }
    Write-Log "========== COMPLETADO: $removed aplicaciones eliminadas ==========" "OK"
}

function Remove-OneDrive {
    Write-Log "========== DESINSTALANDO ONEDRIVE ==========" "TASK"
    try {
        Get-Process -Name "OneDrive*" -ErrorAction SilentlyContinue | Stop-Process -Force
        Write-Log "Procesos de OneDrive detenidos" "OK"
        $uninstaller = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (!(Test-Path $uninstaller)) { $uninstaller = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        if (Test-Path $uninstaller) {
            Write-Log "Ejecutando desinstalador..." "INFO"
            $process = Start-Process -FilePath $uninstaller -ArgumentList "/uninstall" -NoNewWindow -PassThru -Wait
            Write-Log "OneDrive desinstalado (codigo: $($process.ExitCode))" "OK"
        } else { Write-Log "No se encontro el desinstalador de OneDrive" "WARN" }
    } catch { Write-Log "Error al desinstalar OneDrive: $_" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Install-OneDrive {
    Write-Log "========== INSTALANDO ONEDRIVE ==========" "TASK"
    try {
        $oneDriveUrl = "https://go.microsoft.com/fwlink/?linkid=2264368"
        $installerPath = "$global:DownloadDir\OneDriveSetup.exe"
        Write-Log "Descargando instalador de OneDrive..." "INFO"
        # Forzamos TLS 1.2 para que no falle la descarga
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $oneDriveUrl -OutFile $installerPath -UseBasicParsing
        if (Test-Path $installerPath) {
            Write-Log "Ejecutando instalador..." "INFO"
            $process = Start-Process -FilePath $installerPath -ArgumentList "/silent" -NoNewWindow -PassThru -Wait
            Write-Log "OneDrive instalado (codigo: $($process.ExitCode))" "OK"
            Start-Sleep -Seconds 3
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "Error al instalar OneDrive: $_" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Install-SelectedApps {
    param([string[]]$Apps)
    if ($global:InstallRunning) { Write-Log "Ya hay una instalacion en curso" "WARN"; return }
    $global:InstallRunning = $true
    Write-Log "========== INSTALANDO APLICACIONES ==========" "TASK"
    if (-not $global:WingetAvailable) {
        Write-Log "Winget no esta disponible. Abriendo Microsoft Store..." "WARN"
        Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction SilentlyContinue
        $global:InstallRunning = $false; return
    }
    foreach ($app in $Apps) {
        Write-Log "Instalando: $app..." "INFO"
        try {
            switch ($app) {
                "7zip" { $proc = Start-Process -FilePath "winget" -ArgumentList "install --id 7zip.7zip --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait; Write-Log "  $app instalado (Cod: $($proc.ExitCode))" "OK" }
                "Chrome" { $proc = Start-Process -FilePath "winget" -ArgumentList "install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait; Write-Log "  $app instalado (Cod: $($proc.ExitCode))" "OK" }
                "Firefox" { $proc = Start-Process -FilePath "winget" -ArgumentList "install --id Mozilla.Firefox --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait; Write-Log "  $app instalado (Cod: $($proc.ExitCode))" "OK" }
                "VLC" { $proc = Start-Process -FilePath "winget" -ArgumentList "install --id VideoLAN.VLC --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait; Write-Log "  $app instalado (Cod: $($proc.ExitCode))" "OK" }
            }
        } catch { Write-Log "  Error instalando: $app - $_" "ERROR" }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Write-Log "========== INSTALACION COMPLETADA ==========" "OK"
    $global:InstallRunning = $false
}

function Optimize-System {
    Write-Log "========== OPTIMIZANDO SISTEMA ==========" "TASK"
    $priorityPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    if (!(Test-Path $priorityPath)) { New-Item -Path $priorityPath -Force | Out-Null }
    Set-ItemProperty -Path $priorityPath -Name "SystemResponsiveness" -Value 10 -ErrorAction SilentlyContinue
    Write-Log "  Priorizacion de juegos activada" "OK"
    $services = @("SysMain", "WSearch")
    foreach ($service in $services) {
        Stop-Service $service -Force -ErrorAction SilentlyContinue
        Set-Service $service -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log "  Servicio deshabilitado: $service" "OK"
    }
    powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
    Write-Log "  Plan de alto rendimiento activado" "OK"
    Write-Log "========== OPTIMIZACION COMPLETADA ==========" "OK"
}

function Start-RepairJob {
    Write-Log "========== INICIANDO REPARACION (14 PASOS) ==========" "TASK"
    $global:RepairRunning = $true
    $scriptBlock = {
        $logFile = "C:\Temp\WindowsOptimizer\optimizer_log.txt"
        function Write-Step { param([int]$Num, [int]$Total, [string]$Name, [string]$Status) $time = Get-Date -Format "HH:mm:ss"; Add-Content -Path $logFile -Value "[$time] [PASO $Num/$Total] $Name - $Status" }
        $total = 14
        try {
            Write-Step 1 $total "Limpiar Temp usuario" "iniciando"; cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null; cmd /c "rd /s /q `"$env:USERPROFILE\AppData\Local\Temp`"" 2>&1 | Out-Null; Write-Step 1 $total "Limpiar Temp usuario" "COMPLETADO"
            Write-Step 2 $total "Limpiar Windows Temp" "iniciando"; cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null; cmd /c "rd /s /q C:\Windows\Temp" 2>&1 | Out-Null; Write-Step 2 $total "Limpiar Windows Temp" "COMPLETADO"
            Write-Step 3 $total "Limpiar cache Internet" "iniciando"; RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null; Write-Step 3 $total "Limpiar cache Internet" "COMPLETADO"
            Write-Step 4 $total "DISM CheckHealth" "iniciando"; & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-Null; Write-Step 4 $total "DISM CheckHealth" "COMPLETADO"
            Write-Step 5 $total "DISM ScanHealth" "iniciando"; & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-Null; Write-Step 5 $total "DISM ScanHealth" "COMPLETADO"
            Write-Step 6 $total "DISM RestoreHealth" "iniciando"; & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null; Write-Step 6 $total "DISM RestoreHealth" "COMPLETADO"
            Write-Step 7 $total "SFC Scannow" "iniciando"; & sfc.exe /scannow 2>&1 | Out-Null; Write-Step 7 $total "SFC Scannow" "COMPLETADO"
            Write-Step 8 $total "Registrar DLLs" "iniciando"; $dlls = @("atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll", "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll", "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll", "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll", "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll", "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll", "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"); foreach ($dll in $dlls) { regsvr32.exe /s $dll 2>&1 | Out-Null }; Write-Step 8 $total "Registrar DLLs" "COMPLETADO"
            Write-Step 9 $total "Resetear Winsock" "iniciando"; netsh winsock reset 2>&1 | Out-Null; Write-Step 9 $total "Resetear Winsock" "COMPLETADO"
            Write-Step 10 $total "Limpiar cache DNS" "iniciando"; ipconfig /flushdns 2>&1 | Out-Null; Write-Step 10 $total "Limpiar cache DNS" "COMPLETADO"
            Write-Step 11 $total "Deshabilitar Firewall" "iniciando"; netsh advfirewall set domainprofile state off 2>&1 | Out-Null; Write-Step 11 $total "Deshabilitar Firewall" "COMPLETADO"
            Write-Step 12 $total "Limpiar cache Windows Update" "iniciando"; net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; net stop cryptsvc 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\SoftwareDistribution`"" 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\system32\catroot2`"" 2>&1 | Out-Null; net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null; net start cryptsvc 2>&1 | Out-Null; Write-Step 12 $total "Limpiar cache Windows Update" "COMPLETADO"
            Write-Step 13 $total "Actualizar politicas" "iniciando"; gpupdate /force 2>&1 | Out-Null; Write-Step 13 $total "Actualizar politicas" "COMPLETADO"
            Write-Step 14 $total "Limpieza de disco" "iniciando"; Cleanmgr.exe /sagerun:64 2>&1 | Out-Null; Write-Step 14 $total "Limpieza de disco" "COMPLETADO"
            $time = Get-Date -Format "HH:mm:ss"; Add-Content -Path $logFile -Value "[$time] [FIN] ===== REPARACION COMPLETADA =====`n"; return $true
        } catch { $time = Get-Date -Format "HH:mm:ss"; Add-Content -Path $logFile -Value "[$time] [ERROR] $_"; return $false }
    }
    $global:CurrentJob = Start-Job -Name "RepairSystem" -ScriptBlock $scriptBlock
    $global:RepairTimer = New-Object System.Windows.Forms.Timer
    $global:RepairTimer.Interval = 2000
    $global:RepairTimer.Add_Tick({
        if ($global:LogTextBox -and !$global:LogTextBox.IsDisposed) {
            $global:LogTextBox.Text = Get-Content -Path $global:LogFile -ErrorAction SilentlyContinue | Out-String
            $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length
            $global:LogTextBox.ScrollToCaret()
        }
        if ($global:CurrentJob.State -eq "Completed") {
            $global:RepairTimer.Stop()
            $result = Receive-Job -Job $global:CurrentJob -ErrorAction SilentlyContinue
            Remove-Job -Job $global:CurrentJob -Force -ErrorAction SilentlyContinue
            $global:CurrentJob = $null; $global:RepairRunning = $false
            if ($result -eq $true) {
                Write-Log "========== REPARACION COMPLETADA ==========" "OK"
                $res = [System.Windows.Forms.MessageBox]::Show("La reparacion finalizo.`n`n¿Desea reiniciar ahora?", "Reparacion", "YesNo", "Question")
                if ($res -eq "Yes") { Start-Sleep 3; Restart-Computer -Force }
            } else { Write-Log "La reparacion tuvo errores." "WARNING" }
        } elseif ($global:CurrentJob.State -eq "Failed") {
            $global:RepairTimer.Stop()
            Write-Log "Reparacion fallida: $($global:CurrentJob.JobStateInfo.Reason.Message)" "ERROR"
            Remove-Job -Job $global:CurrentJob -Force -ErrorAction SilentlyContinue
            $global:CurrentJob = $null; $global:RepairRunning = $false
        }
    })
    $global:RepairTimer.Start()
}

function Stop-RepairJob {
    Write-Log "========== DETENIENDO REPARACION ==========" "TASK"
    if ($global:RepairTimer) { $global:RepairTimer.Stop(); $global:RepairTimer.Dispose(); $global:RepairTimer = $null }
    if ($global:CurrentJob) {
        try { Stop-Job -Job $global:CurrentJob -ErrorAction SilentlyContinue; Remove-Job -Job $global:CurrentJob -Force -ErrorAction SilentlyContinue; Write-Log "Job detenido" "OK" } catch { Write-Log "Error al detener job: $_" "ERROR" }
        $global:CurrentJob = $null
    }
    foreach ($proc in @("dism", "sfc", "TiWorker", "TrustedInstaller")) { try { Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Log "Terminado: $proc" "OK" } catch {} }
    $global:RepairRunning = $false
    Write-Log "========== REPARACION DETENIDA ==========" "OK"
}

function Reset-WindowsUpdateOnly {
    Write-Log "========== REINICIANDO WINDOWS UPDATE ==========" "TASK"
    net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; net stop cryptsvc 2>&1 | Out-Null
    $sdPath = "$env:SystemRoot\SoftwareDistribution"; if (Test-Path $sdPath) { cmd /c "rmdir /s /q `"$sdPath`"" 2>&1 | Out-Null; Write-Log "  Limpiado SoftwareDistribution" "OK" }
    $catPath = "$env:SystemRoot\system32\catroot2"; if (Test-Path $catPath) { cmd /c "rmdir /s /q `"$catPath`"" 2>&1 | Out-Null; Write-Log "  Limpiado Catroot2" "OK" }
    net