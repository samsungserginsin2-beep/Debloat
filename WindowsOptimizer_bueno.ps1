<#
.SYNOPSIS
    Windows 10/11 SAMG27 Windows Optimizer v6.9 (Completo)
#>

$ErrorActionPreference = 'Continue'
$global:ScriptVersion = "6.9"
$global:CurrentJob = $null
$global:RepairRunning = $false
$global:RepairTimer = $null
$global:InstallRunning = $false
$global:LogTextBox = $null
$global:IsISE = ($psISE -ne $null)

function Test-AdminElevation {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Solicitando permisos de administrador..." -ForegroundColor Yellow
        $scriptPath = if ($psISE) { $psISE.CurrentFile.FullPath } else { $PSCommandPath }
        $batContent = "@echo off`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $batPath = [System.IO.Path]::GetTempFileName() + ".bat"
        [System.IO.File]::WriteAllText($batPath, $batContent)
        Start-Process -FilePath $batPath -Verb RunAs -Wait
        Start-Sleep -Seconds 2; Remove-Item $batPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Write-Host "Ejecutando con privilegios de administrador..." -ForegroundColor Green
}
Test-AdminElevation

$global:WindowsVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ProductName
$global:WindowsBuild = [Environment]::OSVersion.Version.Build
$global:IsWindows11 = $global:WindowsBuild -ge 22000
$global:Is24H2 = $global:WindowsBuild -ge 26100
$global:WingetAvailable = (Get-Command winget -ErrorAction SilentlyContinue) -ne $null

$global:LogDir = "C:\Temp\WindowsOptimizer"
$global:DownloadDir = "C:\Temp\WindowsOptimizer\Downloads"
If (!(Test-Path $global:LogDir)) { New-Item -Path $global:LogDir -ItemType Directory -Force | Out-Null }
If (!(Test-Path $global:DownloadDir)) { New-Item -Path $global:DownloadDir -ItemType Directory -Force | Out-Null }
$global:LogFile = "$global:LogDir\optimizer_log.txt"
if (Test-Path $global:LogFile) { Remove-Item $global:LogFile -Force }

function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $logEntry = "[$(Get-Date -Format 'HH:mm:ss')] [$Type] $Message"
    Add-Content -Path $global:LogFile -Value $logEntry
    Write-Host $logEntry
    if ($global:LogTextBox -and !$global:LogTextBox.IsDisposed) {
        $global:LogTextBox.Text = Get-Content -Path $global:LogFile -ErrorAction SilentlyContinue | Out-String
        $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length
        $global:LogTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

$global:Bloatware = @("Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.Microsoft3DViewer","Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection","Microsoft.MixedReality.Portal","Microsoft.Office.OneNote","Microsoft.People","Microsoft.Print3D","Microsoft.SkypeApp","Microsoft.WindowsAlarms","Microsoft.WindowsFeedbackHub","Microsoft.WindowsMaps","Microsoft.WindowsSoundRecorder","Microsoft.YourPhone","Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.Todos","Microsoft.Windows.DevHome","Microsoft.PowerAutomateDesktop","Clipchamp.Clipchamp","Microsoft.Xbox.TCUI","Microsoft.XboxApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay","Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","CandyCrush","Facebook","Twitter","Spotify","Netflix","Disney","Microsoft.Windows.WebExperiencePack","MicrosoftWindows.Client.WebExperience")
if ($global:Is24H2) { $global:Bloatware += @("Microsoft.Windows.AI.Copilot", "Microsoft.Copilot", "Microsoft.Windows.Recall") }
$global:BloatwareRegex = $global:Bloatware -join '|'

#region FUNCIONES
function Clear-CurrentUserTemp { Write-Log "Limpiando perfil actual..." "TASK"; cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null; cmd /c "rd /s /q `"$env:USERPROFILE\AppData\Local\Temp`"" 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Clear-AllUsersTemp { Write-Log "Limpiando todos los perfiles..." "TASK"; if (Test-Path "C:\Users") { Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $t = Join-Path $_.FullName "AppData\Local\Temp"; if (Test-Path $t) { cmd /c "del /f /s /q `"$t\*`"" 2>&1 | Out-Null; cmd /c "rd /s /q `"$t`"" 2>&1 | Out-Null } } }; Write-Log "Completado" "OK" }
function Clear-WindowsTemp { Write-Log "Limpiando Windows Temp..." "TASK"; cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null; cmd /c "rd /s /q C:\Windows\Temp" 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Clear-InternetCache { Write-Log "Limpiando cache Internet..." "TASK"; RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null; RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 4 2>&1 | Out-Null; RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 2 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Run-DiskCleanup { Write-Log "Ejecutando Cleanmgr..." "TASK"; Cleanmgr.exe /sagerun:64 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Disable-Firewall { Write-Log "Deshabilitando Firewall..." "TASK"; netsh advfirewall set domainprofile state off 2>&1 | Out-Null; netsh advfirewall set privateprofile state off 2>&1 | Out-Null; netsh advfirewall set publicprofile state off 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Invoke-FullCleanup { Write-Log "Limpieza completa..." "TASK"; Clear-CurrentUserTemp; Clear-AllUsersTemp; Clear-WindowsTemp; Clear-InternetCache; Run-DiskCleanup; Write-Log "Completado" "OK" }

function Remove-AllBloatware {
    Write-Log "Eliminando bloatware..." "TASK"; $removed = 0
    Get-AppxPackage | Where-Object { $_.Name -match $global:BloatwareRegex } | ForEach-Object { try { Remove-AppxPackage -Package $_ -ErrorAction SilentlyContinue; $removed++; Write-Log "Eliminado: $($_.Name)" "OK" } catch {} }
    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $global:BloatwareRegex } | ForEach-Object { try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue } catch {} }
    $tp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; if (!(Test-Path $tp)) { New-Item -Path $tp -Force | Out-Null }; Set-ItemProperty -Path $tp -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
    $bp = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"; if (!(Test-Path $bp)) { New-Item -Path $bp -Force | Out-Null }; Set-ItemProperty -Path $bp -Name "BingSearchEnabled" -Value 0 -ErrorAction SilentlyContinue
    $cp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; if (!(Test-Path $cp)) { New-Item -Path $cp -Force | Out-Null }; Set-ItemProperty -Path $cp -Name "AllowCortana" -Value 0 -ErrorAction SilentlyContinue
    if ($global:IsWindows11) { $wp = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; if (!(Test-Path $wp)) { New-Item -Path $wp -Force | Out-Null }; Set-ItemProperty -Path $wp -Name "AllowNewsAndInterests" -Value 0 -ErrorAction SilentlyContinue }
    if ($global:Is24H2) { $rp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; if (!(Test-Path $rp)) { New-Item -Path $rp -Force | Out-Null }; Set-ItemProperty -Path $rp -Name "EnableRecall" -Value 0 -ErrorAction SilentlyContinue }
    Write-Log "Completado: $removed apps" "OK"
}

function Remove-OneDrive {
    Write-Log "Desinstalando OneDrive..." "TASK"; Get-Process -Name "OneDrive*" -ErrorAction SilentlyContinue | Stop-Process -Force
    $u = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"; if (!(Test-Path $u)) { $u = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
    if (Test-Path $u) { $p = Start-Process -FilePath $u -ArgumentList "/uninstall" -NoNewWindow -PassThru -Wait; Write-Log "Completado (Cod: $($p.ExitCode))" "OK" }
}

function Install-OneDrive {
    Write-Log "Instalando OneDrive..." "TASK"; $url = "https://go.microsoft.com/fwlink/?linkid=2264368"; $path = "$global:DownloadDir\OneDriveSetup.exe"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing; Start-Process -FilePath $path -ArgumentList "/silent" -Wait; Remove-Item $path -Force; Write-Log "Completado" "OK" } catch { Write-Log "Error: $_" "ERROR" }
}

function Install-Apps {
    param([string[]]$Apps); if ($global:InstallRunning) { return }; $global:InstallRunning = $true
    foreach ($app in $Apps) { Write-Log "Instalando $app..." "INFO"; try { $id = switch ($app) { "7zip" { "7zip.7zip" } "Chrome" { "Google.Chrome" } "Firefox" { "Mozilla.Firefox" } "VLC" { "VideoLAN.VLC" } }; Start-Process -FilePath "winget" -ArgumentList "install --id $id --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait; Write-Log "$app instalado" "OK" } catch { Write-Log "Error $app" "ERROR" } }; $global:InstallRunning = $false
}

function Optimize-System {
    Write-Log "Optimizando..." "TASK"; $p = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; if (!(Test-Path $p)) { New-Item -Path $p -Force | Out-Null }; Set-ItemProperty -Path $p -Name "SystemResponsiveness" -Value 10 -ErrorAction SilentlyContinue
    foreach ($s in @("SysMain", "WSearch")) { Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Disabled -ErrorAction SilentlyContinue }; powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null; Write-Log "Completado" "OK"
}

function Start-RepairJob {
    Write-Log "Iniciando reparación (14 pasos)..." "TASK"; $global:RepairRunning = $true
    $sb = {
        $log = "C:\Temp\WindowsOptimizer\optimizer_log.txt"; function W-Step { param($n,$t,$s,$st) Add-Content $log "[$(Get-Date -Format 'HH:mm:ss')] [PASO $n/$t] $s - $st" }
        $steps = @("Limpiar Temp","Limpiar WinTemp","Cache Internet","DISM Check","DISM Scan","DISM Restore","SFC","DLLs","Winsock","DNS","Firewall","WU Cache","GPO","Disco")
        for ($i=0; $i -lt 14; $i++) { $n=$i+1; W-Step $n 14 $steps[$i] "iniciando"; switch ($i) {
            0 { cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null }
            1 { cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null }
            2 { RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null }
            3 { & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-Null }
            4 { & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-Null }
            5 { & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null }
            6 { & sfc.exe /scannow 2>&1 | Out-Null }
            7 { foreach ($d in @("atl.dll","urlmon.dll","mshtml.dll","actxprxy.dll","softpub.dll","wintrust.dll","oleaut32.dll","ole32.dll","shell32.dll","wuapi.dll")) { regsvr32.exe /s $d 2>&1 | Out-Null } }
            8 { netsh winsock reset 2>&1 | Out-Null }
            9 { ipconfig /flushdns 2>&1 | Out-Null }
            10 { netsh advfirewall set allprofiles state off 2>&1 | Out-Null }
            11 { net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\SoftwareDistribution`"" 2>&1 | Out-Null; net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null }
            12 { gpupdate /force 2>&1 | Out-Null }
            13 { Cleanmgr.exe /sagerun:64 2>&1 | Out-Null }
        }; W-Step $n 14 $steps[$i] "COMPLETADO" }; return $true
    }
    $global:CurrentJob = Start-Job -ScriptBlock $sb
    $global:RepairTimer = New-Object System.Windows.Forms.Timer; $global:RepairTimer.Interval = 2000
    $global:RepairTimer.Add_Tick({
        if ($global:LogTextBox -and !$global:LogTextBox.IsDisposed) { $global:LogTextBox.Text = Get-Content $global:LogFile -ErrorAction SilentlyContinue | Out-String; $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length; $global:LogTextBox.ScrollToCaret() }
        if ($global:CurrentJob.State -eq "Completed") { $global:RepairTimer.Stop(); Remove-Job $global:CurrentJob -Force; $global:CurrentJob = $null; $global:RepairRunning = $false; Write-Log "Reparación completada" "OK"; if ([System.Windows.Forms.MessageBox]::Show("¿Reiniciar ahora?", "Listo", "YesNo") -eq "Yes") { Restart-Computer -Force } }
    }); $global:RepairTimer.Start()
}

function Reset-WindowsUpdateOnly { Write-Log "Reiniciando WU..." "TASK"; net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; net stop cryptsvc 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\SoftwareDistribution`"" 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\system32\catroot2`"" 2>&1 | Out-Null; net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null; net start cryptsvc 2>&1 | Out-Null; Write-Log "Completado" "OK" }
function Create-RestorePoint { Write-Log "Creando punto..." "TASK"; Checkpoint-Computer -Description "Optimizer" -ErrorAction SilentlyContinue; Write-Log "Completado" "OK" }
function Kill-HungProcesses { Write-Log "Matando procesos..." "TASK"; if ($global:RepairTimer) { $global:RepairTimer.Stop(); $global:RepairTimer.Dispose() }; if ($global:CurrentJob) { Stop-Job $global:CurrentJob -ErrorAction SilentlyContinue; Remove-Job $global:CurrentJob -Force -ErrorAction SilentlyContinue; $global:CurrentJob = $null }; foreach ($p in @("dism","sfc","TiWorker","TrustedInstaller","OneDrive","winget")) { Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }; Write-Log "Completado" "OK" }
#endregion

#region INTERFAZ GRAFICA
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Form = New-Object System.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(680, 850)
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'Sizable'
$Form.MinimizeBox = $true; $Form.MaximizeBox = $true
$Form.Text = "SAMG27 Windows Optimizer v$global:ScriptVersion"
$Form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

$P1 = New-Object System.Windows.Forms.Panel; $P1.Location = New-Object System.Drawing.Point(10, 10); $P1.Size = New-Object System.Drawing.Size(660, 130)
$L1 = New-Object System.Windows.Forms.Label; $L1.Text = "ELIMINAR BLOATWARE"; $L1.Location = New-Object System.Drawing.Point(10, 5); $L1.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $L1.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $L1.AutoSize = $true
$B1 = New-Object System.Windows.Forms.Button; $B1.Text = "ELIMINAR TODO (Copilot, Xbox, Widgets)"; $B1.Location = New-Object System.Drawing.Point(5, 30); $B1.Size = New-Object System.Drawing.Size(650, 40); $B1.FlatStyle = 'Flat'; $B1.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B1.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B1.Add_Click({ Remove-AllBloatware })
$B2 = New-Object System.Windows.Forms.Button; $B2.Text = "DESINSTALAR ONEDRIVE"; $B2.Location = New-Object System.Drawing.Point(5, 80); $B2.Size = New-Object System.Drawing.Size(650, 35); $B2.FlatStyle = 'Flat'; $B2.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B2.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B2.Add_Click({ Remove-OneDrive })
$P1.Controls.AddRange(@($L1, $B1, $B2))

$P2 = New-Object System.Windows.Forms.Panel; $P2.Location = New-Object System.Drawing.Point(10, 150); $P2.Size = New-Object System.Drawing.Size(660, 220)
$L2 = New-Object System.Windows.Forms.Label; $L2.Text = "LIMPIEZA"; $L2.Location = New-Object System.Drawing.Point(10, 5); $L2.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $L2.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $L2.AutoSize = $true
$B3 = New-Object System.Windows.Forms.Button; $B3.Text = "LIMPIAR PERFIL ACTUAL"; $B3.Location = New-Object System.Drawing.Point(5, 35); $B3.Size = New-Object System.Drawing.Size(320, 35); $B3.FlatStyle = 'Flat'; $B3.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B3.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B3.Add_Click({ Clear-CurrentUserTemp })
$B4 = New-Object System.Windows.Forms.Button; $B4.Text = "LIMPIAR TODOS LOS PERFILES"; $B4.Location = New-Object System.Drawing.Point(330, 35); $B4.Size = New-Object System.Drawing.Size(325, 35); $B4.FlatStyle = 'Flat'; $B4.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B4.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B4.Add_Click({ Clear-AllUsersTemp })
$B5 = New-Object System.Windows.Forms.Button; $B5.Text = "LIMPIAR WINDOWS TEMP"; $B5.Location = New-Object System.Drawing.Point(5, 80); $B5.Size = New-Object System.Drawing.Size(320, 35); $B5.FlatStyle = 'Flat'; $B5.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B5.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B5.Add_Click({ Clear-WindowsTemp })
$B6 = New-Object System.Windows.Forms.Button; $B6.Text = "LIMPIAR CACHE INTERNET"; $B6.Location = New-Object System.Drawing.Point(330, 80); $B6.Size = New-Object System.Drawing.Size(325, 35); $B6.FlatStyle = 'Flat'; $B6.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B6.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B6.Add_Click({ Clear-InternetCache })
$B7 = New-Object System.Windows.Forms.Button; $B7.Text = "LIMPIEZA COMPLETA"; $B7.Location = New-Object System.Drawing.Point(5, 130); $B7.Size = New-Object System.Drawing.Size(650, 40); $B7.FlatStyle = 'Flat'; $B7.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#777777"); $B7.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B7.Add_Click({ Invoke-FullCleanup })
$P2.Controls.AddRange(@($L2, $B3, $B4, $B5, $B6, $B7))

$P3 = New-Object System.Windows.Forms.Panel; $P3.Location = New-Object System.Drawing.Point(10, 380); $P3.Size = New-Object System.Drawing.Size(660, 200)
$L3 = New-Object System.Windows.Forms.Label; $L3.Text = "INSTALAR APLICACIONES"; $L3.Location = New-Object System.Drawing.Point(10, 5); $L3.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $L3.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $L3.AutoSize = $true
$C1 = New-Object System.Windows.Forms.CheckBox; $C1.Text = "7-Zip"; $C1.Location = New-Object System.Drawing.Point(10, 40); $C1.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $C1.AutoSize = $true
$C2 = New-Object System.Windows.Forms.CheckBox; $C2.Text = "Chrome"; $C2.Location = New-Object System.Drawing.Point(100, 40); $C2.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $C2.AutoSize = $true
$C3 = New-Object System.Windows.Forms.CheckBox; $C3.Text = "Firefox"; $C3.Location = New-Object System.Drawing.Point(190, 40); $C3.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $C3.AutoSize = $true
$C4 = New-Object System.Windows.Forms.CheckBox; $C4.Text = "VLC"; $C4.Location = New-Object System.Drawing.Point(280, 40); $C4.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $C4.AutoSize = $true
$C5 = New-Object System.Windows.Forms.CheckBox; $C5.Text = "Teams (Web)"; $C5.Location = New-Object System.Drawing.Point(10, 70); $C5.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#ffcc88"); $C5.AutoSize = $true
$C6 = New-Object System.Windows.Forms.CheckBox; $C6.Text = "OneDrive (Directo)"; $C6.Location = New-Object System.Drawing.Point(200, 70); $C6.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#ffcc88"); $C6.AutoSize = $true
$B8 = New-Object System.Windows.Forms.Button; $B8.Text = "INSTALAR SELECCIONADAS"; $B8.Location = New-Object System.Drawing.Point(5, 130); $B8.Size = New-Object System.Drawing.Size(650, 45); $B8.FlatStyle = 'Flat'; $B8.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#33aa33"); $B8.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B8.Add_Click({
    $apps = @(); if ($C1.Checked) { $apps += "7zip" }; if ($C2.Checked) { $apps += "Chrome" }; if ($C3.Checked) { $apps += "Firefox" }; if ($C4.Checked) { $apps += "VLC" }
    if ($apps.Count -gt 0) { Install-Apps -Apps $apps }; if ($C6.Checked) { Install-OneDrive }; if ($C5.Checked) { Start-Process "https://www.microsoft.com/es-mx/microsoft-teams/download-app" }
    $C1.Checked = $false; $C2.Checked = $false; $C3.Checked = $false; $C4.Checked = $false; $C5.Checked = $false; $C6.Checked = $false
})
$P3.Controls.AddRange(@($L3, $C1, $C2, $C3, $C4, $C5, $C6, $B8))

$P4 = New-Object System.Windows.Forms.Panel; $P4.Location = New-Object System.Drawing.Point(10, 590); $P4.Size = New-Object System.Drawing.Size(660, 130)
$L4 = New-Object System.Windows.Forms.Label; $L4.Text = "HERRAMIENTAS"; $L4.Location = New-Object System.Drawing.Point(10, 5); $L4.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $L4.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $L4.AutoSize = $true
$B9 = New-Object System.Windows.Forms.Button; $B9.Text = "OPTIMIZAR"; $B9.Location = New-Object System.Drawing.Point(5, 35); $B9.Size = New-Object System.Drawing.Size(155, 35); $B9.FlatStyle = 'Flat'; $B9.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B9.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B9.Add_Click({ Optimize-System })
$B10 = New-Object System.Windows.Forms.Button; $B10.Text = "REPARAR (14)"; $B10.Location = New-Object System.Drawing.Point(168, 35); $B10.Size = New-Object System.Drawing.Size(155, 35); $B10.FlatStyle = 'Flat'; $B10.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B10.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B10.Add_Click({ if (-not $global:RepairRunning) { Start-RepairJob } })
$B11 = New-Object System.Windows.Forms.Button; $B11.Text = "FIREWALL OFF"; $B11.Location = New-Object System.Drawing.Point(331, 35); $B11.Size = New-Object System.Drawing.Size(155, 35); $B11.FlatStyle = 'Flat'; $B11.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B11.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B11.Add_Click({ Disable-Firewall })
$B12 = New-Object System.Windows.Forms.Button; $B12.Text = "RESET WU"; $B12.Location = New-Object System.Drawing.Point(494, 35); $B12.Size = New-Object System.Drawing.Size(155, 35); $B12.FlatStyle = 'Flat'; $B12.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B12.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B12.Add_Click({ Reset-WindowsUpdateOnly })
$B13 = New-Object System.Windows.Forms.Button; $B13.Text = "PTO RESTAURACION"; $B13.Location = New-Object System.Drawing.Point(5, 80); $B13.Size = New-Object System.Drawing.Size(320, 35); $B13.FlatStyle = 'Flat'; $B13.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B13.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B13.Add_Click({ Create-RestorePoint })
$B14 = New-Object System.Windows.Forms.Button; $B14.Text = "LIMPIEZA DISCO AVANZADA"; $B14.Location = New-Object System.Drawing.Point(330, 80); $B14.Size = New-Object System.Drawing.Size(325, 35); $B14.FlatStyle = 'Flat'; $B14.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $B14.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B14.Add_Click({ Run-DiskCleanup })
$P4.Controls.AddRange(@($L4, $B9, $B10, $B11, $B12, $B13, $B14))

$B15 = New-Object System.Windows.Forms.Button; $B15.Text = "TERMINAR PROCESOS BLOQUEADOS"; $B15.Location = New-Object System.Drawing.Point(10, 730); $B15.Size = New-Object System.Drawing.Size(660, 40); $B15.FlatStyle = 'Flat'; $B15.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#aa6633"); $B15.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B15.Add_Click({ Kill-HungProcesses })

$B16 = New-Object System.Windows.Forms.Button; $B16.Text = "CERRAR PROGRAMA"; $B16.Location = New-Object System.Drawing.Point(10, 780); $B16.Size = New-Object System.Drawing.Size(660, 35); $B16.FlatStyle = 'Flat'; $B16.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#aa3333"); $B16.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $B16.Add_Click({ $Form.Close() })

$global:LogTextBox = New-Object System.Windows.Forms.RichTextBox; $global:LogTextBox.Location = New-Object System.Drawing.Point(10, 825); $global:LogTextBox.Size = New-Object System.Drawing.Size(660, 100); $global:LogTextBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1a1a1a"); $global:LogTextBox.ForeColor = [System.Drawing.Color]::LightGreen; $global:LogTextBox.Font = New-Object System.Drawing.Font("Consolas", 8); $global:LogTextBox.ReadOnly = $true

$Form.Controls.AddRange(@($P1, $P2, $P3, $P4, $B15, $B16, $global:LogTextBox))

Write-Log "Optimizer v$global:ScriptVersion cargado" "INFO"
Write-Log "Sistema: $global:WindowsVersion" "INFO"
Write-Log "Listo para usar." "OK"

[void]$Form.ShowDialog()
#endregion
