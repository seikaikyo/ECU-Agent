# 中央伺服器設定腳本 (Windows版)

# 獲取腳本所在目錄的絕對路徑
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PARENT_DIR = Split-Path -Parent $SCRIPT_DIR

# 載入共用函數
. "$PARENT_DIR\scripts\utils.ps1"

# 設定資料目錄
$DATA_ROOT = "C:\data"
$PROMETHEUS_DIR = "$DATA_ROOT\prometheus"
$PUSHGATEWAY_DIR = "$DATA_ROOT\pushgateway"
$GRAFANA_DIR = "$DATA_ROOT\grafana"
$CONFIG_DIR = "$(Get-Location)\config"

# 顯示標題
Write-Title "Prometheus + Grafana 監控系統設定與啟動工具"

# 檢查是否以管理員權限運行
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $IsAdmin) {
    Write-Error "請使用管理員權限運行此腳本"
    Write-Host "請以管理員身份重新運行此腳本" -ForegroundColor Yellow
    exit 1
}

# 步驟 1: 檢查依賴
Write-Info "步驟 1: 檢查系統環境..."
& "$PARENT_DIR\scripts\install-deps.ps1" server

# 檢查 Docker 是否運行
$DockerRunning = $false
try {
    $DockerService = Get-Service docker -ErrorAction SilentlyContinue
    if ($DockerService.Status -eq "Running") {
        $DockerRunning = $true
        Write-Info "Docker 服務正在運行"
    } else {
        Write-Warning "Docker 服務未運行"
        Start-Service docker
        Write-Info "已啟動 Docker 服務"
    }
} catch {
    Write-Error "無法檢查或啟動 Docker 服務: $_"
    Write-Host "請確保 Docker Desktop 已安裝並運行" -ForegroundColor Yellow
    exit 1
}

# 步驟 2: 建立並設定資料目錄
Write-Info "步驟 2: 建立資料儲存目錄..."
if (-not (Test-Path $DATA_ROOT)) {
    New-Item -Path $DATA_ROOT -ItemType Directory | Out-Null
}
if (-not (Test-Path $PROMETHEUS_DIR)) {
    New-Item -Path $PROMETHEUS_DIR -ItemType Directory | Out-Null
}
if (-not (Test-Path $PUSHGATEWAY_DIR)) {
    New-Item -Path $PUSHGATEWAY_DIR -ItemType Directory | Out-Null
}
if (-not (Test-Path $GRAFANA_DIR)) {
    New-Item -Path $GRAFANA_DIR -ItemType Directory | Out-Null
}

if (-not (Test-Path "$CONFIG_DIR\grafana\provisioning\datasources")) {
    New-Item -Path "$CONFIG_DIR\grafana\provisioning\datasources" -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path "$CONFIG_DIR\grafana\provisioning\dashboards")) {
    New-Item -Path "$CONFIG_DIR\grafana\provisioning\dashboards" -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path "$CONFIG_DIR\grafana\dashboards")) {
    New-Item -Path "$CONFIG_DIR\grafana\dashboards" -ItemType Directory -Force | Out-Null
}

# 設定權限
Write-Info "設定目錄權限..."
# 在 Windows 中設定權限比 Linux 中複雜，這裡簡化處理
icacls $DATA_ROOT /grant "Everyone:(OI)(CI)F" /T
Write-Info "已設定資料目錄權限"

# 步驟 3: 複製配置文件模板
Write-Info "步驟 3: 準備配置文件..."

# 複製 docker-compose.yml
if (Test-Path "$SCRIPT_DIR\templates\docker-compose.yml") {
    Copy-Item "$SCRIPT_DIR\templates\docker-compose.yml" "docker-compose.yml" -Force
    Write-Info "已複製 docker-compose.yml"
    
    # 修改 Docker Compose 文件的路徑格式（Windows 路徑）
    $ComposeContent = Get-Content "docker-compose.yml" -Raw
    $ComposeContent = $ComposeContent -replace "device: /data/prometheus", "device: $($PROMETHEUS_DIR -replace '\\', '\\')"
    $ComposeContent = $ComposeContent -replace "device: /data/pushgateway", "device: $($PUSHGATEWAY_DIR -replace '\\', '\\')"
    $ComposeContent = $ComposeContent -replace "device: /data/grafana", "device: $($GRAFANA_DIR -replace '\\', '\\')"
    $ComposeContent | Out-File "docker-compose.yml" -Encoding utf8 -Force
    Write-Info "已調整 docker-compose.yml 中的路徑"
} else {
    Write-Warning "找不到 docker-compose.yml 模板"
    exit 1
}

# 複製 prometheus.yml 配置
if (-not (Test-Path "config")) {
    New-Item -Path "config" -ItemType Directory | Out-Null
}

if (Test-Path "$SCRIPT_DIR\templates\prometheus.yml") {
    Copy-Item "$SCRIPT_DIR\templates\prometheus.yml" "config\prometheus.yml" -Force
    Write-Info "已複製 Prometheus 配置"
} else {
    Write-Warning "找不到 prometheus.yml 模板"
    exit 1
}

# 設定 Grafana 數據源
$GrafanaDatasource = @"
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
"@
$GrafanaDatasource | Out-File "config\grafana\provisioning\datasources\prometheus.yml" -Encoding utf8 -Force
Write-Info "已設定 Grafana 數據源"

# 設定 Grafana 儀表板配置
$GrafanaDashboardProvider = @"
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
"@
$GrafanaDashboardProvider | Out-File "config\grafana\provisioning\dashboards\default.yml" -Encoding utf8 -Force
Write-Info "已設定 Grafana 儀表板配置"

# 複製範例儀表板
if (Test-Path "$SCRIPT_DIR\templates\grafana-dashboard.json") {
    if (-not (Test-Path "config\grafana\dashboards")) {
        New-Item -Path "config\grafana\dashboards" -ItemType Directory -Force | Out-Null
    }
    Copy-Item "$SCRIPT_DIR\templates\grafana-dashboard.json" "config\grafana\dashboards\modbus_overview.json" -Force
    Write-Info "已複製範例儀表板"
} else {
    # 如果沒有模板，建立一個基本儀表板
    $GrafanaDashboard = @"
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "target": {
          "limit": 100,
          "matchAny": false,
          "tags": [],
          "type": "dashboard"
        },
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "PBFA97CFB590B2093"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [
            {
              "options": {
                "0": {
                  "color": "red",
                  "index": 0,
                  "text": "離線"
                },
                "1": {
                  "color": "green",
                  "index": 1,
                  "text": "在線"
                }
              },
              "type": "value"
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "gridPos": {
        "h": 5,
        "w": 24,
        "x": 0,
        "y": 1
      },
      "id": 10,
      "options": {
        "colorMode": "value",
        "graphMode": "none",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "pluginVersion": "9.3.6",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "PBFA97CFB590B2093"
          },
          "expr": "device_connection_status",
          "legendFormat": "{{device}} ({{ip}})",
          "refId": "A"
        }
      ],
      "title": "設備連接狀態",
      "type": "stat"
    }
  ],
  "refresh": "5s",
  "schemaVersion": 37,
  "style": "dark",
  "tags": ["modbus", "plc"],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "PLC 監控總覽",
  "uid": "modbus-overview",
  "version": 1,
  "weekStart": ""
}
"@
    $GrafanaDashboard | Out-File "config\grafana\dashboards\modbus_overview.json" -Encoding utf8 -Force
    Write-Info "已創建基本儀表板"
}

# 步驟 4: 設定設備配置目錄
Write-Info "步驟 4: 設定設備配置..."
if (-not (Test-Path "config\devices")) {
    New-Item -Path "config\devices" -ItemType Directory -Force | Out-Null
}

# 如果提供的設備配置存在，則複製
if (Test-Path "$PARENT_DIR\config\devices\devices.json") {
    Copy-Item "$PARENT_DIR\config\devices\devices.json" "config\devices\" -Force
    Write-Info "已複製設備配置"
} else {
    # 否則，創建一個範例
    $DevicesConfig = @"
{
  "devices": [
    {
      "id": "ecu1051_1",
      "name": "1號機",
      "primary_ip": "10.6.118.52",
      "backup_ip": "10.6.118.53",
      "port": 502,
      "timeout": 3,
      "retry_interval": 60
    },
    {
      "id": "ecu1051_2",
      "name": "2號機",
      "primary_ip": "10.6.118.58",
      "backup_ip": "10.6.118.59",
      "port": 502,
      "timeout": 3,
      "retry_interval": 60
    },
    {
      "id": "ecu1051_3",
      "name": "3號機",
      "primary_ip": "10.6.118.64",
      "backup_ip": "10.6.118.65",
      "port": 502,
      "timeout": 3,
      "retry_interval": 60
    },
    {
      "id": "ecu1051_4",
      "name": "4號機",
      "primary_ip": "10.6.118.70",
      "backup_ip": "10.6.118.71",
      "port": 502,
      "timeout": 3,
      "retry_interval": 60
    }
  ]
}
"@
    $DevicesConfig | Out-File "config\devices\devices.json" -Encoding utf8 -Force
    Write-Info "已創建範例設備配置"
}

# 為每個機台建立單獨的配置檔
try {
    $DevicesJson = Get-Content "config\devices\devices.json" -Raw | ConvertFrom-Json
    for ($i = 0; $i -lt $DevicesJson.devices.Count; $i++) {
        $DeviceConfig = $DevicesJson.devices[$i] | ConvertTo-Json -Depth 10
        $DeviceNum = $i + 1
        $DeviceConfig | Out-File "config\devices\device-$DeviceNum.json" -Encoding utf8 -Force
    }
    Write-Info "已為每台設備創建獨立配置文件"
} catch {
    Write-Warning "無法解析或處理設備配置: $_"
}

# 步驟 5: 為代理機器準備啟動腳本
Write-Info "步驟 5: 準備代理啟動腳本..."

# 複製或創建 plc_points.json
if (Test-Path "$PARENT_DIR\config\plc_points.json") {
    Copy-Item "$PARENT_DIR\config\plc_points.json" "config\" -Force
} else {
    # 創建一個提示檔案
    $PlcPoints = @"
{
  "metric_groups": [
    {
      "group_name": "溫度控制器",
      "device_id": 1,
      "start_address": 40001,
      "count": 78,
      "metrics": [
        {
          "id": "left_main_temp_pv",
          "name": "左側主控_PV",
          "register_offset": 0,
          "data_type": "INT16",
          "scale_factor": 10.0,
          "unit": "℃"
        }
        // 需要完整定義所有點位...
      ]
    }
  ]
}
"@
    $PlcPoints | Out-File "config\plc_points.json" -Encoding utf8 -Force
    Write-Info "已創建 PLC 點位配置模板，請完善它"
}

# 複製代理啟動和部署腳本
if (-not (Test-Path "config\scripts")) {
    New-Item -Path "config\scripts" -ItemType Directory -Force | Out-Null
}

if (Test-Path "$PARENT_DIR\agent\start-agent.ps1") {
    Copy-Item "$PARENT_DIR\agent\start-agent.ps1" "config\scripts\" -Force
    Write-Info "已複製互動式安裝腳本"
}

if (Test-Path "$PARENT_DIR\agent\deploy_agent.ps1") {
    Copy-Item "$PARENT_DIR\agent\deploy_agent.ps1" "config\scripts\" -Force
    Write-Info "已複製自動部署腳本"
}

if (Test-Path "$PARENT_DIR\agent\collector-agent.py") {
    Copy-Item "$PARENT_DIR\agent\collector-agent.py" "config\scripts\" -Force
    Write-Info "已複製代理主程式"
}

# 步驟 6: 啟動服務
Write-Info "步驟 6: 啟動監控服務..."
try {
    docker-compose down
    docker-compose up -d
} catch {
    Write-Error "啟動服務失敗: $_"
    exit 1
}

# 步驟 7: 檢查服務狀態
Write-Info "步驟 7: 檢查服務狀態..."
docker-compose ps

# 獲取本機 IP 地址
$LocalIP = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1).IPAddress

# 顯示總結訊息
Write-Title "設定完成！系統已成功啟動"

Write-Host "可通過以下網址訪問服務:"
Write-Host "Prometheus: " -NoNewline
Write-Host "http://$LocalIP`:9090" -ForegroundColor Yellow
Write-Host "Push Gateway: " -NoNewline
Write-Host "http://$LocalIP`:9091" -ForegroundColor Yellow
Write-Host "Grafana: " -NoNewline
Write-Host "http://$LocalIP`:3000 (用戶名/密碼: admin/admin)" -ForegroundColor Yellow

Write-Host "`n資料儲存位置:"
Write-Host "Prometheus: " -NoNewline
Write-Host $PROMETHEUS_DIR -ForegroundColor Yellow
Write-Host "Push Gateway: " -NoNewline
Write-Host $PUSHGATEWAY_DIR -ForegroundColor Yellow
Write-Host "Grafana: " -NoNewline
Write-Host $GRAFANA_DIR -ForegroundColor Yellow

Write-Host "`n設備配置與代理工具:"
Write-Host "設備配置: " -NoNewline
Write-Host "$(Get-Location)\config\devices\" -ForegroundColor Yellow
Write-Host "代理工具: " -NoNewline
Write-Host "$(Get-Location)\config\scripts\" -ForegroundColor Yellow
Write-Host "點位定義: " -NoNewline
Write-Host "$(Get-Location)\config\plc_points.json" -ForegroundColor Yellow

Write-Title "請妥善保存以上信息"
