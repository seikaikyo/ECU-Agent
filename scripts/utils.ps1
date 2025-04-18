# 共用函數庫 (Windows PowerShell 版)

# 顯示彩色訊息
function Write-Info {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warning {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Title {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Title
    )
    
    $Line = "=" * 55
    Write-Host "`n$Line" -ForegroundColor Blue
    Write-Host "  $Title  " -ForegroundColor Blue
    Write-Host "$Line`n" -ForegroundColor Blue
}

# 檢查命令是否存在
function Test-CommandExists {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Command
    )
    
    $Exists = $false
    try {
        if (Get-Command $Command -ErrorAction SilentlyContinue) {
            $Exists = $true
            Write-Info "$Command 已安裝"
        } else {
            Write-Warning "$Command 未安裝"
        }
    } catch {
        Write-Warning "$Command 未安裝"
    }
    
    return $Exists
}

# 檢查 Python 套件
function Test-PythonPackage {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Package
    )
    
    $Exists = $false
    try {
        # 使用 pip 檢查包是否安裝
        $Result = python -c "import $Package; print('OK')" 2>$null
        if ($Result -eq "OK") {
            $Exists = $true
            Write-Info "已安裝 Python 套件: $Package"
        } else {
            Write-Warning "缺少 Python 套件: $Package"
        }
    } catch {
        Write-Warning "缺少 Python 套件: $Package"
    }
    
    return $Exists
}

# 檢測設備 IP 地址
function Detect-DeviceIP {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JsonFile
    )
    
    $HostIPs = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" }).IPAddress
    
    try {
        $Devices = Get-Content $JsonFile -Raw | ConvertFrom-Json
        
        for ($i = 0; $i -lt $Devices.devices.Count; $i++) {
            $PrimaryIP = $Devices.devices[$i].primary_ip
            $BackupIP = $Devices.devices[$i].backup_ip
            
            if ($HostIPs -contains $PrimaryIP -or $HostIPs -contains $BackupIP) {
                $DeviceID = $i + 1
                $DeviceName = $Devices.devices[$i].name
                return "$DeviceID`:$DeviceName"
            }
        }
    } catch {
        Write-Error "解析 JSON 文件失敗: $_"
    }
    
    return $null
}

# 從 devices.json 中提取單個設備配置
function Extract-DeviceConfig {
    param (
        [Parameter(Mandatory=$true)]
        [string]$JsonFile,
        
        [Parameter(Mandatory=$true)]
        [int]$DeviceIndex,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputFile
    )
    
    try {
        $Devices = Get-Content $JsonFile -Raw | ConvertFrom-Json
        $DeviceConfig = $Devices.devices[$DeviceIndex - 1]
        
        $DeviceConfig | ConvertTo-Json -Depth 10 | Out-File $OutputFile -Encoding utf8
        Write-Info "已提取設備配置到: $OutputFile"
        return $true
    } catch {
        Write-Error "提取設備配置失敗: $_"
        return $false
    }
}

# 保存配置到環境文件
function Save-ConfigEnv {
    param (
        [Parameter(Mandatory=$true)]
        [string]$DeviceID,
        
        [Parameter(Mandatory=$true)]
        [string]$ConfigFile,
        
        [Parameter(Mandatory=$true)]
        [string]$ServerIP,
        
        [Parameter(Mandatory=$true)]
        [string]$PushGateway,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [int]$Interval
    )
    
    $OutputDir = "config"
    if (-not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }
    
    $EnvContent = @"
# Modbus 收集代理配置
# 生成於 $(Get-Date)

# 設備信息
DEVICE_ID="$DeviceID"
DEVICE_CONFIG="$ConfigFile"

# 伺服器信息
SERVER_IP="$ServerIP"
PUSH_GATEWAY="$PushGateway"

# 運行配置
LOCAL_PORT=$Port
INTERVAL=$Interval
"@
    
    $EnvContent | Out-File "$OutputDir\agent_config.env" -Encoding utf8
    Write-Info "已保存配置到: $OutputDir\agent_config.env"
    return $true
}

# 建立啟動批處理文件
function Create-StartBatch {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ConfigFile,
        
        [Parameter(Mandatory=$true)]
        [string]$PointsFile,
        
        [Parameter(Mandatory=$true)]
        [string]$PushGateway,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [int]$Interval
    )
    
    $BatchContent = @"
@echo off
python collector-agent.py --config "$ConfigFile" --points "$PointsFile" --push-gateway "$PushGateway" --port "$Port" --interval "$Interval" > logs\collector_%date:~0,4%%date:~5,2%%date:~8,2%.log 2>&1
echo 收集代理已啟動
"@
    
    $BatchContent | Out-File "start_service.bat" -Encoding utf8
    Write-Info "已建立啟動批處理文件: start_service.bat"
    return $true
}

# 建立 PowerShell 啟動腳本
function Create-StartPS {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ConfigFile,
        
        [Parameter(Mandatory=$true)]
        [string]$PointsFile,
        
        [Parameter(Mandatory=$true)]
        [string]$PushGateway,
        
        [Parameter(Mandatory=$true)]
        [int]$Port,
        
        [Parameter(Mandatory=$true)]
        [int]$Interval
    )
    
    $CurrentPath = (Get-Location).Path
    $LogFile = "$CurrentPath\logs\collector_$(Get-Date -Format 'yyyyMMdd').log"
    
    $PSContent = @"
# 收集代理啟動腳本
# 生成於 $(Get-Date)
`$ErrorActionPreference = "Stop"

# 確保日誌目錄存在
if (-not (Test-Path "$CurrentPath\logs")) {
    New-Item -Path "$CurrentPath\logs" -ItemType Directory | Out-Null
}

# 啟動收集進程
try {
    Start-Transcript -Path "$LogFile" -Append
    Write-Host "開始執行 Modbus 收集代理 ($(Get-Date))"
    python "$CurrentPath\collector-agent.py" --config "$ConfigFile" --points "$PointsFile" --push-gateway "$PushGateway" --port "$Port" --interval "$Interval"
} catch {
    Write-Error `$_
} finally {
    Stop-Transcript
}
"@
    
    $PSContent | Out-File "start_service.ps1" -Encoding utf8
    Write-Info "已建立 PowerShell 啟動腳本: start_service.ps1"
    return $true
}

# 安裝 Windows 服務
function Install-WindowsService {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory=$true)]
        [string]$BinaryPath,
        
        [Parameter(Mandatory=$true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory=$true)]
        [string]$Description
    )
    
    # 檢查是否以管理員權限運行
    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $IsAdmin) {
        Write-Error "需要管理員權限來安裝服務"
        return $false
    }
    
    # 如果服務已存在，先移除
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        try {
            Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
            $ServiceObj = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'"
            if ($ServiceObj -ne $null) {
                $ServiceObj.delete()
            }
            Write-Info "已移除舊服務: $ServiceName"
        } catch {
            Write-Error "移除舊服務失敗: $_"
            return $false
        }
    }
    
    # 創建新服務
    try {
        $nssmPath = "C:\Program Files\nssm\nssm.exe"
        
        if (Test-Path $nssmPath) {
            # 使用 NSSM (如果已安裝)
            Write-Info "使用 NSSM 安裝服務..."
            & $nssmPath install $ServiceName powershell.exe
            & $nssmPath set $ServiceName AppParameters "-NoProfile -ExecutionPolicy Bypass -File `"$BinaryPath`""
            & $nssmPath set $ServiceName DisplayName $DisplayName
            & $nssmPath set $ServiceName Description $Description
            & $nssmPath set $ServiceName Start SERVICE_AUTO_START
        } else {
            # 使用原生服務命令
            Write-Info "使用原生方式安裝服務..."
            New-Service -Name $ServiceName -BinaryPathName "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$BinaryPath`"" -DisplayName $DisplayName -Description $Description -StartupType Automatic
        }
        
        # 啟動服務
        Start-Service $ServiceName
        Write-Info "服務已安裝並啟動: $ServiceName"
        return $true
    } catch {
        Write-Error "安裝服務失敗: $_"
        return $false
    }
}

# 安裝計劃任務 (替代服務)
function Install-ScheduledTask {
    param (
        [Parameter(Mandatory=$true)]
        [string]$TaskName,
        
        [Parameter(Mandatory=$true)]
        [string]$ScriptPath,
        
        [Parameter(Mandatory=$true)]
        [string]$WorkingDir,
        
        [Parameter(Mandatory=$true)]
        [string]$Description
    )
    
    try {
        $TaskPath = "\ModbusAgent\"
        
        # 刪除已存在的任務
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        
        # 創建任務
        $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -WorkingDirectory $WorkingDir
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Password -RunLevel Highest
        
        # 創建任務
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description $Description
        
        # 啟動任務
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        Write-Info "計劃任務已創建並啟動: $TaskPath$TaskName"
        return $true
    } catch {
        Write-Error "創建計劃任務失敗: $_"
        return $false
    }
}

# 安裝啟動項 (最後備選方案)
function Install-StartupItem {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Name,
        
        [Parameter(Mandatory=$true)]
        [string]$ScriptPath,
        
        [Parameter(Mandatory=$true)]
        [string]$WorkingDir
    )
    
    try {
        $StartupFolder = [System.Environment]::GetFolderPath("Startup")
        $ShortcutPath = Join-Path $StartupFolder "$Name.lnk"
        
        $WScriptShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $Shortcut.WorkingDirectory = $WorkingDir
        $Shortcut.Save()
        
        Write-Info "已創建啟動項: $ShortcutPath"
        return $true
    } catch {
        Write-Error "創建啟動項失敗: $_"
        return $false
    }
}

# 檢查 Python 環境
function Check-PythonEnvironment {
    # 檢查是否已安裝 Python
    if (-not (Test-CommandExists "python")) {
        Write-Error "Python 未安裝，請先安裝 Python 3.8 或更高版本"
        return $false
    }
    
    # 檢查 Python 版本
    $PythonVersion = (python --version) 2>&1
    if ($PythonVersion -match "Python ([0-9]+)\.([0-9]+)") {
        $MajorVersion = [int]$Matches[1]
        $MinorVersion = [int]$Matches[2]
        
        if ($MajorVersion -lt 3 -or ($MajorVersion -eq 3 -and $MinorVersion -lt 8)) {
            Write-Warning "Python 版本過低: $PythonVersion，建議升級到 Python 3.8 或更高版本"
        } else {
            Write-Info "Python 版本: $PythonVersion"
        }
    }
    
    # 檢查 Python 套件
    $MissingPackages = @()
    
    if (-not (Test-PythonPackage "pymodbus")) {
        $MissingPackages += "pymodbus"
    }
    
    if (-not (Test-PythonPackage "prometheus_client")) {
        $MissingPackages += "prometheus-client"
    }
    
    if (-not (Test-PythonPackage "requests")) {
        $MissingPackages += "requests"
    }
    
    # 如果有缺少的套件，提示安裝
    if ($MissingPackages.Count -gt 0) {
        Write-Warning "缺少以下 Python 套件: $($MissingPackages -join ', ')"
        $Install = Read-Host "是否安裝這些套件? (y/n)"
        
        if ($Install -match "^[Yy]") {
            Write-Info "正在安裝 Python 套件..."
            pip install $MissingPackages
            Write-Info "Python 套件安裝完成"
        } else {
            Write-Warning "跳過安裝 Python 套件，代理可能無法正常運行"
            return $false
        }
    }
    
    return $true
}
