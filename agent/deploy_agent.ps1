# Modbus 收集代理自動部署腳本 (Windows 版)
# 專為 CI/CD 環境設計，支援命令行參數和非互動式運行

# 顯示說明
function Show-Help {
    Write-Host "用法: .\deploy_agent.ps1 [選項]"
    Write-Host
    Write-Host "選項:"
    Write-Host "  -Device ID        設備識別號或配置文件名 (必要)"
    Write-Host "  -ServerIP IP      中央伺服器IP地址 (必要)"
    Write-Host "  -Port PORT        本地HTTP服務埠 (預設: 8000，設為0禁用)"
    Write-Host "  -Interval SEC     數據收集間隔，單位為秒 (預設: 5)"
    Write-Host "  -AutoStart MODE   自動啟動方式 (service 或 task，預設: service)"
    Write-Host "  -JsonFile FILE    設備配置JSON檔案 (預設: devices.json)"
    Write-Host "  -Help             顯示此幫助信息"
    Write-Host
    Write-Host "範例:"
    Write-Host "  .\deploy_agent.ps1 -Device 1 -ServerIP 192.168.1.100"
    Write-Host "  .\deploy_agent.ps1 -Device ecu1051_1 -ServerIP 10.0.0.1 -Port 9000 -Interval 10"
    Write-Host
}

# 預設值
$LOCAL_PORT = 8000
$INTERVAL = 5
$AUTOSTART = "service"
$DEVICES_JSON = "devices.json"

# 解析命令行參數
param(
    [Parameter(Mandatory=$false)][string]$Device,
    [Parameter(Mandatory=$false)][string]$ServerIP,
    [Parameter(Mandatory=$false)][int]$Port = $LOCAL_PORT,
    [Parameter(Mandatory=$false)][int]$Interval = $INTERVAL,
    [Parameter(Mandatory=$false)][string]$AutoStart = $AUTOSTART,
    [Parameter(Mandatory=$false)][string]$JsonFile = $DEVICES_JSON,
    [Parameter(Mandatory=$false)][switch]$Help
)

# 如果請求幫助或缺少必要參數則顯示幫助
if ($Help -or [string]::IsNullOrEmpty($Device) -or [string]::IsNullOrEmpty($ServerIP)) {
    Show-Help
    exit
}

# 設定日誌輸出
$LOG_DIR = "logs"
if (-not (Test-Path $LOG_DIR)) {
    New-Item -Path $LOG_DIR -ItemType Directory | Out-Null
}
$LOG_FILE = "$LOG_DIR\deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# 開始記錄日誌
Start-Transcript -Path $LOG_FILE -Append

Write-Host "=== 開始部署 Modbus 收集代理 $(Get-Date) ==="
Write-Host "設備: $Device"
Write-Host "伺服器: $ServerIP"
Write-Host "本地埠: $Port"
Write-Host "收集間隔: $Interval 秒"
Write-Host "自動啟動方式: $AutoStart"
Write-Host "設備配置檔: $JsonFile"

# 設置推送網關
$PUSH_GATEWAY = "http://${ServerIP}:9091"

# 安裝必要的 Python 依賴
Write-Host "=== 安裝 Python 依賴 ==="
pip install pymodbus prometheus-client requests

# 配置文件處理
$CONFIG_DIR = "config"
if (-not (Test-Path $CONFIG_DIR)) {
    New-Item -Path $CONFIG_DIR -ItemType Directory | Out-Null
}

# 根據設備ID或名稱提取配置
$DEVICE_CONFIG_FILE = ""
$DEVICE_ID = ""

# 提取設備配置
if ($Device -match "device-.*\.json" -and (Test-Path $Device)) {
    # 如果 Device 參數指向已存在的配置文件
    Write-Host "使用現有配置文件: $Device"
    $DEVICE_CONFIG_FILE = $Device
    
    # 嘗試提取設備ID (如果能解析 JSON)
    try {
        $DeviceContent = Get-Content $DEVICE_CONFIG_FILE -Raw | ConvertFrom-Json
        $DEVICE_ID = $DeviceContent.id
    } catch {
        Write-Warning "無法從配置文件讀取設備ID"
    }
} elseif ($Device -match "^\d+$" -and (Test-Path $JsonFile)) {
    # 如果 Device 是數字，從 JSON 檔案中提取對應索引的設備
    try {
        $DevicesContent = Get-Content $JsonFile -Raw | ConvertFrom-Json
        $DeviceIndex = [int]$Device - 1
        
        if ($DeviceIndex -ge 0 -and $DeviceIndex -lt $DevicesContent.devices.Count) {
            Write-Host "從 $JsonFile 提取設備 #$Device 的配置"
            $DeviceConfig = $DevicesContent.devices[$DeviceIndex]
            $DEVICE_ID = $DeviceConfig.id
            $DEVICE_CONFIG_FILE = "device-$Device.json"
            $DeviceConfig | ConvertTo-Json -Depth 10 | Out-File $DEVICE_CONFIG_FILE -Encoding utf8
            Write-Host "已創建設備配置文件: $DEVICE_CONFIG_FILE"
        } else {
            Write-Error "錯誤: 無效的設備索引 $Device (範圍: 1-$($DevicesContent.devices.Count))"
            exit 1
        }
    } catch {
        Write-Error "錯誤: 解析 JSON 文件失敗: $_"
        exit 1
    }
} else {
    # 嘗試直接使用 Device 作為設備 ID 從 JSON 中尋找匹配
    if (Test-Path $JsonFile) {
        try {
            $DevicesContent = Get-Content $JsonFile -Raw | ConvertFrom-Json
            $DeviceFound = $false
            
            for ($i = 0; $i -lt $DevicesContent.devices.Count; $i++) {
                if ($DevicesContent.devices[$i].id -eq $Device) {
                    Write-Host "使用設備 ID: $Device"
                    $DeviceConfig = $DevicesContent.devices[$i]
                    $DEVICE_CONFIG_FILE = "device-$Device.json"
                    $DeviceConfig | ConvertTo-Json -Depth 10 | Out-File $DEVICE_CONFIG_FILE -Encoding utf8
                    $DEVICE_ID = $Device
                    $DeviceFound = $true
                    Write-Host "已創建設備配置文件: $DEVICE_CONFIG_FILE"
                    break
                }
            }
            
            if (-not $DeviceFound) {
                Write-Error "錯誤: 在 $JsonFile 中找不到 ID 為 $Device 的設備"
                exit 1
            }
        } catch {
            Write-Error "錯誤: 處理 JSON 文件失敗: $_"
            exit 1
        }
    } else {
        Write-Error "錯誤: 無法處理設備配置"
        exit 1
    }
}

if ([string]::IsNullOrEmpty($DEVICE_CONFIG_FILE) -or -not (Test-Path $DEVICE_CONFIG_FILE)) {
    Write-Error "錯誤: 無法建立或找到設備配置文件"
    exit 1
}

# 確保 PLC 點位文件存在
if (-not (Test-Path "plc_points.json")) {
    Write-Error "錯誤: 找不到 plc_points.json 文件"
    exit 1
}

# 確保代理程式存在
if (-not (Test-Path "collector-agent.py")) {
    Write-Error "錯誤: 找不到 collector-agent.py 文件"
    exit 1
}

# 記錄配置到 .env 文件
Write-Host "=== 保存配置 ==="
$EnvContent = @"
# Modbus 收集代理配置
# 由自動部署腳本生成於 $(Get-Date)

# 設備信息
DEVICE_ID="$DEVICE_ID"
DEVICE_CONFIG="$DEVICE_CONFIG_FILE"

# 伺服器信息
SERVER_IP="$ServerIP"
PUSH_GATEWAY="$PUSH_GATEWAY"

# 運行配置
LOCAL_PORT=$Port
INTERVAL=$Interval
"@

if (-not (Test-Path "$CONFIG_DIR")) {
    New-Item -Path "$CONFIG_DIR" -ItemType Directory | Out-Null
}
$EnvContent | Out-File "$CONFIG_DIR\agent_config.env" -Encoding utf8
Write-Host "已保存配置到: $CONFIG_DIR\agent_config.env"

# 創建啟動批處理文件
Write-Host "=== 建立啟動腳本 ==="
$BatchContent = @"
@echo off
python collector-agent.py --config "$DEVICE_CONFIG_FILE" --points "plc_points.json" --push-gateway "$PUSH_GATEWAY" --port "$Port" --interval "$Interval" > logs\collector_%date:~0,4%%date:~5,2%%date:~8,2%.log 2>&1
echo 收集代理已啟動
"@
$BatchContent | Out-File "start_service.bat" -Encoding utf8
Write-Host "已建立啟動腳本: start_service.bat"

# 建立 PowerShell 腳本 (用於定時任務)
$PSContent = @"
# 收集代理啟動腳本
python `"$((Get-Location).Path)\collector-agent.py`" --config `"$DEVICE_CONFIG_FILE`" --points `"plc_points.json`" --push-gateway `"$PUSH_GATEWAY`" --port `"$Port`" --interval `"$Interval`"
"@
$PSContent | Out-File "start_service.ps1" -Encoding utf8
Write-Host "已建立 PowerShell 啟動腳本: start_service.ps1"

# 如果選擇服務啟動方式，建立 Windows 服務
if ($AutoStart -eq "service") {
    Write-Host "=== 配置 Windows 服務 ==="
    
    # 使用 NSSM (Non-Sucking Service Manager) 來安裝服務，需要事先安裝 NSSM
    # 檢查是否已安裝 NSSM
    $nssmPath = "C:\Program Files\nssm\nssm.exe"
    
    if (-not (Test-Path $nssmPath)) {
        Write-Warning "找不到 NSSM 工具，將使用計劃任務替代"
        $AutoStart = "task"
    } else {
        $ServiceName = "ModbusCollector"
        & $nssmPath install $ServiceName python
        & $nssmPath set $ServiceName AppParameters "`"$((Get-Location).Path)\collector-agent.py`" --config `"$DEVICE_CONFIG_FILE`" --points `"plc_points.json`" --push-gateway `"$PUSH_GATEWAY`" --port `"$Port`" --interval `"$Interval`""
        & $nssmPath set $ServiceName AppDirectory "$((Get-Location).Path)"
        & $nssmPath set $ServiceName DisplayName "Modbus 收集代理"
        & $nssmPath set $ServiceName Description "從 PLC 收集 Modbus 數據並發送到 Prometheus"
        & $nssmPath set $ServiceName Start SERVICE_AUTO_START
        & $nssmPath set $ServiceName AppStdout "$((Get-Location).Path)\logs\service_stdout.log"
        & $nssmPath set $ServiceName AppStderr "$((Get-Location).Path)\logs\service_stderr.log"
        
        # 啟動服務
        Start-Service $ServiceName
        Write-Host "服務已創建並啟動: $ServiceName"
    }
}

# 如果選擇定時任務啟動方式，或 NSSM 不可用
if ($AutoStart -eq "task") {
    Write-Host "=== 配置計劃任務 ==="
    
    $TaskName = "ModbusCollector"
    $TaskPath = "\ModbusAgent\"
    
    # 刪除已存在的任務
    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    
    # 創建任務
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$((Get-Location).Path)\start_service.ps1`"" -WorkingDirectory "$((Get-Location).Path)"
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    
    try {
        if (-not (Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)) {
            # 創建任務文件夾
            New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree$TaskPath" -Force | Out-Null
        }
        
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal
        
        # 啟動任務
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        Write-Host "計劃任務已創建並啟動: $TaskPath$TaskName"
    } catch {
        Write-Error "創建計劃任務失敗: $_"
        
        # 使用備用方法 - 寫入啟動目錄
        $StartupFolder = [System.Environment]::GetFolderPath("Startup")
        $ShortcutPath = Join-Path $StartupFolder "ModbusCollector.lnk"
        
        $WScriptShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "powershell.exe"
        $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$((Get-Location).Path)\start_service.ps1`""
        $Shortcut.WorkingDirectory = "$((Get-Location).Path)"
        $Shortcut.Save()
        
        Write-Host "已創建啟動項: $ShortcutPath"
    }
}

Write-Host "=== 部署完成 $(Get-Date) ==="
Write-Host "設備: $DEVICE_ID ($DEVICE_CONFIG_FILE)"
Write-Host "伺服器: $ServerIP"
Write-Host "推送網關: $PUSH_GATEWAY"
Write-Host "本地埠: $Port"
Write-Host "收集間隔: $Interval 秒"
Write-Host "日誌路徑: $LOG_FILE"

# 結束記錄
Stop-Transcript
