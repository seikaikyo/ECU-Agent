# 分佈式 Modbus 資料收集系統

這個系統實現了一個分佈式架構的 Modbus 資料收集解決方案，由以下組件組成：

1. **收集代理 (Collector Agent)** - 部署在每台機器上，負責直接與 PLC 通訊並收集資料
2. **中央伺服器 (Central Server)** - 部署單一服務器上，負責彙總所有代理收集的資料
3. **監控和視覺化** - 使用 Prometheus 和 Grafana 提供數據存儲和可視化

## 系統架構

```
機台1 [收集代理] ──┐
機台2 [收集代理] ──┼─→ [Push Gateway] → [Prometheus] → [Grafana]
機台3 [收集代理] ──┤
機台4 [收集代理] ──┘
                  中央伺服器
```

## 專案目錄結構

```
/
├── agent/                           # 代理端程式
│   ├── collector_agent.py           # 代理主程式
│   ├── start_agent.sh               # 互動式安裝腳本
│   ├── deploy_agent.sh              # CI/CD 部署腳本
│   └── templates/                   # 腳本模板目錄
│
├── server/                          # 伺服器端程式
│   ├── setup_server.sh              # 中央伺服器設定腳本
│   └── templates/                   # 配置模板目錄
│       ├── docker-compose.yml       # Docker Compose 模板
│       ├── prometheus.yml           # Prometheus 配置模板
│       └── grafana-dashboard.json   # Grafana 儀表板模板
│
├── config/                          # 配置文件
│   ├── devices/                     # 設備配置目錄
│   │   ├── devices.json             # 設備集中配置
│   │   └── device-X.json            # 單機配置
│   └── plc_points.json              # PLC 點位配置
│
├── scripts/                         # 共用腳本
│   ├── utils.sh                     # 共用函數庫
│   └── install_deps.sh              # 依賴安裝腳本
│
└── ci/                              # CI/CD 配置
    └── .gitlab-ci.yml               # GitLab CI/CD 配置
```

## 安裝指南

### 1. 中央伺服器安裝

1. 完整複製此專案到伺服器：

```bash
git clone https://your-repository-url.git modbus-system
cd modbus-system
```

2. 執行伺服器設定腳本：

```bash
sudo ./server/setup_server.sh
```

此腳本會：
- 安裝必要的依賴 (Docker, Docker Compose 等)
- 建立數據存儲目錄
- 設定並啟動 Prometheus, Push Gateway 和 Grafana 服務
- 生成所有必要的配置文件

安裝完成後，可以通過以下網址訪問服務：
- Prometheus: http://伺服器IP:9090
- Push Gateway: http://伺服器IP:9091
- Grafana: http://伺服器IP:3000 (預設用戶名/密碼: admin/admin)

### 2. 代理端安裝

#### 方法 A: 互動式安裝（適合手動部署）

1. 將必要文件複製到目標機器：

```bash
# 從中央伺服器複製
scp -r 中央伺服器IP:/path/to/modbus-system/config/scripts/* .
scp -r 中央伺服器IP:/path/to/modbus-system/config/devices/devices.json .
scp -r 中央伺服器IP:/path/to/modbus-system/config/plc_points.json .

# 或直接從版本控制系統獲取
git clone https://your-repository-url.git modbus-agent
cd modbus-agent
```

2. 執行互動式安裝腳本：

```bash
chmod +x start_agent.sh
./start_agent.sh
```

3. 根據互動式提示完成設定和啟動服務。腳本會：
   - 自動檢測當前機器是哪一台設備
   - 引導您設定中央伺服器IP、服務埠等參數
   - 提供多種啟動方式選擇

#### 方法 B: 自動部署（適合 CI/CD）

1. 在 GitLab 中設定 CI/CD 變量：
   - `SERVER_IP`: 中央伺服器 IP
   - 可選：`LOCAL_PORT`, `INTERVAL` 等

2. 在每台機器上設定 GitLab Runner，並設定對應的機器標籤：
   - 1號機：標籤 `agent1`
   - 2號機：標籤 `agent2`
   - 依此類推

3. 推送代碼到 GitLab，CI/CD 流程會自動部署到標記的機器

4. 也可以手動執行部署腳本：

```bash
./deploy_agent.sh --device=1 --server=192.168.1.100
```

## 數據永久保存

中央伺服器已配置為數據永久保存，存儲在以下位置：

- Prometheus 數據: `/data/prometheus`
- Push Gateway 數據: `/data/pushgateway`
- Grafana 數據: `/data/grafana`

## 配置說明

### 設備配置 (devices.json)

集中配置文件包含所有機台的信息：

```json
{
  "devices": [
    {
      "id": "ecu1051_1",  // 機台唯一識別碼
      "name": "1號機",    // 顯示名稱
      "primary_ip": "主要IP",  // 主要 Modbus TCP IP
      "backup_ip": "備用IP",   // 備用 Modbus TCP IP
      "port": 502,             // Modbus TCP 通訊埠
      "timeout": 3,            // 連線超時時間 (秒)
      "retry_interval": 60     // 重試間隔 (秒)
    },
    // 其他機台...
  ]
}
```

### PLC 點位配置 (plc_points.json)

定義所有需要收集的 PLC 數據點：

```json
{
  "metric_groups": [
    {
      "group_name": "溫度控制器",
      "device_id": 1,          // Modbus 設備 ID
      "start_address": 40001,  // 起始地址
      "count": 78,             // 連續讀取的暫存器數量
      "metrics": [
        {
          "id": "left_main_temp_pv",  // 指標識別碼
          "name": "左側主控_PV",      // 顯示名稱
          "register_offset": 0,       // 相對 start_address 的偏移量
          "data_type": "INT16",       // 數據類型 (INT16 或 FLOAT32)
          "scale_factor": 10.0,       // 比例因子
          "unit": "℃"                // 單位
        },
        // 其他點位...
      ]
    },
    // 其他組...
  ]
}
```

## 操作與維護

### 檢查代理狀態

```bash
# 查看代理日誌
tail -f logs/collector_*.log

# 檢查代理進程
ps aux | grep collector_agent.py

# 查看系統服務狀態
sudo systemctl status modbus-collector
```

### 檢查中央伺服器狀態

```bash
# 檢查容器狀態
docker ps

# 查看容器日誌
docker logs prometheus
docker logs pushgateway
docker logs grafana

# 重啟服務
docker-compose restart
```

### 更新配置

1. 修改設備配置：
   ```bash
   # 編輯 devices.json
   vi config/devices/devices.json
   
   # 重新生成獨立配置文件
   jq ".devices[0]" config/devices/devices.json > config/devices/device-1.json
   ```

2. 重新部署代理：
   ```bash
   # 互動式部署
   ./agent/start_agent.sh
   
   # 自動部署
   ./agent/deploy_agent.sh --device=1 --server=192.168.1.100
   ```

## 故障排除

### 代理連接問題

1. **無法連接到 PLC**：
   - 確認 PLC 的 IP 地址可以 ping 通
   - 檢查防火牆設置，確保 Modbus TCP 通訊埠 (502) 開放
   - 確認 primary_ip 和 backup_ip 設定正確

2. **連接中斷**：
   - 查看日誌檔案中的詳細錯誤訊息
   - 檢查網絡連接，可能有間歇性斷網

### 資料推送問題

1. **無法推送到 Push Gateway**：
   - 確認中央伺服器的 Push Gateway 可以訪問
   - 檢查防火牆設置，確保通訊埠 (9091) 開放
   - 確認 SERVER_IP 設定正確

2. **數據未顯示在 Grafana**：
   - 在 Prometheus 界面檢查資料是否正確收集
   - 確認 Grafana 數據源連接正確
   - 檢查 Grafana 查詢表達式是否正確

### 系統維護

1. **磁碟空間不足**：
   - 監控 `/data` 目錄的使用情況：`df -h /data`
   - 考慮設定 Prometheus 數據保留策略
   - 必要時擴展磁碟空間

2. **服務無響應**：
   - 檢查 Docker 服務狀態：`sudo systemctl status docker`
   - 重啟服務：`docker-compose restart`
   - 檢查系統資源使用情況：`htop`

## 開發指南

### 擴展點位配置

1. 添加新的點位組：
   - 編輯 `plc_points.json`
   - 添加新的 `metric_groups` 項
   - 定義所有需要的 `metrics`

2. 添加新的設備：
   - 編輯 `devices.json`
   - 添加新的設備配置
   - 更新 CI/CD 配置和標籤

### 版本發佈流程

1. 更新版本號：
   ```bash
   echo "v$(date +%Y%m%d)-$(git rev-parse --short HEAD)" > VERSION
   ```

2. 打標籤和發佈：
   ```bash
   VERSION=$(cat VERSION)
   git tag -a "$VERSION" -m "Release $VERSION"
   git push origin "$VERSION"
   ```

3. GitLab CI/CD 將自動部署到所有機器

## 授權和貢獻

本專案遵循 [LICENSE] 授權協議。歡迎提交 Issue 和 Pull Request。
