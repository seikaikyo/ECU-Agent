#!/bin/bash
# Modbus 收集代理互動式安裝腳本

# 獲取腳本所在目錄的絕對路徑
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# 載入共用函數
source $PARENT_DIR/scripts/utils.sh

# 確保目錄存在
mkdir -p logs

# 顯示標題
log_header "Modbus 收集代理安裝與啟動工具"

# 檢查依賴
$PARENT_DIR/scripts/install_deps.sh agent

# 檢測網絡配置
log_info "檢測網絡配置..."
HOST_IPS=$(hostname -I)
echo -e "本機IP地址: ${YELLOW}$HOST_IPS${NC}"

# 讀取可用的設備配置
if [ -f "devices.json" ]; then
    DEVICES_JSON="devices.json"
elif [ -f "$PARENT_DIR/config/devices/devices.json" ]; then
    DEVICES_JSON="$PARENT_DIR/config/devices/devices.json"
else
    log_error "找不到設備配置檔案 (devices.json)"
    log_warn "請確認 devices.json 或 config/devices/devices.json 存在"
    exit 1
fi

# 如果有 jq 工具，使用它來解析 JSON
if command -v jq > /dev/null; then
    log_info "使用 jq 解析設備配置..."
    DEVICE_COUNT=$(jq '.devices | length' $DEVICES_JSON)
    log_info "找到 ${YELLOW}$DEVICE_COUNT${NC} 台設備配置"
    
    # 顯示所有配置的 IP 列表
    echo -e "${GREEN}設備列表:${NC}"
    for i in $(seq 0 $(($DEVICE_COUNT-1))); do
        DEVICE_ID=$(jq -r ".devices[$i].id" $DEVICES_JSON)
        DEVICE_NAME=$(jq -r ".devices[$i].name" $DEVICES_JSON)
        PRIMARY_IP=$(jq -r ".devices[$i].primary_ip" $DEVICES_JSON)
        BACKUP_IP=$(jq -r ".devices[$i].backup_ip" $DEVICES_JSON)
        
        echo -e "$((i+1)). ${YELLOW}$DEVICE_NAME${NC} (ID: $DEVICE_ID)"
        echo -e "   主要IP: $PRIMARY_IP"
        echo -e "   備用IP: $BACKUP_IP"
    done
    
    # 嘗試自動檢測當前機器匹配哪個配置
    DETECTED_RESULT=$(detect_device_ip $DEVICES_JSON)
    if [ $? -eq 0 ]; then
        DETECTED_DEVICE=$(echo $DETECTED_RESULT | cut -d':' -f1)
        DETECTED_NAME=$(echo $DETECTED_RESULT | cut -d':' -f2)
        
        echo -e "\n${GREEN}自動檢測到您可能是 ${YELLOW}$DETECTED_NAME${GREEN} (機號 $DETECTED_DEVICE)${NC}"
        read -p "是否正確？(y/n): " CONFIRM
        if [[ $CONFIRM == [Yy]* ]]; then
            SELECTED_DEVICE=$DETECTED_DEVICE
        else
            SELECTED_DEVICE=""
        fi
    fi
    
    # 如果沒有自動檢測到或用戶不確認，則手動選擇
    if [ -z "$SELECTED_DEVICE" ]; then
        echo -e "\n${YELLOW}請選擇您的機台編號 (1-$DEVICE_COUNT):${NC}"
        read -p "機號: " SELECTED_DEVICE
        
        # 驗證選擇是否有效
        if ! [[ "$SELECTED_DEVICE" =~ ^[0-9]+$ ]] || [ $SELECTED_DEVICE -lt 1 ] || [ $SELECTED_DEVICE -gt $DEVICE_COUNT ]; then
            log_error "無效的機號 $SELECTED_DEVICE"
            exit 1
        fi
    fi
    
    # 設置對應的配置檔案
    DEVICE_INDEX=$((SELECTED_DEVICE-1))
    DEVICE_CONFIG=$(jq -c ".devices[$DEVICE_INDEX]" $DEVICES_JSON)
    DEVICE_NAME=$(jq -r ".devices[$DEVICE_INDEX].name" $DEVICES_JSON)
    DEVICE_ID=$(jq -r ".devices[$DEVICE_INDEX].id" $DEVICES_JSON)
    
    echo -e "\n${GREEN}選擇了 ${YELLOW}$DEVICE_NAME${NC}"
    echo -e "${GREEN}配置信息:${NC} $DEVICE_CONFIG"
    
    # 輸出到單獨的配置檔
    echo "$DEVICE_CONFIG" > device-$SELECTED_DEVICE.json
    log_info "已創建設備配置文件: device-$SELECTED_DEVICE.json"
    
    DEVICE_CONFIG_FILE="device-$SELECTED_DEVICE.json"
else
    # 如果沒有 jq，提示手動選擇
    log_warn "未安裝 jq 工具，無法自動解析設備配置"
    log_warn "請確保已創建對應您機台的配置文件 (device-X.json)"
    
    # 檢查是否有設備配置檔案
    DEVICE_FILES=( device-*.json )
    if [ ${#DEVICE_FILES[@]} -eq 0 ]; then
        log_error "找不到任何 device-X.json 配置檔案"
        exit 1
    fi
    
    echo -e "${GREEN}發現以下設備配置:${NC}"
    for i in "${!DEVICE_FILES[@]}"; do
        echo -e "$((i+1)). ${YELLOW}${DEVICE_FILES[$i]}${NC}"
    done
    
    echo -e "\n${YELLOW}請選擇您的機台配置 (1-${#DEVICE_FILES[@]}):${NC}"
    read -p "選擇: " SELECTED_INDEX
    
    # 驗證選擇是否有效
    if ! [[ "$SELECTED_INDEX" =~ ^[0-9]+$ ]] || [ $SELECTED_INDEX -lt 1 ] || [ $SELECTED_INDEX -gt ${#DEVICE_FILES[@]} ]; then
        log_error "無效的選擇 $SELECTED_INDEX"
        exit 1
    fi
    
    DEVICE_CONFIG_FILE="${DEVICE_FILES[$((SELECTED_INDEX-1))]}"
    log_info "已選擇設備配置: $DEVICE_CONFIG_FILE"
    
    # 嘗試從文件名提取機號
    SELECTED_DEVICE=$(echo $DEVICE_CONFIG_FILE | grep -o '[0-9]\+' | head -1)
    
    # 嘗試從文件提取ID
    if command -v grep > /dev/null && command -v sed > /dev/null; then
        DEVICE_ID=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' $DEVICE_CONFIG_FILE | sed 's/"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    fi
fi

# 中央伺服器配置
echo -e "\n${GREEN}設定中央伺服器...${NC}"
read -p "請輸入中央伺服器IP地址: " SERVER_IP
if [ -z "$SERVER_IP" ]; then
    log_error "伺服器IP不能為空"
    exit 1
fi
PUSH_GATEWAY="http://${SERVER_IP}:9091"
log_info "Push Gateway 地址: $PUSH_GATEWAY"

# 本地HTTP服務埠配置
echo -e "\n${GREEN}設定本地HTTP服務...${NC}"
read -p "請輸入本地HTTP服務埠 (默認8000，輸入0禁用): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8000}
if [ "$LOCAL_PORT" -eq 0 ]; then
    log_warn "本地HTTP服務已禁用"
else
    log_info "本地HTTP服務將在埠號 $LOCAL_PORT 啟動"
fi

# 收集間隔配置
echo -e "\n${GREEN}設定數據收集間隔...${NC}"
read -p "請輸入數據收集間隔秒數 (默認5秒): " INTERVAL
INTERVAL=${INTERVAL:-5}
log_info "數據收集間隔: $INTERVAL 秒"

# 檢查是否已存在 collector_agent.py
if [ ! -f "collector_agent.py" ] && [ ! -f "$SCRIPT_DIR/collector_agent.py" ]; then
    log_error "找不到 collector_agent.py"
    exit 1
elif [ ! -f "collector_agent.py" ]; then
    cp $SCRIPT_DIR/collector_agent.py .
    log_info "已複製 collector_agent.py 到當前目錄"
fi

# 檢查是否已存在 plc_points.json
POINTS_FILE=""
if [ -f "plc_points.json" ]; then
    POINTS_FILE="plc_points.json"
elif [ -f "$PARENT_DIR/config/plc_points.json" ]; then
    POINTS_FILE="$PARENT_DIR/config/plc_points.json"
    cp $POINTS_FILE .
    POINTS_FILE="plc_points.json"
    log_info "已複製 plc_points.json 到當前目錄"
else
    log_error "找不到 plc_points.json"
    exit 1
fi

# 保存配置到環境文件
save_config_env "$DEVICE_ID" "$DEVICE_CONFIG_FILE" "$SERVER_IP" "$PUSH_GATEWAY" "$LOCAL_PORT" "$INTERVAL"

# 建立啟動腳本
create_start_script "$DEVICE_CONFIG_FILE" "$POINTS_FILE" "$PUSH_GATEWAY" "$LOCAL_PORT" "$INTERVAL"

# 建立系統服務
SERVICE_NAME="modbus-collector"
create_systemd_service "$SERVICE_NAME" "$(pwd)" "$DEVICE_CONFIG_FILE" "$POINTS_FILE" "$PUSH_GATEWAY" "$LOCAL_PORT" "$INTERVAL"

# 顯示啟動命令
log_info "啟動命令:"
echo -e "python collector_agent.py --config \"$DEVICE_CONFIG_FILE\" --points \"$POINTS_FILE\" --push-gateway \"$PUSH_GATEWAY\" --port \"$LOCAL_PORT\" --interval \"$INTERVAL\""

# 詢問用戶是否立即啟動服務
echo -e "\n${YELLOW}服務已準備就緒。選擇啟動方式:${NC}"
echo -e "1. 使用系統服務啟動 (systemd)"
echo -e "2. 使用腳本啟動 (start_service.sh)"
echo -e "3. 暫不啟動"
read -p "請選擇 (1-3): " START_OPTION

case $START_OPTION in
    1)
        log_info "正在啟用並啟動系統服務..."
        start_systemd_service "$SERVICE_NAME"
        log_info "服務已啟動!"
        echo -e "可以使用以下命令查看服務狀態:"
        echo -e "${YELLOW}sudo systemctl status $SERVICE_NAME${NC}"
        ;;
    2)
        log_info "使用腳本啟動服務..."
        ./start_service.sh
        ;;
    *)
        log_warn "服務未啟動。您可以稍後手動啟動:"
        echo -e "系統服務: ${YELLOW}sudo systemctl start $SERVICE_NAME${NC}"
        echo -e "或使用腳本: ${YELLOW}./start_service.sh${NC}"
        ;;
esac

# 顯示總結訊息
echo
log_header "設定完成！收集代理已配置"
echo
echo -e "配置摘要:"
echo -e "${YELLOW}設備ID:${NC} $DEVICE_ID"
echo -e "${YELLOW}設備配置:${NC} $DEVICE_CONFIG_FILE"
echo -e "${YELLOW}中央伺服器:${NC} $SERVER_IP"
echo -e "${YELLOW}Push Gateway:${NC} $PUSH_GATEWAY"
echo -e "${YELLOW}本地HTTP埠:${NC} $LOCAL_PORT"
echo -e "${YELLOW}收集間隔:${NC} $INTERVAL 秒"
echo
echo -e "日誌文件:"
echo -e "${YELLOW}系統服務日誌:${NC} journalctl -u $SERVICE_NAME -f"
echo -e "${YELLOW}腳本日誌:${NC} logs/collector_*.log"
echo
log_header "配置完成"
