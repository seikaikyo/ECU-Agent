# Modbus 收集代理互動式安裝腳本 (Windows 版)

# 引入工具函數
. .\scripts\utils.ps1

# 確保目錄存在
if (-not (Test-Path "logs")) {
    New-Item -Path "logs" -ItemType Directory | Out-Null
}

# 顯示標題
Write-Title "Modbus 收集代理安裝與啟動工具"

# 檢測網絡配置
Write-Info "檢測網絡配置..."
$HOST_IPS = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" }).IPAddress
Write-Host "本機IP地址: " -NoNewline
Write-Host $HOST_IPS -ForegroundColor Yellow

# 讀取可用的設備配置
if (Test-Path "devices.json") {
    $DEVICES_JSON = "devices.json"
} elseif (Test-Path "config\devices\devices.json") {
    $DEVICES_JSON = "config\devices\devices.json"
} else {
    Write-Error "找不到設備配置檔案 (devices.json)"
    Write-Warning "請確認 devices.json 或 config\devices\devices.json 存在"
    exit 1
}

# 解析 JSON 配置
try {
    $DevicesConfig = Get-Content $DEVICES_JSON -Raw | ConvertFrom-Json
    Write-Info "找到 $($DevicesConfig.devices.Count) 台設備配置"
    
    # 顯示所有配置的 IP 列表
    Write-Host "設備列表:" -ForegroundColor Green
    for ($i = 0; $i -lt $DevicesConfig.devices.Count; $i++) {
        $DEVICE_ID = $DevicesConfig.devices[$i].id
        $DEVICE_NAME = $DevicesConfig.devices[$i].name
        $PRIMARY_IP = $DevicesConfig.devices[$i].primary_ip
        $BACKUP_IP = $DevicesConfig.devices[$i].backup_ip
        
        Write-Host "$($i+1). " -NoNewline
        Write-Host $DEVICE_NAME -ForegroundColor Yellow -NoNewline
        Write-Host " (ID: $DEVICE_ID)"
        Write-Host "   主要IP: $PRIMARY_IP"
        Write-Host "   備用IP: $BACKUP_IP"
    }
    
    # 嘗試自動檢測當前機器匹配哪個配置
    $DETECTED_DEVICE = $null
    $DETECTED_NAME = $null
    
    for ($i = 0; $i -lt $DevicesConfig.devices.Count; $i++) {
        $PRIMARY_IP = $DevicesConfig.devices[$i].primary_ip
        $BACKUP_IP = $DevicesConfig.devices[$i].backup_ip
        
        if ($HOST_IPS -contains $PRIMARY_IP -or $HOST_IPS -contains $BACKUP_IP) {
            $DETECTED_DEVICE = $i + 1
            $DETECTED_NAME = $DevicesConfig.devices[$i].name
            break
        }
    }
    
    # 讓用戶選擇或確認機號
    if ($DETECTED_DEVICE -ne $null) {
        Write-Host "`n檢測到您可能是 " -ForegroundColor Green -NoNewline
        Write-Host $DETECTED_NAME -ForegroundColor Yellow -NoNewline
        Write-Host " (機號 $DETECTED_DEVICE)" -ForegroundColor Green
        
        $CONFIRM = Read-Host "是否正確？(y/n)"
        if ($CONFIRM -match "^[Yy]") {
            $SELECTED_DEVICE = $DETECTED_DEVICE
        } else {
            $SELECTED_DEVICE = $null
        }
    }
    
    # 如果沒有自動檢測到或用戶不確認，則手動選擇
    if ($SELECTED_DEVICE -eq $null) {
        Write-Host "`n請選擇您的機台編號 (1-$($DevicesConfig.devices.Count)):" -ForegroundColor Yellow
        $SELECTED_DEVICE = Read-Host "機號"
        
        # 驗證選擇是否有效
        if (-not ($SELECTED_DEVICE -match "^\d+$") -or 
            [int]$SELECTED_DEVICE -lt 1 -or 
            [int]$SELECTED_DEVICE -gt $DevicesConfig.devices.Count) {
            
            Write-Error "無效的機號 $SELECTED_DEVICE"
            exit 1
        }
    }
    
    # 設置對應的配置檔案
    $DEVICE_INDEX = [int]$SELECTED_DEVICE - 1
    $DEVICE_CONFIG = $DevicesConfig.devices[$DEVICE_INDEX]
    $DEVICE_NAME = $DEVICE_CONFIG.name
    $DEVICE_ID = $DEVICE_CONFIG.id
    
    Write-Host "`n選擇了 " -ForegroundColor Green -NoNewline
    Write-Host $DEVICE_NAME -ForegroundColor Yellow
    Write-Host "配置信息:" -ForegroundColor Green
    $DEVICE_CONFIG | ConvertTo-Json -Depth 10
    
    # 輸出到單獨的配置檔
    $DEVICE_CONFIG_FILE = "device-$SELECTED_DEVICE.json"
    $DEVICE_CONFIG | ConvertTo-Json -Depth 10 | Out-File $DEVICE_CONFIG_FILE -Encoding utf8
    Write-Info "已創建設備配置文件: $DEVICE_CONFIG_FILE"
} catch {
    # 如果無法解析 JSON
    Write-Warning "無法解析設備配置 JSON: $_"
    
    # 檢查是否有設備配置檔案
    $DEVICE_FILES = Get-ChildItem -Filter "device-*.json" -File
    if ($DEVICE_FILES.Count -eq 0) {
        Write-Error "找不到任何 device-X.json 配置檔案"
        exit 1
    }
    
    Write-Host "發現以下設備配置:" -ForegroundColor Green
    for ($i = 0; $i -lt $DEVICE_FILES.Count; $i++) {
        Write-Host "$($i+1). " -NoNewline
        Write-Host $DEVICE_FILES[$i].Name -ForegroundColor Yellow
    }
    
    Write-Host "`n請選擇您的機台配置 (1-$($DEVICE_FILES.Count)):" -ForegroundColor Yellow
    $SELECTED_INDEX = Read-Host "選擇"
    
    # 驗證選擇是否有效
    if (-not ($SELECTED_INDEX -match "^\d+$") -or 
        [int]$SELECTED_INDEX -lt 1 -or 
        [int]$SELECTED_INDEX -gt $DEVICE_FILES.Count) {
        
        Write-Error "無效的選擇 $SELECTED_INDEX"
        exit 1
    }
    
    $DEVICE_CONFIG_FILE = $DEVICE_FILES[[int]$SELECTED_INDEX - 1].Name
    Write-Info "已選擇設備配置: $DEVICE_CONFIG_FILE"
    
    # 嘗試從文件名提取機號
    if ($DEVICE_CONFIG_FILE -match "device-(\d+)\.json") {
        $SELECTED_DEVICE = $Matches[1]
    }
    
    # 嘗試從文件提取ID
    try {
        $DeviceContent = Get-Content $DEVICE_CONFIG_FILE -Raw | ConvertFrom-Json
        $DEVICE_ID = $DeviceContent.id
    } catch {
        Write-Warning "無法從配置文件讀取設備ID"
    }
}

# 中央伺服器配置
Write-Host "`n設定中央伺服器..." -ForegroundColor Green
$SERVER_IP = Read-Host "請輸入中央伺服器IP地址"
if ([string]::IsNullOrWhiteSpace($SERVER_IP)) {
    Write-Error "伺服器IP不能為空"
    exit 1
}
$PUSH_GATEWAY = "http://${SERVER_IP}:9091"
Write-Info "Push Gateway 地址: $PUSH_GATEWAY"

# 本地HTTP服務埠配置
Write-Host "`n設定本地HTTP服務..." -ForegroundColor Green
$LOCAL_PORT = Read-Host "請輸入本地HTTP服務埠 (默認8000，輸入0禁用)"
if ([string]::IsNullOrWhiteSpace($LOCAL_PORT)) {
    $LOCAL_PORT = 8000
}
if ([int]$LOCAL_PORT -eq 0) {
    Write-Warning "本地HTTP服務已禁用"
} else {
    Write-Info "本地HTTP服務將在埠號 $LOCAL_PORT 啟動"
}

# 收集間隔配置
Write-Host "`n設定數據收集間隔..." -ForegroundColor Green
$INTERVAL = Read-Host "請輸入數據收集間隔秒數 (默認5秒)"
if ([string]::IsNullOrWhiteSpace($INTERVAL)) {
    $INTERVAL = 5
}
Write-Info "數據收集間隔: $INTERVAL 秒"

# 檢查是否已存在 collector-agent.py
if (-not (Test-Path "collector-agent.py") -and -not (Test-Path "agent\collector-agent.py")) {
    Write-Error "找不到 collector-agent.py"
    exit 1
} elseif (-not (Test-Path "collector-agent.py")) {
    Copy-Item "agent\collector-agent.py" .
    Write-Info "已複製 collector-agent.py 到當前目錄"
}

# 檢查是否已存在 plc_points.json
$POINTS_FILE = ""
if (Test-Path "plc_points.json") {
    $POINTS_FILE = "plc_points.json"
} elseif (Test-Path "config\plc_points.json") {
    $POINTS_FILE = "config\plc_points.json"
    Copy-Item $POINTS_FILE .
    $POINTS_FILE = "plc_points.json"
    Write-Info "已複製 plc_points.json 到當前目錄"
} else {
    Write-Error "找不到 plc_points.json"
    exit 1
}

# 保存配置到環境文件
Save-ConfigEnv $DEVICE_ID $DEVICE_CONFIG_FILE $SERVER_IP $PUSH_GATEWAY $LOCAL_PORT $INTERVAL

# 建立啟動批處理文件
Create-StartBatch $DEVICE_CONFIG_FILE $POINTS_FILE $PUSH_GATEWAY $LOCAL_PORT $INTERVAL

# 建立 PowerShell 啟動腳本
Create-StartPS $DEVICE_CONFIG_FILE $POINTS_FILE $PUSH_GATEWAY $LOCAL_PORT $INTERVAL

# 顯示啟動命令
Write-Info "啟動命令:"
Write-Host "python collector-agent.py --config `"$DEVICE_CONFIG_FILE`" --points `"$POINTS_FILE`" --push-gateway `"$PUSH_GATEWAY`" --port `"$LOCAL_PORT`" --interval `"$INTERVAL`""

# 詢問用戶是否立即啟動服務
Write-Host "`n服務已準備就緒。選擇啟動方式:" -ForegroundColor Yellow
Write-Host "1. 使用 Windows 服務啟動 (需要管理員權限)"
Write-Host "2. 使用計劃任務啟動"
Write-Host "3. 使用批處理文件啟動"
Write-Host "4. 暫不啟動"
$START_OPTION = Read-Host "請選擇 (1-4)"

switch ($START_OPTION) {
    "1" {
        Write-Info "正在建立 Windows 服務..."
        
        # 檢查是否以管理員權限運行
        $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        if (-not $IsAdmin) {
            Write-Warning "需要管理員權限來創建服務。請以管理員身份重新運行此腳本。"
            exit 1
        }
        
        # 使用 NSSM 建立服務，如果已安裝
        $nssmPath = "C:\Program Files\nssm\nssm.exe"
        
        if (Test-Path $nssmPath) {
            $ServiceName = "ModbusCollector"
            
            # 移除已存在的服務
            & $nssmPath remove $ServiceName confirm
            
            # 創建新服務
            & $nssmPath install $ServiceName python
            & $nssmPath set $ServiceName AppParameters "`"$((Get-Location).Path)\collector-agent.py`" --config `"$DEVICE_CONFIG_FILE`" --points `"$POINTS_FILE`" --push-gateway `"$PUSH_GATEWAY`" --port `"$LOCAL_PORT`" --interval `"$INTERVAL`""
            & $nssmPath set $ServiceName AppDirectory "$((Get-Location).Path)"
            & $nssmPath set $ServiceName DisplayName "Modbus 收集代理"
            & $nssmPath set $ServiceName Description "從 PLC 收集 Modbus 數據並發送到 Prometheus"
            & $nssmPath set $ServiceName Start SERVICE_AUTO_START
            & $nssmPath set $ServiceName AppStdout "$((Get-Location).Path)\logs\service_stdout.log"
            & $nssmPath set $ServiceName AppStderr "$((Get-Location).Path)\logs\service_stderr.log"
            
            # 啟動服務
            Start-Service $ServiceName
            Write-Host "服務已創建並啟動: $ServiceName"
        } else {
            # 使用 Windows 原生服務建立方式
            $ServiceName = "ModbusCollector"
            
            # 如果服務已存在，先刪除
            if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
                Stop-Service $ServiceName -Force
                Remove-Service $ServiceName
            }
            
            # 創建服務
            $BinaryPath = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$((Get-Location).Path)\start_service.ps1`""
            New-Service -Name $ServiceName -BinaryPathName $BinaryPath -DisplayName "Modbus 收集代理" -Description "從 PLC 收集 Modbus 數據並發送到 Prometheus" -StartupType Automatic
            
            # 啟動服務
            Start-Service $ServiceName
            Write-Host "服務已創建並啟動: $ServiceName"
        }
    }
    "2" {
        Write-Info "正在建立計劃任務..."
        
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
        $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Password -RunLevel Highest
        
        try {
            if (-not (Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)) {
                # 創建任務文件夾
                New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree$TaskPath" -Force -ErrorAction SilentlyContinue | Out-Null
            }
            
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal
            
            # 啟動任務
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
            Write-Info "計劃任務已創建並啟動: $TaskPath$TaskName"
        } catch {
            Write-Warning "創建計劃任務失敗: $_"
            
            # 使用備用方法 - 寫入啟動目錄
            $StartupFolder = [System.Environment]::GetFolderPath("Startup")
            $ShortcutPath = Join-Path $StartupFolder "ModbusCollector.lnk"
            
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
            $Shortcut.TargetPath = "powershell.exe"
            $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$((Get-Location).Path)\start_service.ps1`""
            $Shortcut.WorkingDirectory = "$((Get-Location).Path)"
            $Shortcut.Save()
            
            Write-Info "已創建啟動項: $ShortcutPath"
        }
    }
    "3" {
        Write-Info "使用批處理文件啟動服務..."
        Start-Process -FilePath "start_service.bat"
    }
    default {
        Write-Warning "服務未啟動。您可以稍後手動啟動:"
        Write-Host "批處理方式: " -NoNewline
        Write-Host "start_service.bat" -ForegroundColor Yellow
        Write-Host "PowerShell方式: " -NoNewline
        Write-Host ".\start_service.ps1" -ForegroundColor Yellow
    }
}

# 顯示總結訊息
Write-Title "設定完成！收集代理已配置"

Write-Host "配置摘要:"
Write-Host "設備ID: " -NoNewline
Write-Host $DEVICE_ID -ForegroundColor Yellow
Write-Host "設備配置: " -NoNewline
Write-Host $DEVICE_CONFIG_FILE -ForegroundColor Yellow
Write-Host "中央伺服器: " -NoNewline
Write-Host $SERVER_IP -ForegroundColor Yellow
Write-Host "Push Gateway: " -NoNewline
Write-Host $PUSH_GATEWAY -ForegroundColor Yellow
Write-Host "本地HTTP埠: " -NoNewline
Write-Host $LOCAL_PORT -ForegroundColor Yellow
Write-Host "收集間隔: " -NoNewline
Write-Host "$INTERVAL 秒" -ForegroundColor Yellow

Write-Host "`n日誌文件:"
Write-Host "Windows 服務日誌: " -NoNewline
Write-Host "logs\service_*.log" -ForegroundColor Yellow
Write-Host "批處理腳本日誌: " -NoNewline
Write-Host "logs\collector_*.log" -ForegroundColor Yellow

Write-Title "配置完成"
