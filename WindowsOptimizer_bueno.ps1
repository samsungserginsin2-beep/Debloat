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
$global:LogTextBox = $null

function Test-AdminElevation {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Host "Se requieren privilegios de administrador. Solicitando elevacion..." -ForegroundColor Yellow
        if ($psISE) { $scriptPath = $psISE.CurrentFile.FullPath } else { $scriptPath = $PSCommandPath }
        
        if (-not $scriptPath -or $scriptPath -eq "") {
            Write-Host "No se pudo determinar la ruta del script." -ForegroundColor Red
            Read-Host "Presiona Enter para salir"; exit 1
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
if ($global:Is24H2) { $global:Bloatware += @("Microsoft.Windows.AI.Copilot", "Microsoft.Copilot", "Microsoft.Windows.Recall") }
$global:BloatwareRegex = $global:Bloatware -join '|'
#endregion

#region [FUNCIONES DE LIMPIEZA BASICA]
function Clear-CurrentUserTemp {
    Write-Log "========== LIMPIANDO PERFIL ACTUAL ==========" "TASK"
    try {
        if (Test-Path "$env:USERPROFILE\AppData\Local\Temp") {
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
            cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null
            cmd /c "rd /s /q C:\Windows\Temp" 2>&1 | Out-Null
            Write-Log "Limpieza de Windows\Temp completada" "OK"
        }
    } catch { Write-Log "Error al limpiar Windows\Temp" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Clear-InternetCache {
    Write-Log "========== LIMPIANDO CACHE DE INTERNET ==========" "TASK"
    RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null
    Write-Log "Cache de Internet limpiada" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Run-DiskCleanup {
    Write-Log "========== EJECUTANDO LIMPIEZA DE DISCO ==========" "TASK"
    Cleanmgr.exe /sagerun:64 2>&1 | Out-Null
    Write-Log "Limpieza de disco completada" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Disable-Firewall {
    Write-Log "========== DESHABILITANDO FIREWALL ==========" "TASK"
    netsh advfirewall set domainprofile state off 2>&1 | Out-Null
    netsh advfirewall set privateprofile state off 2>&1 | Out-Null
    netsh advfirewall set publicprofile state off 2>&1 | Out-Null
    Write-Log "Firewall deshabilitado" "OK"
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Invoke-FullCleanup {
    Write-Log "========== LIMPIEZA COMPLETA ==========" "TASK"
    Clear-CurrentUserTemp; Clear-AllUsersTemp; Clear-WindowsTemp; Clear-InternetCache; Run-DiskCleanup
    Write-Log "========== LIMPIEZA COMPLETA FINALIZADA ==========" "OK"
}

function Remove-AllBloatware {
    Write-Log "========== ELIMINANDO BLOATWARE ==========" "TASK"
    $removed = 0
    $appxPackages = Get-AppxPackage | Where-Object { $_.Name -match $global:BloatwareRegex }
    foreach ($pkg in $appxPackages) {
        try { Remove-AppxPackage -Package $pkg -ErrorAction SilentlyContinue; $removed++; Write-Log "  Eliminado: $($pkg.Name)" "OK" } catch { }
    }
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $global:BloatwareRegex }
    foreach ($prov in $provisioned) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue; Write-Log "  Eliminado: $($prov.DisplayName)" "OK" } catch { }
    }
    
    $telemetryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    if (!(Test-Path $telemetryPath)) { New-Item -Path $telemetryPath -Force | Out-Null }
    Set-ItemProperty -Path $telemetryPath -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
    
    $bingPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $bingPath)) { New-Item -Path $bingPath -Force | Out-Null }
    Set-ItemProperty -Path $bingPath -Name "BingSearchEnabled" -Value 0 -ErrorAction SilentlyContinue
    
    $cortanaPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    if (!(Test-Path $cortanaPath)) { New-Item -Path $cortanaPath -Force | Out-Null }
    Set-ItemProperty -Path $cortanaPath -Name "AllowCortana" -Value 0 -ErrorAction SilentlyContinue
    
    if ($global:IsWindows11) {
        $widgetsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
        if (!(Test-Path $widgetsPath)) { New-Item -Path $widgetsPath -Force | Out-Null }
        Set-ItemProperty -Path $widgetsPath -Name "AllowNewsAndInterests" -Value 0 -ErrorAction SilentlyContinue
    }
    
    if ($global:Is24H2) {
        $recallPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (!(Test-Path $recallPath)) { New-Item -Path $recallPath -Force | Out-Null }
        Set-ItemProperty -Path $recallPath -Name "EnableRecall" -Value 0 -ErrorAction SilentlyContinue
    }
    Write-Log "========== COMPLETADO: $removed apps eliminadas ==========" "OK"
}

function Remove-OneDrive {
    Write-Log "========== DESINSTALANDO ONEDRIVE ==========" "TASK"
    try {
        Get-Process -Name "OneDrive*" -ErrorAction SilentlyContinue | Stop-Process -Force
        $uninstaller = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (!(Test-Path $uninstaller)) { $uninstaller = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        if (Test-Path $uninstaller) {
            $process = Start-Process -FilePath $uninstaller -ArgumentList "/uninstall" -NoNewWindow -PassThru -Wait
            Write-Log "OneDrive desinstalado" "OK"
        }
    } catch { Write-Log "Error al desinstalar OneDrive: $_" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Install-OneDrive {
    Write-Log "========== INSTALANDO ONEDRIVE ==========" "TASK"
    try {
        $oneDriveUrl = "https://go.microsoft.com/fwlink/?linkid=2264368"
        $installerPath = "$global:DownloadDir\OneDriveSetup.exe"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $oneDriveUrl -OutFile $installerPath -UseBasicParsing
        if (Test-Path $installerPath) {
            $process = Start-Process -FilePath $installerPath -ArgumentList "/silent" -NoNewWindow -PassThru -Wait
            Write-Log "OneDrive instalado" "OK"
            Start-Sleep -Seconds 3; Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "Error al instalar OneDrive: $_" "ERROR" }
    Write-Log "========== COMPLETADO ==========" "OK"
}

function Install-SelectedApps {
    param([string[]]$Apps)
    if ($global:InstallRunning) { return }
    $global:InstallRunning = $true
    foreach ($app in $Apps) {
        try {
            switch ($app) {
                "7zip" { Start-Process -FilePath "winget" -ArgumentList "install --id 7zip.7zip --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait }
                "Chrome" { Start-Process -FilePath "winget" -ArgumentList "install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait }
                "Firefox" { Start-Process -FilePath "winget" -ArgumentList "install --id Mozilla.Firefox --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait }
                "VLC" { Start-Process -FilePath "winget" -ArgumentList "install --id VideoLAN.VLC --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait }
            }
            Write-Log "  Instalado: $app" "OK"
        } catch { Write-Log "  Error: $app" "ERROR" }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $global:InstallRunning = $false
}

function Optimize-System {
    Write-Log "========== OPTIMIZANDO SISTEMA ==========" "TASK"
    $priorityPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    if (!(Test-Path $priorityPath)) { New-Item -Path $priorityPath -Force | Out-Null }
    Set-ItemProperty -Path $priorityPath -Name "SystemResponsiveness" -Value 10 -ErrorAction SilentlyContinue
    foreach ($service in @("SysMain", "WSearch")) {
        Stop-Service $service -Force -ErrorAction SilentlyContinue
        Set-Service $service -StartupType Disabled -ErrorAction SilentlyContinue
    }
    powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
    Write-Log "========== OPTIMIZACION COMPLETADA ==========" "OK"
}

function Start-RepairJob {
    Write-Log "========== INICIANDO REPARACION ==========" "TASK"
    $global:RepairRunning = $true
    $scriptBlock = {
        $logFile = "C:\Temp\WindowsOptimizer\optimizer_log.txt"
        function Write-Step { param([int]$Num, [int]$Total, [string]$Name, [string]$Status) $time = Get-Date -Format "HH:mm:ss"; Add-Content -Path $logFile -Value "[$time] [PASO $Num/$Total] $Name - $Status" }
        $total = 14
        Write-Step 1 $total "Limpiar Temp" "iniciando"; cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null; Write-Step 1 $total "Limpiar Temp" "COMPLETADO"
        Write-Step 2 $total "Limpiar WinTemp" "iniciando"; cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null; Write-Step 2 $total "Limpiar WinTemp" "COMPLETADO"
        Write-Step 3 $total "Cache Internet" "iniciando"; RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null; Write-Step 3 $total "Cache Internet" "COMPLETADO"
        Write-Step 4 $total "DISM Check" "iniciando"; & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-Null; Write-Step 4 $total "DISM Check" "COMPLETADO"
        Write-Step 5 $total "DISM Scan" "iniciando"; & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-Null; Write-Step 5 $total "DISM Scan" "COMPLETADO"
        Write-Step 6 $total "DISM Restore" "iniciando"; & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null; Write-Step 6 $total "DISM Restore" "COMPLETADO"
        Write-Step 7 $total "SFC" "iniciando"; & sfc.exe /scannow 2>&1 | Out-Null; Write-Step 7 $total "SFC" "COMPLETADO"
        Write-Step 8 $total "DLLs" "iniciando"; foreach ($dll in @("atl.dll", "urlmon.dll", "mshtml.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "oleaut32.dll", "ole32.dll", "shell32.dll", "wuapi.dll")) { regsvr32.exe /s $dll 2>&1 | Out-Null }; Write-Step 8 $total "DLLs" "COMPLETADO"
        Write-Step 9 $total "Winsock" "iniciando"; netsh winsock reset 2>&1 | Out-Null; Write-Step 9 $total "Winsock" "COMPLETADO"
        Write-Step 10 $total "DNS" "iniciando"; ipconfig /flushdns 2>&1 | Out-Null; Write-Step 10 $total "DNS" "COMPLETADO"
        Write-Step 11 $total "Firewall" "iniciando"; netsh advfirewall set allprofiles state off 2>&1 | Out-Null; Write-Step 11 $total "Firewall" "COMPLETADO"
        Write-Step 12 $total "WU Cache" "iniciando"; net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\SoftwareDistribution`"" 2>&1 | Out-Null; net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null; Write-Step 12 $total "WU Cache" "COMPLETADO"
        Write-Step 13 $total "GPO" "iniciando"; gpupdate /force 2>&1 | Out-Null; Write-Step 13 $total "GPO" "COMPLETADO"
        Write-Step 14 $total "DiskCleanup" "iniciando"; Cleanmgr.exe /sagerun:64 2>&1 | Out-Null; Write-Step 14 $total "DiskCleanup" "COMPLETADO"
        $time = Get-Date -Format "HH:mm:ss"; Add-Content -Path $logFile -Value "[$time] [FIN] ===== REPARACION COMPLETADA =====`n"; return $true
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
            $global:RepairTimer.Stop(); Receive-Job -Job $global:CurrentJob -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $global:CurrentJob -Force -ErrorAction SilentlyContinue
            $global:CurrentJob = $null; $global:RepairRunning = $false
            Write-Log "========== REPARACION COMPLETADA ==========" "OK"
            $res = [System.Windows.Forms.MessageBox]::Show("Reparacion finalizada. ¿Reiniciar ahora?", "Reparacion", "YesNo", "Question")
            if ($res -eq "Yes") { Start-Sleep 3; Restart-Computer -Force }
        }
    })
    $global:RepairTimer.Start()
}

function Reset-WindowsUpdateOnly {
    Write-Log "========== REINICIANDO WINDOWS UPDATE ==========" "TASK"
    net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; net stop cryptsvc 2>&1 | Out-Null
    $sdPath = "$env:SystemRoot\SoftwareDistribution"; if (Test-Path $sdPath) { cmd /c "rmdir /s /q `"$sdPath`"" 2>&1 | Out-Null }
    $catPath = "$env:SystemRoot\system32\catroot2"; if (Test-Path $catPath) { cmd /c "rmdir /s /q `"$catPath`"" 2>&1 | Out-Null }
    net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null; net start cryptsvc 2>&1 | Out-Null
    Write-Log "========== WINDOWS UPDATE REINICIADO ==========" "OK"
}

function Create-RestorePoint {
    Write-Log "========== CREANDO PUNTO DE RESTAURACION ==========" "TASK"
    try { Checkpoint-Computer -Description "Optimizer" -ErrorAction SilentlyContinue; Write-Log "Punto creado" "OK" } catch { Write-Log "Error al crear punto" "WARN" }
}

function Kill-HungProcesses {
    Write-Log "========== TERMINANDO PROCESOS ==========" "TASK"
    if ($global:RepairTimer) { $global:RepairTimer.Stop(); $global:RepairTimer.Dispose(); $global:RepairTimer = $null }
    if ($global:CurrentJob) { Stop-Job -Job $global:CurrentJob -ErrorAction SilentlyContinue; Remove-Job -Job $global:CurrentJob -Force -ErrorAction SilentlyContinue; $global:CurrentJob = $null; $global:RepairRunning = $false }
    foreach ($proc in @("dism", "sfc", "TiWorker", "TrustedInstaller", "OneDrive", "winget")) {
        try { Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Log "Terminado: $proc" "OK" } catch { }
    }
    Write-Log "========== COMPLETADO ==========" "OK"
}
#endregion

#region [INTERFAZ GRAFICA]
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Form = New-Object System.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(680, 820) # TAMAÑO CORREGIDO
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'Sizable'
$Form.MinimizeBox = $true
$Form.MaximizeBox = $true
$Form.ShowIcon = $false
$Form.Text = "Windows Optimizer v$global:ScriptVersion - $global:WindowsVersion"
$Form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

# Panel Debloat
$DebloatPanel = New-Object System.Windows.Forms.Panel
$DebloatPanel.height = 130
$DebloatPanel.width = 660
$DebloatPanel.location = New-Object System.Drawing.Point(10, 10)
$DebloatPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

$DebloatLabel = New-Object System.Windows.Forms.Label
$DebloatLabel.text = "ELIMINAR BLOATWARE"
$DebloatLabel.AutoSize = $true
$DebloatLabel.location = New-Object System.Drawing.Point(10, 5)
$DebloatLabel.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold)
$DebloatLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")

$RemoveAllBloatware = New-Object System.Windows.Forms.Button
$RemoveAllBloatware.FlatStyle = 'Flat'
$RemoveAllBloatware.text = "ELIMINAR TODO (Copilot, Xbox, Widgets, Telemetria)"
$RemoveAllBloatware.width = 650
$RemoveAllBloatware.height = 40
$RemoveAllBloatware.location = New-Object System.Drawing.Point(5, 30)
$RemoveAllBloatware.Font = New-Object System.Drawing.Font('Consolas', 9)
$RemoveAllBloatware.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$RemoveAllBloatware.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$RemoveAllBloatware.Add_Click({ Remove-AllBloatware })

$RemoveOneDriveBtn = New-Object System.Windows.Forms.Button
$RemoveOneDriveBtn.FlatStyle = 'Flat'
$RemoveOneDriveBtn.text = "DESINSTALAR ONEDRIVE"
$RemoveOneDriveBtn.width = 650
$RemoveOneDriveBtn.height = 35
$RemoveOneDriveBtn.location = New-Object System.Drawing.Point(5, 80)
$RemoveOneDriveBtn.Font = New-Object System.Drawing.Font('Consolas', 9)
$RemoveOneDriveBtn.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$RemoveOneDriveBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$RemoveOneDriveBtn.Add_Click({ Remove-OneDrive })

$DebloatPanel.controls.AddRange(@($DebloatLabel, $RemoveAllBloatware, $RemoveOneDriveBtn))

# Panel Limpieza
$CleanPanel = New-Object System.Windows.Forms.Panel
$CleanPanel.height = 220
$CleanPanel.width = 660
$CleanPanel.location = New-Object System.Drawing.Point(10, 150)
$CleanPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

$CleanLabel = New-Object System.Windows.Forms.Label
$CleanLabel.text = "LIMPIEZA DE ARCHIVOS TEMPORALES"
$CleanLabel.AutoSize = $true
$CleanLabel.location = New-Object System.Drawing.Point(10, 5)
$CleanLabel.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold)
$CleanLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")

$BtnClearCurrentUser = New-Object System.Windows.Forms.Button
$BtnClearCurrentUser.FlatStyle = 'Flat'
$BtnClearCurrentUser.text = "LIMPIAR PERFIL ACTUAL"
$BtnClearCurrentUser.width = 320
$BtnClearCurrentUser.height = 35
$BtnClearCurrentUser.location = New-Object System.Drawing.Point(5, 35)
$BtnClearCurrentUser.Font = New-Object System.Drawing.Font('Consolas', 9)
$BtnClearCurrentUser.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$BtnClearCurrentUser.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$BtnClearCurrentUser.Add_Click({ Clear-CurrentUserTemp })

$BtnClearAllUsers = New-Object System.Windows.Forms.Button
$BtnClearAllUsers.FlatStyle = 'Flat'
$BtnClearAllUsers.text = "LIMPIAR TODOS LOS PERFILES"
$BtnClearAllUsers.width = 325
$BtnClearAllUsers.height = 35
$BtnClearAllUsers.location = New-Object System.Drawing.Point(330, 35)
$BtnClearAllUsers.Font = New-Object System.Drawing.Font('Consolas', 9)
$BtnClearAllUsers.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$BtnClearAllUsers.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$BtnClearAllUsers.Add_Click({ Clear-AllUsersTemp })

$BtnClearWindowsTemp = New-Object System.Windows.Forms.Button
$BtnClearWindowsTemp.FlatStyle = 'Flat'
$BtnClearWindowsTemp.text = "LIMPIAR WINDOWS TEMP"
$BtnClearWindowsTemp.width = 320
$BtnClearWindowsTemp.height = 35
$BtnClearWindowsTemp.location = New-Object System.Drawing.Point(5, 80)
$BtnClearWindowsTemp.Font = New-Object System.Drawing.Font('Consolas', 9)
$BtnClearWindowsTemp.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$BtnClearWindowsTemp.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$BtnClearWindowsTemp.Add_Click({ Clear-WindowsTemp })

$BtnClearInternetCache = New-Object System.Windows.Forms.Button
$BtnClearInternetCache.FlatStyle = 'Flat'
$BtnClearInternetCache.text = "LIMPIAR CACHE INTERNET"
$BtnClearInternetCache.width = 325
$BtnClearInternetCache.height = 35
$BtnClearInternetCache.location = New-Object System.Drawing.Point(330, 80)
$BtnClearInternetCache.Font = New-Object System.Drawing.Font('Consolas', 9)
$BtnClearInternetCache.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$BtnClearInternetCache.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555")
$BtnClearInternetCache.Add_Click({ Clear-InternetCache })

$BtnFullCleanup = New-Object System.Windows.Forms.Button
$BtnFullCleanup.FlatStyle = 'Flat'
$BtnFullCleanup.text = "LIMPIEZA COMPLETA (TODO LO ANTERIOR)"
$BtnFullCleanup.width = 650
$BtnFullCleanup.height = 40
$BtnFullCleanup.location = New-Object System.Drawing.Point(5, 130)
$BtnFullCleanup.Font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
$BtnFullCleanup.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee")
$BtnFullCleanup.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#777777")
$BtnFullCleanup.Add_Click({ Invoke-FullCleanup })

$CleanPanel.controls.AddRange(@($CleanLabel, $BtnClearCurrentUser, $BtnClearAllUsers, $BtnClearWindowsTemp, $BtnClearInternetCache, $BtnFullCleanup))

# Panel Instalacion
$InstallPanel = New-Object System.Windows.Forms.Panel
$InstallPanel.height = 200
$InstallPanel.width = 660
$InstallPanel.location = New-Object System.Drawing.Point(10, 380)
$InstallPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

$InstallLabel = New-Object System.Windows.Forms.Label
$InstallLabel.text = "INSTALAR APLICACIONES"
$InstallLabel.AutoSize = $true
$InstallLabel.location = New-Object System.Drawing.Point(10, 5)
$InstallLabel.Font = New-Object System.Drawing