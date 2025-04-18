#!/bin/bash
# 中央伺服器設定腳本

# 獲取腳本所在目錄的絕對路徑
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# 載入共用函數
source $PARENT_DIR/scripts/utils.sh

# 設定資料目錄
DATA_ROOT="/data"
PROMETHEUS_DIR="${DATA_ROOT}/prometheus"
PUSHGATEWAY_DIR="${DATA_ROOT}/pushgateway"
GRAFANA_DIR="${DATA_ROOT}/grafana"
CONFIG_DIR="$(pwd)/config"

# 顯示標題
log_header "Prometheus + Grafana 監控系統設定與啟動工具"

# 檢查是否以 root 運行
if [ "$EUID" -ne 0 ]; then
    log_error "請使用 root 權限運行此腳本"
    echo -e "${YELLOW}請執行: sudo $0${NC}"
    exit 1
fi

# 步驟 1: 檢查依賴
log_info "步驟 1: 檢查系統環境..."
$PARENT_DIR/scripts/install_deps.sh server

# 步驟 2: 建立並設定資料目錄
log_info "步驟 2: 建立資料儲存目錄..."
mkdir -p "$PROMETHEUS_DIR" "$PUSHGATEWAY_DIR" "$GRAFANA_DIR" 
mkdir -p "$CONFIG_DIR/grafana/provisioning/datasources"
mkdir -p "$CONFIG_DIR/grafana/provisioning/dashboards"
mkdir -p "$CONFIG_DIR/grafana/dashboards"

# 設定權限
log_info "設定目錄權限..."
chown -R 65534:65534 "$PROMETHEUS_DIR"
chown -R 65534:65534 "$PUSHGATEWAY_DIR"
chown -R 472:472 "$GRAFANA_DIR"  # Grafana 容器的默認 UID 是 472

chmod -R 755 "$DATA_ROOT"
chmod -R 775 "$PROMETHEUS_DIR" "$PUSHGATEWAY_DIR" "$GRAFANA_DIR"

# 步驟 3: 複製配置文件模板
log_info "步驟 3: 準備配置文件..."

# 複製 docker-compose.yml
cp $SCRIPT_DIR/templates/docker-compose.yml docker-compose.yml
log_info "已複製 docker-compose.yml"

# 複製 prometheus.yml 配置
mkdir -p config
cp $SCRIPT_DIR/templates/prometheus.yml config/prometheus.yml
log_info "已複製 Prometheus 配置"

# 設定 Grafana 數據源
mkdir -p config/grafana/provisioning/datasources
cat > config/grafana/provisioning/datasources/prometheus.yml << 'EOL'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOL
log_info "已設定 Grafana 數據源"

# 設定 Grafana 儀表板配置
mkdir -p config/grafana/provisioning/dashboards
cat > config/grafana/provisioning/dashboards/default.yml << 'EOL'
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
EOL
log_info "已設定 Grafana 儀表板配置"

# 複製範例儀表板
if [ -f "$SCRIPT_DIR/templates/grafana-dashboard.json" ]; then
    mkdir -p config/grafana/dashboards
    cp $SCRIPT_DIR/templates/grafana-dashboard.json config/grafana/dashboards/modbus_overview.json
    log_info "已複製範例儀表板"
else
    # 如果沒有模板，建立一個基本儀表板
    mkdir -p config/grafana/dashboards
    cat > config/grafana/dashboards/modbus_overview.json << 'EOL'
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
EOL
    log_info "已創建基本儀表板"
fi

# 步驟 4: 設定設備配置目錄
log_info "步驟 4: 設定設備配置..."
mkdir -p config/devices

# 如果提供的設備配置存在，則複製
if [ -f "$PARENT_DIR/config/devices/devices.json" ]; then
    cp $PARENT_DIR/config/devices/devices.json config/devices/
    log_info "已複製設備配置"
else
    # 否則，創建一個範例
    cat > config/devices/devices.json << 'EOL'
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
EOL
    log_info "已創建範例設備配置"
fi

# 為每個機台建立單獨的配置檔
if command -v jq > /dev/null; then
    DEVICE_COUNT=$(jq '.devices | length' config/devices/devices.json)
    for i in $(seq 0 $(($DEVICE_COUNT-1))); do
        device_config=$(jq ".devices[$i]" config/devices/devices.json)
        device_num=$((i+1))
        echo "$device_config" > config/devices/device-$device_num.json
    done
    log_info "已為每台設備創建獨立配置文件"
fi

# 步驟 5: 為代理機器準備啟動腳本
log_info "步驟 5: 準備代理啟動腳本..."

# 複製或創建 plc_points.json
if [ -f "$PARENT_DIR/config/plc_points.json" ]; then
    cp $PARENT_DIR/config/plc_points.json config/
else
    # 創建一個提示檔案
    cat > config/plc_points.json << 'EOL'
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
EOL
    log_info "已創建 PLC 點位配置模板，請完善它"
fi

# 複製代理啟動和部署腳本
mkdir -p config/scripts
if [ -f "$PARENT_DIR/agent/start_agent.sh" ]; then
    cp $PARENT_DIR/agent/start_agent.sh config/scripts/
    log_info "已複製互動式安裝腳本"
fi

if [ -f "$PARENT_DIR/agent/deploy_agent.sh" ]; then
    cp $PARENT_DIR/agent/deploy_agent.sh config/scripts/
    log_info "已複製自動部署腳本"
fi

if [ -f "$PARENT_DIR/agent/collector_agent.py" ]; then
    cp $PARENT_DIR/agent/collector_agent.py config/scripts/
    log_info "已複製代理主程式"
fi

# 步驟 6: 啟動服務
log_info "步驟 6: 啟動監控服務..."
docker-compose down
docker-compose up -d

# 步驟 7: 檢查服務狀態
log_info "步驟 7: 檢查服務狀態..."
docker-compose ps

# 顯示總結訊息
echo
log_header "設定完成！系統已成功啟動"
echo
echo -e "可通過以下網址訪問服務:"
echo -e "${YELLOW}Prometheus: ${NC}http://$(hostname -I | awk '{print $1}'):9090"
echo -e "${YELLOW}Push Gateway: ${NC}http://$(hostname -I | awk '{print $1}'):9091"
echo -e "${YELLOW}Grafana: ${NC}http://$(hostname -I | awk '{print $1}'):3000 (用戶名/密碼: admin/admin)"
echo
echo -e "資料儲存位置:"
echo -e "${YELLOW}Prometheus: ${NC}$PROMETHEUS_DIR"
echo -e "${YELLOW}Push Gateway: ${NC}$PUSHGATEWAY_DIR"
echo -e "${YELLOW}Grafana: ${NC}$GRAFANA_DIR"
echo
echo -e "設備配置與代理工具:"
echo -e "${YELLOW}設備配置: ${NC}$(pwd)/config/devices/"
echo -e "${YELLOW}代理工具: ${NC}$(pwd)/config/scripts/"
echo -e "${YELLOW}點位定義: ${NC}$(pwd)/config/plc_points.json"
echo
log_header "請妥善保存以上信息"
