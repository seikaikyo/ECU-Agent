#!/bin/bash
# 依賴安裝腳本

# 載入共用函數
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $SCRIPT_DIR/utils.sh

log_header "依賴安裝"

# 檢查並安裝系統依賴
install_system_deps() {
    log_info "檢查系統依賴..."
    
    local missing_deps=0
    local to_install=""
    
    # 檢查 jq
    if ! check_command "jq"; then
        missing_deps=1
        to_install="$to_install jq"
    fi
    
    # 如果是伺服器安裝，檢查 Docker 相關套件
    if [ "$1" == "server" ]; then
        # 檢查 Docker
        if ! check_command "docker"; then
            missing_deps=1
            to_install="$to_install docker.io"
        fi
        
        # 檢查 Docker Compose
        if ! check_command "docker-compose"; then
            missing_deps=1
            to_install="$to_install docker-compose"
        fi
    fi
    
    # 如果有缺少的依賴，詢問是否安裝
    if [ $missing_deps -eq 1 ]; then
        log_warn "缺少系統依賴: $to_install"
        
        if [ -z "$AUTO_INSTALL" ]; then
            read -p "是否安裝缺少的系統依賴? (y/n): " install_deps
            if [[ $install_deps != [Yy]* ]]; then
                log_warn "跳過安裝系統依賴"
                return 1
            fi
        fi
        
        log_info "安裝系統依賴..."
        sudo apt-get update
        sudo apt-get install -y $to_install
        
        # 如果是伺服器安裝，啟用 Docker 服務
        if [ "$1" == "server" ] && [[ $to_install == *"docker"* ]]; then
            log_info "啟用 Docker 服務..."
            sudo systemctl enable docker
            sudo systemctl start docker
        fi
        
        log_info "系統依賴安裝完成"
    else
        log_info "所有系統依賴已安裝"
    fi
    
    return 0
}

# 檢查並安裝 Python 依賴
install_python_deps() {
    log_info "檢查 Python 依賴..."
    
    local missing_deps=0
    local to_install=""
    
    # 檢查 pymodbus
    if ! check_python_package "pymodbus"; then
        missing_deps=1
        to_install="$to_install pymodbus"
    fi
    
    # 檢查 prometheus_client
    if ! check_python_package "prometheus_client"; then
        missing_deps=1
        to_install="$to_install prometheus-client"
    fi
    
    # 檢查 requests
    if ! check_python_package "requests"; then
        missing_deps=1
        to_install="$to_install requests"
    fi
    
    # 如果有缺少的依賴，詢問是否安裝
    if [ $missing_deps -eq 1 ]; then
        log_warn "缺少 Python 依賴: $to_install"
        
        if [ -z "$AUTO_INSTALL" ]; then
            read -p "是否安裝缺少的 Python 依賴? (y/n): " install_deps
            if [[ $install_deps != [Yy]* ]]; then
                log_warn "跳過安裝 Python 依賴"
                return 1
            fi
        fi
        
        log_info "安裝 Python 依賴..."
        pip install $to_install
        
        log_info "Python 依賴安裝完成"
    else
        log_info "所有 Python 依賴已安裝"
    fi
    
    return 0
}

# 主安裝函數
main() {
    local mode=${1:-"agent"}  # 預設為 agent 模式
    
    # 安裝系統依賴
    install_system_deps $mode
    
    # 如果是 agent 模式，安裝 Python 依賴
    if [ "$mode" == "agent" ]; then
        install_python_deps
    fi
    
    log_info "依賴安裝檢查完成"
}

# 執行主函數
main "$@"
