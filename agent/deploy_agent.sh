#!/bin/bash
# Modbus 收集代理自動部署腳本
# 專為 CI/CD 環境設計，支援命令行參數和非互動式運行

# 顯示說明
show_help() {
    echo "用法: $0 [選項]"
    echo
    echo "選項:"
    echo "  -d, --device ID       設備識別號或配置文件名 (必要)"
    echo "  -s, --server IP       中央伺服器IP地址 (必要)"
    echo "  -p, --port PORT       本地HTTP服務埠 (預設: 8000，設為0禁用)"
    echo "  -i, --interval SEC    數據收集間隔，單位為秒 (預設: 5)"
    echo "  -a, --autostart MODE  自動啟動方式 (systemd 或 script，預設: systemd)"
    echo "  -j, --json FILE       設備配置JSON檔案 (預設: devices.json)"
    echo "  -h, --help            顯示此幫助信息"
    echo
    echo "範例:"
    echo "  $0 -d 1 -s 192.168.1.100"
    echo "  $0 --device=ecu1051_1 --server=10.0.0.1 --port=9000 --interval=10"
    echo
}

# 預設值
LOCAL_PORT=8000
INTERVAL=5
AUTOSTART="systemd"
DEVICES_JSON="devices.json"

# 解析命令行參數
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--device) DEVICE="$2"; shift ;;
        --device=*) DEVICE="${1#*=}" ;;
        -s|--server) SERVER_IP="$2"; shift ;;
        --server=*) SERVER_IP="${1#*=}" ;;
        -p|--port) LOCAL_PORT="$2"; shift ;;
        --port=*) LOCAL_PORT="${1#*=}" ;;
        -i|--interval) INTERVAL="$2"; shift ;;
        --interval=*) INTERVAL="${1#*=}" ;;
        -a|--autostart) AUTOSTART="$2"; shift ;;
        --autostart=*) AUTOSTART="${1#*=}" ;;
        -j|--json) DEVICES_JSON="$2"; shift ;;
        --json=*) DEVICES_JSON="${1#*=}" ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "未知選項: $1" >&2; show_help; exit 1 ;;
    esac
    shift
done

# 驗證必要參數
if [ -z "$DEVICE" ]; then
    echo "錯誤: 缺少設備識別號或配置文件" >&2
    show_help
    exit 1
fi

if [ -z "$SERVER_IP" ]; then
    echo "錯誤: 缺少中央伺服器IP地址" >&2
    show_help
    exit 1
fi

# 設定日誌輸出
LOG_DIR="logs"
mkdir -p $LOG_DIR
LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

# 輸出同時顯示到終端和記錄到日誌
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== 開始部署 Modbus 收集代理 $(date) ==="
echo "設備: $DEVICE"
echo "伺服器: $SERVER_IP"
echo "本地埠: $LOCAL_PORT"
echo "收集間隔: $INTERVAL 秒"
echo "自動啟動方式: $AUTOSTART"
echo "設備配置檔: $DEVICES_JSON"

# 設置推送網關
PUSH_GATEWAY="http://${SERVER_IP}:9091"

# 安裝必要的 Python 依賴
echo "=== 安裝 Python 依賴 ==="
pip install pymodbus prometheus-client requests

# 配置文件處理
CONFIG_DIR="config"
mkdir -p $CONFIG_DIR

# 根據設備ID或名稱提取配置
DEVICE_CONFIG_FILE=""
DEVICE_ID=""

# 提取設備配置
if [[ $DEVICE == device-* ]] && [ -f "$DEVICE" ]; then
    # 如果 DEVICE 參數指向已存在的配置文件
    echo "使用現有配置文件: $DEVICE"
    DEVICE_CONFIG_FILE="$DEVICE"
    # 嘗試提取設備ID (如果有jq)
    if command -v jq > /dev/null; then
        DEVICE_ID=$(jq -r '.id // empty' "$DEVICE_CONFIG_FILE")
    fi
elif [[ $DEVICE =~ ^[0-9]+$ ]] && [ -f "$DEVICES_JSON" ]; then
    # 如果 DEVICE 是數字，從 JSON 檔案中提取對應索引的設備
    if command -v jq > /dev/null; then
        # 檢查索引範圍
        DEVICE_COUNT=$(jq '.devices | length' $DEVICES_JSON)
        DEVICE_INDEX=$((DEVICE-1))
        if [ $DEVICE_INDEX -ge 0 ] && [ $DEVICE_INDEX -lt $DEVICE_COUNT ]; then
            echo "從 $DEVICES_JSON 提取設備 #$DEVICE 的配置"
            DEVICE_CONFIG=$(jq -c ".devices[$DEVICE_INDEX]" $DEVICES_JSON)
            DEVICE_ID=$(jq -r ".devices[$DEVICE_INDEX].id" $DEVICES_JSON)
            DEVICE_CONFIG_FILE="device-$DEVICE.json"
            echo "$DEVICE_CONFIG" > "$DEVICE_CONFIG_FILE"
            echo "已創建設備配置文件: $DEVICE_CONFIG_FILE"
        else
            echo "錯誤: 無效的設備索引 $DEVICE (範圍: 1-$DEVICE_COUNT)"
            exit 1
        fi
    else
        echo "錯誤: 需要安裝 jq 來處理 JSON 文件"
        exit 1
    fi
else
    # 嘗試直接使用 DEVICE 作為設備 ID 從 JSON 中尋找匹配
    if command -v jq > /dev/null && [ -f "$DEVICES_JSON" ]; then
        # 通過 ID 尋找設備
        DEVICE_INDEX=$(jq ".devices | map(.id == \"$DEVICE\") | index(true)" $DEVICES_JSON)
        if [ "$DEVICE_INDEX" != "null" ] && [ "$DEVICE_INDEX" -ge 0 ]; then
            echo "使用設備 ID: $DEVICE"
            DEVICE_CONFIG=$(jq -c ".devices[$DEVICE_INDEX]" $DEVICES_JSON)
            DEVICE_CONFIG_FILE="device-$DEVICE.json"
            echo "$DEVICE_CONFIG" > "$DEVICE_CONFIG_FILE"
            DEVICE_ID="$DEVICE"
            echo "已創建設備配置文件: $DEVICE_CONFIG_FILE"
        else
            echo "錯誤: 在 $DEVICES_JSON 中找不到 ID 為 $DEVICE 的設備"
            exit 1
        fi
    else
        echo "錯誤: 無法處理設備配置"
        exit 1
    fi
fi

if [ -z "$DEVICE_CONFIG_FILE" ] || [ ! -f "$DEVICE_CONFIG_FILE" ]; then
    echo "錯誤: 無法建立或找到設備配置文件"
    exit 1
fi

# 確保 PLC 點位文件存在
if [ ! -f "plc_points.json" ]; then
    echo "錯誤: 找不到 plc_points.json 文件"
    exit 1
fi

# 確保代理程式存在
if [ ! -f "collector_agent.py" ]; then
    echo "錯誤: 找不到 collector_agent.py 文件"
    exit 1
fi

# 記錄配置到 .env 文件
echo "=== 保存配置 ==="
cat > $CONFIG_DIR/agent_config.env << EOL
# Modbus 收集代理配置
# 由自動部署腳本生成於 $(date)

# 設備信息
DEVICE_ID="$DEVICE_ID"
DEVICE_CONFIG="$DEVICE_CONFIG_FILE"

# 伺服器信息
SERVER_IP="$SERVER_IP"
PUSH_GATEWAY="$PUSH_GATEWAY"

# 運行配置
LOCAL_PORT=$LOCAL_PORT
INTERVAL=$INTERVAL
EOL
echo "已保存配置到: $CONFIG_DIR/agent_config.env"

# 創建服務啟動腳本
echo "=== 建立啟動腳本 ==="
cat > start_service.sh << EOL
#!/bin/bash
python collector_agent.py \\
  --config "$DEVICE_CONFIG_FILE" \\
  --points "plc_points.json" \\
  --push-gateway "$PUSH_GATEWAY" \\
  --port "$LOCAL_PORT" \\
  --interval "$INTERVAL" > logs/collector_\$(date +%Y%m%d).log 2>&1 &

echo "收集代理已啟動，進程 ID: \$!"
EOL
chmod +x start_service.sh
echo "已建立啟動腳本: start_service.sh"

# 建立系統服務
echo "=== 配置系統服務 ==="
SERVICE_NAME="modbus-collector"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

cat > "$SERVICE_NAME.service" << EOL
[Unit]
Description=Modbus Collector Agent
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(which python) $(pwd)/collector_agent.py --config "$DEVICE_CONFIG_FILE" --points "$(pwd)/plc_points.json" --push-gateway "$PUSH_GATEWAY" --port "$LOCAL_PORT" --interval "$INTERVAL"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

# 複製服務文件並啟動
if [ "$AUTOSTART" = "systemd" ]; then
    echo "=== 使用 systemd 啟動服務 ==="
    cp "$SERVICE_NAME.service" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME
    systemctl status $SERVICE_NAME --no-pager
    echo "服務已啟動，狀態請見上方輸出"
elif [ "$AUTOSTART" = "script" ]; then
    echo "=== 使用啟動腳本啟動服務 ==="
    ./start_service.sh
    echo "服務已通過腳本啟動"
else
    echo "=== 不自動啟動服務 ==="
    echo "可使用以下命令手動啟動:"
    echo "systemd: sudo cp $SERVICE_NAME.service $SERVICE_FILE && sudo systemctl daemon-reload && sudo systemctl enable $SERVICE_NAME && sudo systemctl start $SERVICE_NAME"
    echo "腳本: ./start_service.sh"
fi

echo "=== 部署完成 $(date) ==="
echo "設備: $DEVICE_ID ($DEVICE_CONFIG_FILE)"
echo "伺服器: $SERVER_IP"
echo "推送網關: $PUSH_GATEWAY"
echo "本地埠: $LOCAL_PORT"
echo "收集間隔: $INTERVAL 秒"
echo "日誌路徑: $LOG_FILE"
