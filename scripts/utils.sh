#!/bin/bash
# 共用函數庫

# 設定顏色輸出
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export NC='\033[0m' # No Color

# 顯示彩色訊息
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

log_header() {
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}  $1  ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo
}

# 檢查是否已安裝必要工具
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_warn "$1 未安裝"
        return 1
    else
        log_info "$1 已安裝"
        return 0
    fi
}

# 檢查 Python 套件
check_python_package() {
    if ! python -c "import $1" &> /dev/null; then
        log_warn "缺少 Python 套件: $1"
        return 1
    else
        log_info "已安裝 Python 套件: $1"
        return 0
    fi
}

# 檢測設備 IP 地址
detect_device_ip() {
    local json_file=$1
    local host_ips=$(hostname -I)
    
    if ! check_command "jq"; then
        log_error "無法檢測設備: 未安裝 jq"
        return 1
    fi
    
    local device_count=$(jq '.devices | length' $json_file)
    log_info "找到 $device_count 台設備配置"
    
    for i in $(seq 0 $(($device_count-1))); do
        local primary_ip=$(jq -r ".devices[$i].primary_ip" $json_file)
        local backup_ip=$(jq -r ".devices[$i].backup_ip" $json_file)
        
        if [[ $host_ips == *"$primary_ip"* ]] || [[ $host_ips == *"$backup_ip"* ]]; then
            local device_id=$((i+1))
            local device_name=$(jq -r ".devices[$i].name" $json_file)
            echo "$device_id:$device_name"
            return 0
        fi
    done
    
    return 1  # 未檢測到匹配的設備
}

# 從 devices.json 中提取單個設備配置
extract_device_config() {
    local json_file=$1
    local device_index=$2
    local output_file=$3
    
    if ! check_command "jq"; then
        log_error "無法提取設備配置: 未安裝 jq"
        return 1
    fi
    
    jq -c ".devices[$((device_index-1))]" $json_file > $output_file
    if [ $? -eq 0 ]; then
        log_info "已提取設備配置到: $output_file"
        return 0
    else
        log_error "提取設備配置失敗"
        return 1
    fi
}

# 建立系統服務
create_systemd_service() {
    local service_name=$1
    local working_dir=$2
    local config_file=$3
    local points_file=$4
    local push_gateway=$5
    local port=$6
    local interval=$7
    local service_file="/etc/systemd/system/${service_name}.service"
    
    cat > "${service_name}.service" << EOL
[Unit]
Description=Modbus Collector Agent
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$working_dir
ExecStart=$(which python) $working_dir/collector_agent.py --config "$config_file" --points "$points_file" --push-gateway "$push_gateway" --port "$port" --interval "$interval"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL
    
    log_info "已建立服務配置文件: ${service_name}.service"
    return 0
}

# 啟動系統服務
start_systemd_service() {
    local service_name=$1
    local service_file="/etc/systemd/system/${service_name}.service"
    
    if [ ! -f "${service_name}.service" ]; then
        log_error "服務文件不存在: ${service_name}.service"
        return 1
    fi
    
    sudo cp "${service_name}.service" "$service_file"
    sudo systemctl daemon-reload
    sudo systemctl enable $service_name
    sudo systemctl restart $service_name
    
    log_info "服務已啟動: $service_name"
    return 0
}

# 建立啟動腳本
create_start_script() {
    local config_file=$1
    local points_file=$2
    local push_gateway=$3
    local port=$4
    local interval=$5
    local output_file="start_service.sh"
    
    cat > $output_file << EOL
#!/bin/bash
python collector_agent.py \\
  --config "$config_file" \\
  --points "$points_file" \\
  --push-gateway "$push_gateway" \\
  --port "$port" \\
  --interval "$interval" > logs/collector_\$(date +%Y%m%d).log 2>&1 &

echo "收集代理已啟動，進程 ID: \$!"
EOL
    
    chmod +x $output_file
    log_info "已建立啟動腳本: $output_file"
    return 0
}

# 保存配置到環境文件
save_config_env() {
    local device_id=$1
    local config_file=$2
    local server_ip=$3
    local push_gateway=$4
    local port=$5
    local interval=$6
    local output_dir="config"
    
    mkdir -p $output_dir
    
    cat > $output_dir/agent_config.env << EOL
# Modbus 收集代理配置
# 生成於 $(date)

# 設備信息
DEVICE_ID="$device_id"
DEVICE_CONFIG="$config_file"

# 伺服器信息
SERVER_IP="$server_ip"
PUSH_GATEWAY="$push_gateway"

# 運行配置
LOCAL_PORT=$port
INTERVAL=$interval
EOL
    
    log_info "已保存配置到: $output_dir/agent_config.env"
    return 0
}
