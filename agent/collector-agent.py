import struct
import json
import time
import logging
import socket
import requests
import argparse
from pathlib import Path
from pymodbus.client import ModbusTcpClient
from prometheus_client import start_http_server, Gauge, Counter, push_to_gateway

# 設定記錄
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("collector_agent.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class ModbusCollectorAgent:
    def __init__(self, device_config, points_file="plc_points.json", push_gateway=None):
        """
        初始化單一設備的數據收集代理
        
        Args:
            device_config: 單個設備的配置（字典或JSON字符串）
            points_file: 點位配置文件路徑
            push_gateway: Prometheus push gateway 的URL（如果使用集中式收集）
        """
        self.metrics = {}  # 存儲所有指標
        
        # 載入設備配置
        if isinstance(device_config, str):
            self.device = json.loads(device_config)
        else:
            self.device = device_config
            
        self.device['current_ip'] = self.device['primary_ip']  # 初始使用主要 IP
        self.device['last_fail_time'] = 0  # 上次連接失敗時間
        self.device['connection_state'] = 'disconnected'  # 初始狀態為未連接
        
        # 獲取主機名稱作為實例標識
        self.hostname = socket.gethostname()
        
        # 載入點位配置
        self.load_points_config(points_file)
        
        # 創建指標
        self.create_metrics()
        
        # 設備連接和監控指標
        self.device_connection_status = Gauge('device_connection_status', '設備連接狀態 (1=連接, 0=斷開)', ['device', 'ip', 'host'])
        self.device_read_total = Counter('device_read_total', '設備讀取總次數', ['device', 'ip', 'host'])
        self.device_read_errors = Counter('device_read_errors', '設備讀取錯誤次數', ['device', 'ip', 'host'])
        self.device_read_duration = Gauge('device_read_duration', '設備讀取耗時(秒)', ['device', 'ip', 'host'])
        
        # Push gateway 設定
        self.push_gateway = push_gateway
    
    def load_points_config(self, points_file):
        """載入點位配置"""
        try:
            with open(points_file, 'r', encoding='utf-8') as f:
                self.point_groups = json.load(f)['metric_groups']
                total_points = sum(len(group['metrics']) for group in self.point_groups)
                logger.info(f"已載入 {len(self.point_groups)} 組點位，共 {total_points} 個監控點")
        except Exception as e:
            logger.error(f"載入點位配置文件時發生錯誤: {e}")
            raise
    
    def create_metrics(self):
        """為所有監控點創建 Prometheus 指標"""
        for group in self.point_groups:
            for metric in group['metrics']:
                metric_id = metric['id']
                metric_name = metric['name']
                
                # 創建指標，添加設備和主機標籤
                self.metrics[metric_id] = Gauge(
                    f"{metric_id}", 
                    f"{metric_name} ({metric.get('unit', '')})",
                    ['device', 'host']
                )
                logger.debug(f"創建指標: {metric_id} - {metric_name}")
    
    def connect_device(self):
        """嘗試連接到設備，如主要 IP 失敗則嘗試備用 IP"""
        now = time.time()
        retry_interval = self.device.get('retry_interval', 60)  # 默認重試間隔為60秒
        
        # 如果處於重試冷卻期，繼續使用上次失敗的 IP
        if now - self.device['last_fail_time'] < retry_interval and self.device['connection_state'] == 'failed':
            return None
            
        # 確定要使用的 IP
        ip_to_use = self.device['current_ip']
        
        try:
            client = ModbusTcpClient(
                host=ip_to_use,
                port=self.device['port'],
                timeout=self.device.get('timeout', 3)
            )
            
            if client.connect():
                logger.info(f"已連接到設備 {self.device['name']} ({ip_to_use})")
                self.device['connection_state'] = 'connected'
                self.device_connection_status.labels(
                    device=self.device['id'], 
                    ip=ip_to_use,
                    host=self.hostname
                ).set(1)
                return client
            else:
                # 連接失敗，嘗試切換 IP
                self._handle_connection_failure(ip_to_use)
                return None
                
        except Exception as e:
            logger.error(f"連接設備 {self.device['name']} ({ip_to_use}) 時發生錯誤: {e}")
            self._handle_connection_failure(ip_to_use)
            return None
    
    def _handle_connection_failure(self, failed_ip):
        """處理連接失敗情況，切換 IP 並更新狀態"""
        logger.warning(f"連接設備 {self.device['name']} ({failed_ip}) 失敗")
        self.device['last_fail_time'] = time.time()
        self.device['connection_state'] = 'failed'
        self.device_connection_status.labels(
            device=self.device['id'], 
            ip=failed_ip,
            host=self.hostname
        ).set(0)
        
        # 切換到另一個 IP
        if failed_ip == self.device['primary_ip']:
            self.device['current_ip'] = self.device['backup_ip']
            logger.info(f"切換到備用 IP: {self.device['backup_ip']}")
        else:
            self.device['current_ip'] = self.device['primary_ip']
            logger.info(f"切換到主要 IP: {self.device['primary_ip']}")
    
    def read_modbus(self, client, device_id, start_address, count):
        """讀取 Modbus 資料"""
        try:
            # 將 40001 基址轉換為 0
            relative_address = start_address - 40001
            logger.debug(f"從設備 {device_id} 讀取 {count} 個寄存器，起始位址 {relative_address}")

            result = client.read_holding_registers(relative_address, count, slave=device_id)
            if not result.isError():
                return result.registers

            logger.error(f"從設備 {device_id}，地址 {start_address} 讀取錯誤: {result}")
            return None
        except Exception as e:
            logger.error(f"從設備 {device_id}，地址 {start_address} 讀取時發生異常: {e}")
            return None
    
    def process_data(self, group, registers):
        """處理讀取到的數據，更新 metrics"""
        if not registers:
            return
            
        for metric in group['metrics']:
            try:
                offset = metric['register_offset']
                data_type = metric.get('data_type', 'INT16')
                scale_factor = metric.get('scale_factor', 1.0)
                
                if data_type == 'INT16':
                    # 處理 INT16 數據
                    if offset < len(registers):
                        value = registers[offset] / scale_factor
                        self.metrics[metric['id']].labels(
                            device=self.device['id'],
                            host=self.hostname
                        ).set(value)
                        logger.debug(f"更新指標 {metric['id']} = {value}")
                    
                elif data_type == 'FLOAT32' and offset + 1 < len(registers):
                    # 處理 FLOAT32 數據（佔用兩個寄存器）
                    hi = registers[offset]
                    lo = registers[offset + 1]
                    raw_data = struct.pack('>HH', hi, lo)
                    value = struct.unpack('>f', raw_data)[0]
                    self.metrics[metric['id']].labels(
                        device=self.device['id'],
                        host=self.hostname
                    ).set(value)
                    logger.debug(f"更新指標 {metric['id']} = {value}")
            
            except Exception as e:
                logger.error(f"處理指標 {metric['id']} 時發生錯誤: {e}")
    
    def collect_data(self):
        """收集設備的所有數據"""
        start_time = time.time()
        client = self.connect_device()
        
        if client:
            try:
                current_ip = self.device['current_ip']
                self.device_read_total.labels(
                    device=self.device['id'], 
                    ip=current_ip,
                    host=self.hostname
                ).inc()
                
                # 收集每組數據
                for group in self.point_groups:
                    registers = self.read_modbus(
                        client, 
                        group['device_id'], 
                        group['start_address'], 
                        group['count']
                    )
                    
                    if registers:
                        self.process_data(group, registers)
                    else:
                        self.device_read_errors.labels(
                            device=self.device['id'], 
                            ip=current_ip,
                            host=self.hostname
                        ).inc()
                
                # 如果有設置 push gateway，則推送數據
                if self.push_gateway:
                    try:
                        push_to_gateway(
                            self.push_gateway, 
                            job=f'modbus_collector_{self.device["id"]}',
                            registry=None  # 使用默認註冊表
                        )
                        logger.info(f"成功推送數據到 {self.push_gateway}")
                    except Exception as e:
                        logger.error(f"推送數據到 {self.push_gateway} 時發生錯誤: {e}")
                
            except Exception as e:
                logger.error(f"從設備 {self.device['name']} 收集數據時發生錯誤: {e}")
                self.device_read_errors.labels(
                    device=self.device['id'], 
                    ip=self.device['current_ip'],
                    host=self.hostname
                ).inc()
            finally:
                client.close()
                
        # 記錄讀取時間
        duration = time.time() - start_time
        self.device_read_duration.labels(
            device=self.device['id'], 
            ip=self.device['current_ip'],
            host=self.hostname
        ).set(duration)
        logger.debug(f"設備 {self.device['name']} 資料收集完成，耗時 {duration:.3f} 秒")
    
    def run(self, interval=5):
        """啟動收集程序"""
        while True:
            try:
                logger.info("開始收集數據...")
                self.collect_data()
                logger.info(f"數據收集完成，等待 {interval} 秒後再次收集")
            except Exception as e:
                logger.error(f"收集過程中發生錯誤: {e}")
            
            time.sleep(interval)

def main():
    parser = argparse.ArgumentParser(description='Modbus 收集代理')
    parser.add_argument('--config', required=True, help='單設備配置文件路徑或JSON字符串')
    parser.add_argument('--points', default="plc_points.json", help='點位配置文件路徑')
    parser.add_argument('--push-gateway', help='Prometheus Push Gateway 地址')
    parser.add_argument('--port', type=int, default=0, help='本地Prometheus HTTP服務埠，0表示不啟動本地服務')
    parser.add_argument('--interval', type=int, default=5, help='收集間隔（秒）')
    
    args = parser.parse_args()
    
    # 讀取設備配置
    if Path(args.config).exists():
        with open(args.config, 'r', encoding='utf-8') as f:
            device_config = json.load(f)
    else:
        device_config = args.config  # 假設是JSON字符串
    
    # 如果提供了HTTP埠，則啟動本地Prometheus服務
    if args.port > 0:
        start_http_server(args.port)
        logger.info(f"Prometheus 指標服務已在 {args.port} 埠啟動")
    
    # 啟動收集代理
    collector = ModbusCollectorAgent(device_config, args.points, args.push_gateway)
    collector.run(interval=args.interval)

if __name__ == '__main__':
    main()
