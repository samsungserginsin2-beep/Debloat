<#
.SYNOPSIS
    Windows 10/11 SAMG27 Windows Optimizer v6.9
#>

$ErrorActionPreference = 'Continue'
$global:ScriptVersion = "6.9"
$global:LogTextBox = $null
$global:CurrentJob = $null
$global:RepairRunning = $false
$global:RepairTimer = $null
$global:InstallRunning = $false

# --- ELEVACION ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Solicitando permisos de administrador..." -ForegroundColor Yellow
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    Start-Process powershell -ArgumentList $args -Verb RunAs
    exit
}

# --- VARIABLES GLOBALES ---
$global:LogDir = "$env:TEMP\WindowsOptimizer"
$global:LogFile = "$global:LogDir\optimizer_log.txt"
if (!(Test-Path $global:LogDir)) { New-Item -Path $global:LogDir -ItemType Directory -Force | Out-Null }
if (Test-Path $global:LogFile) { Remove-Item $global:LogFile -Force }

$global:WingetAvailable = $false
if (Get-Command winget -ErrorAction SilentlyContinue) { $global:WingetAvailable = $true }
$global:Is24H2 = [Environment]::OSVersion.Version.Build -ge 26100

$global:Bloatware = @("Microsoft.BingNews", "Microsoft.BingWeather", "Microsoft.GetHelp", "Microsoft.Getstarted", "Microsoft.Microsoft3DViewer", "Microsoft.MicrosoftOfficeHub", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.MixedReality.Portal", "Microsoft.Office.OneNote", "Microsoft.People", "Microsoft.Print3D", "Microsoft.SkypeApp", "Microsoft.WindowsAlarms", "Microsoft.WindowsFeedbackHub", "Microsoft.WindowsMaps", "Microsoft.WindowsSoundRecorder", "Microsoft.YourPhone", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo", "Microsoft.Todos", "Microsoft.Windows.DevHome", "Microsoft.PowerAutomateDesktop", "Clipchamp.Clipchamp", "Microsoft.Xbox.TCUI", "Microsoft.XboxApp", "Microsoft.XboxGameOverlay", "Microsoft.XboxGamingOverlay", "Microsoft.XboxIdentityProvider", "Microsoft.XboxSpeechToTextOverlay", "CandyCrush", "Facebook", "Twitter", "Spotify", "Netflix", "Disney", "Microsoft.Windows.WebExperiencePack", "MicrosoftWindows.Client.WebExperience")
if ($global:Is24H2) { $global:Bloatware += @("Microsoft.Windows.AI.Copilot", "Microsoft.Copilot", "Microsoft.Windows.Recall") }
$global:BloatwareRegex = $global:Bloatware -join '|'

# --- FUNCIONES LOG ---
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

# --- FUNCIONES DE ACCION ---
function Clear-Temp {
    Write-Log "Limpiando archivos temporales..." "TASK"
    cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null
    cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null
    Write-Log "Limpieza completada." "OK"
}

function Remove-Bloatware {
    Write-Log "Eliminando bloatware..." "TASK"
    $removed = 0
    Get-AppxPackage | Where-Object { $_.Name -match $global:BloatwareRegex } | ForEach-Object {
        try { Remove-AppxPackage -Package $_ -ErrorAction SilentlyContinue; $removed++; Write-Log "Eliminado: $($_.Name)" "OK" } catch {}
    }
    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $global:BloatwareRegex } | ForEach-Object {
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue } catch {}
    }
    $telemetryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    if (!(Test-Path $telemetryPath)) { New-Item -Path $telemetryPath -Force | Out-Null }
    Set-ItemProperty -Path $telemetryPath -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
    Write-Log "Bloatware eliminado. ($removed apps)" "OK"
}

function Disable-Firewall {
    Write-Log "Deshabilitando Firewall..." "TASK"
    netsh advfirewall set domainprofile state off 2>&1 | Out-Null
    netsh advfirewall set privateprofile state off 2>&1 | Out-Null
    netsh advfirewall set publicprofile state off 2>&1 | Out-Null
    Write-Log "Firewall deshabilitado." "OK"
}

function Repair-System {
    Write-Log "Iniciando reparación (14 pasos)..." "TASK"
    $global:RepairRunning = $true
    $sb = {
        $log = "$env:TEMP\WindowsOptimizer\optimizer_log.txt"
        $steps = @(
            "Limpiar Temp usuario", "Limpiar Windows Temp", "Limpiar Cache Internet", 
            "DISM CheckHealth", "DISM ScanHealth", "DISM RestoreHealth", 
            "SFC Scannow", "Registrar DLLs", "Resetear Winsock", 
            "Limpiar Cache DNS", "Deshabilitar Firewall", "Limpiar Cache WU", 
            "Actualizar Politicas", "Limpieza de Disco"
        )
        for ($i=0; $i -lt $steps.Count; $i++) {
            $n = $i + 1
            $t = Get-Date -Format "HH:mm:ss"
            Add-Content -Path $log -Value "[$t] [PASO $n/14] $($steps[$i]) - iniciando"
            
            switch ($i) {
                0 { cmd /c "del /f /s /q `"$env:USERPROFILE\AppData\Local\Temp\*`"" 2>&1 | Out-Null }
                1 { cmd /c "del /f /s /q C:\Windows\Temp\*" 2>&1 | Out-Null }
                2 { RunDll32.exe InetCpl.cpl,ClearMyTracksByProcess 8 2>&1 | Out-Null }
                3 { & dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-Null }
                4 { & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-Null }
                5 { & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-Null }
                6 { & sfc.exe /scannow 2>&1 | Out-Null }
                7 { foreach ($d in @("atl.dll", "urlmon.dll", "mshtml.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "oleaut32.dll", "ole32.dll", "shell32.dll", "wuapi.dll")) { regsvr32.exe /s $d 2>&1 | Out-Null } }
                8 { netsh winsock reset 2>&1 | Out-Null }
                9 { ipconfig /flushdns 2>&1 | Out-Null }
                10 { netsh advfirewall set allprofiles state off 2>&1 | Out-Null }
                11 { net stop bits 2>&1 | Out-Null; net stop wuauserv 2>&1 | Out-Null; cmd /c "rmdir /s /q `"$env:SystemRoot\SoftwareDistribution`"" 2>&1 | Out-Null; net start bits 2>&1 | Out-Null; net start wuauserv 2>&1 | Out-Null }
                12 { gpupdate /force 2>&1 | Out-Null }
                13 { Cleanmgr.exe /sagerun:64 2>&1 | Out-Null }
            }
            $t = Get-Date -Format "HH:mm:ss"
            Add-Content -Path $log -Value "[$t] [PASO $n/14] $($steps[$i]) - COMPLETADO"
        }
        return $true
    }
    $global:CurrentJob = Start-Job -ScriptBlock $sb
    $global:RepairTimer = New-Object System.Windows.Forms.Timer
    $global:RepairTimer.Interval = 2000
    $global:RepairTimer.Add_Tick({
        if ($global:LogTextBox -and !$global:LogTextBox.IsDisposed) {
            $global:LogTextBox.Text = Get-Content -Path $global:LogFile -ErrorAction SilentlyContinue | Out-String
            $global:LogTextBox.SelectionStart = $global:LogTextBox.Text.Length
            $global:LogTextBox.ScrollToCaret()
        }
        if ($global:CurrentJob.State -eq "Completed") {
            $global:RepairTimer.Stop(); Remove-Job -Job $global:CurrentJob -Force; $global:CurrentJob = $null; $global:RepairRunning = $false
            Write-Log "Reparación completada." "OK"
        }
    })
    $global:RepairTimer.Start()
}

# --- INTERFAZ GRAFICA ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Form = New-Object System.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(680, 750) # Altura ajustada
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'Sizable' # ERROR CORREGIDO AQUI (antes tenias 'Sizable'')
$Form.MinimizeBox = $true
$Form.MaximizeBox = $true
$Form.Text = "SAMG27 Windows Optimizer v$global:ScriptVersion"
$Form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252525")

# Panel Debloat
$Panel1 = New-Object System.Windows.Forms.Panel; $Panel1.Location = New-Object System.Drawing.Point(10, 10); $Panel1.Size = New-Object System.Drawing.Size(660, 100)
$Lbl1 = New-Object System.Windows.Forms.Label; $Lbl1.Text = "BLOATWARE"; $Lbl1.Location = New-Object System.Drawing.Point(10, 5); $Lbl1.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $Lbl1.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $Lbl1.AutoSize = $true
$BtnBloat = New-Object System.Windows.Forms.Button; $BtnBloat.Text = "ELIMINAR TODO (Copilot, Xbox, Widgets)"; $BtnBloat.Location = New-Object System.Drawing.Point(5, 30); $BtnBloat.Size = New-Object System.Drawing.Size(650, 40); $BtnBloat.FlatStyle = 'Flat'; $BtnBloat.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $BtnBloat.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $BtnBloat.Add_Click({ Remove-Bloatware })
$Panel1.Controls.AddRange(@($Lbl1, $BtnBloat))

# Panel Limpieza
$Panel2 = New-Object System.Windows.Forms.Panel; $Panel2.Location = New-Object System.Drawing.Point(10, 120); $Panel2.Size = New-Object System.Drawing.Size(660, 100)
$Lbl2 = New-Object System.Windows.Forms.Label; $Lbl2.Text = "LIMPIEZA"; $Lbl2.Location = New-Object System.Drawing.Point(10, 5); $Lbl2.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $Lbl2.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $Lbl2.AutoSize = $true
$BtnClean = New-Object System.Windows.Forms.Button; $BtnClean.Text = "LIMPIAR ARCHIVOS TEMPORALES"; $BtnClean.Location = New-Object System.Drawing.Point(5, 30); $BtnClean.Size = New-Object System.Drawing.Size(650, 40); $BtnClean.FlatStyle = 'Flat'; $BtnClean.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $BtnClean.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $BtnClean.Add_Click({ Clear-Temp })
$Panel2.Controls.AddRange(@($Lbl2, $BtnClean))

# Panel Herramientas
$Panel3 = New-Object System.Windows.Forms.Panel; $Panel3.Location = New-Object System.Drawing.Point(10, 230); $Panel3.Size = New-Object System.Drawing.Size(660, 100)
$Lbl3 = New-Object System.Windows.Forms.Label; $Lbl3.Text = "HERRAMIENTAS"; $Lbl3.Location = New-Object System.Drawing.Point(10, 5); $Lbl3.Font = New-Object System.Drawing.Font('Consolas', 12, [System.Drawing.FontStyle]::Bold); $Lbl3.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $Lbl3.AutoSize = $true
$BtnFirewall = New-Object System.Windows.Forms.Button; $BtnFirewall.Text = "DESHABILITAR FIREWALL"; $BtnFirewall.Location = New-Object System.Drawing.Point(5, 30); $BtnFirewall.Size = New-Object System.Drawing.Size(320, 40); $BtnFirewall.FlatStyle = 'Flat'; $BtnFirewall.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $BtnFirewall.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $BtnFirewall.Add_Click({ Disable-Firewall })
$BtnRepair = New-Object System.Windows.Forms.Button; $BtnRepair.Text = "REPARAR (14 PASOS)"; $BtnRepair.Location = New-Object System.Drawing.Point(335, 30); $BtnRepair.Size = New-Object System.Drawing.Size(320, 40); $BtnRepair.FlatStyle = 'Flat'; $BtnRepair.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#555555"); $BtnRepair.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $BtnRepair.Add_Click({ if (-not $global:RepairRunning) { Repair-System } })
$Panel3.Controls.AddRange(@($Lbl3, $BtnFirewall, $BtnRepair))

# Boton Cerrar
$BtnClose = New-Object System.Windows.Forms.Button; $BtnClose.Text = "CERRAR PROGRAMA"; $BtnClose.Location = New-Object System.Drawing.Point(10, 340); $BtnClose.Size = New-Object System.Drawing.Size(660, 40); $BtnClose.FlatStyle = 'Flat'; $BtnClose.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#aa3333"); $BtnClose.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#eeeeee"); $BtnClose.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold); $BtnClose.Add_Click({ $Form.Close() })

# Caja de Log
$global:LogTextBox = New-Object System.Windows.Forms.RichTextBox
$global:LogTextBox.Location = New-Object System.Drawing.Point(10, 390)
$global:LogTextBox.Size = New-Object System.Drawing.Size(660, 350)
$global:LogTextBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1a1a1a")
$global:LogTextBox.ForeColor = [System.Drawing.Color]::LightGreen
$global:LogTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$global:LogTextBox.ReadOnly = $true
$global:LogTextBox.ScrollBars = 'Vertical'

$Form.Controls.AddRange(@($Panel1, $Panel2, $Panel3, $BtnClose, $global:LogTextBox))

Write-Log "Optimizer v$global:ScriptVersion cargado." "INFO"
Write-Log "Listo para usar." "OK"

[void]$Form.ShowDialog()