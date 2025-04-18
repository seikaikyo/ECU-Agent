# 依賴安裝腳本 (Windows版)

# 載入共用函數
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$SCRIPT_DIR\utils.ps1"

Write-Title "依賴安裝"

# 檢查並安裝系統依賴
function Install-SystemDeps {
    param (
        [Parameter(Mandatory=$false)]
        [string]$Mode = "agent"
    )
    
    Write-Info "檢查系統依賴..."
    
    $MissingDeps = $false
    $ToInstall = @()
    
    # 檢查是否有 Chocolatey 包管理器
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warning "未安裝 Chocolatey 包管理器，建議安裝以簡化依賴管理"
        Write-Host "可以從 https://chocolatey.org/install 安裝 Chocolatey" -ForegroundColor Cyan
        $InstallChoco = Read-Host "是否要安裝 Chocolatey? (y/n)"
        
        if ($InstallChoco -match "^[Yy]") {
            Write-Info "安裝 Chocolatey..."
            
            # 檢查是否以管理員權限運行
            $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
            
            if (-not $IsAdmin) {
                Write-Error "需要管理員權限安裝 Chocolatey，請以管理員身份重新運行此腳本"
                return $false
            }
            
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
                Write-Info "Chocolatey 安裝完成"
            } catch {
                Write-Error "安裝 Chocolatey 失敗: $_"
                Write-Host "請訪問 https://chocolatey.org/install 手動安裝" -ForegroundColor Cyan
                $MissingDeps = $true
            }
        } else {
            Write-Warning "跳過安裝 Chocolatey"
            $MissingDeps = $true
        }
    }
    
    # 檢查 PowerShell 版本
    $PSVersion = $PSVersionTable.PSVersion
    Write-Info "PowerShell 版本: $($PSVersion.Major).$($PSVersion.Minor)"
    
    if ($PSVersion.Major -lt 5) {
        Write-Warning "PowerShell 版本低於 5.0，某些功能可能無法正常工作"
        Write-Host "建議升級到 PowerShell 5.1 或更高版本" -ForegroundColor Cyan
    }
    
    # 檢查是否已安裝 Python
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Warning "Python 未安裝"
        $ToInstall += "python"
        $MissingDeps = $true
    } else {
        Write-Info "已安裝 Python: $(python --version)"
    }
    
    # 如果是伺服器安裝，檢查 Docker 相關套件
    if ($Mode -eq "server") {
        # 檢查 Docker
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Warning "Docker 未安裝"
            $ToInstall += "docker-desktop"
            $MissingDeps = $true
        } else {
            Write-Info "已安裝 Docker: $(docker --version)"
        }
        
        # 檢查 Docker Compose
        $DockerCompose = $null
        try {
            $DockerCompose = docker compose version
        } catch {
            $DockerCompose = $null
        }
        
        if ($DockerCompose -eq $null) {
            Write-Warning "Docker Compose 未安裝或未啟用"
            if (-not ($ToInstall -contains "docker-desktop")) {
                Write-Host "可能需要啟用 Docker Compose V2" -ForegroundColor Cyan
            }
        } else {
            Write-Info "已安裝 Docker Compose: $DockerCompose"
        }
    }
    
    # 如果有缺少的依賴，詢問是否安裝
    if ($MissingDeps -and $ToInstall.Count -gt 0) {
        Write-Warning "缺少系統依賴: $($ToInstall -join ', ')"
        
        if (-not $env:AUTO_INSTALL) {
            $InstallDeps = Read-Host "是否安裝缺少的系統依賴? (y/n)"
            if ($InstallDeps -notmatch "^[Yy]") {
                Write-Warning "跳過安裝系統依賴"
                return $false
            }
        }
        
        # 檢查是否以管理員權限運行
        $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        
        if (-not $IsAdmin) {
            Write-Error "需要管理員權限安裝依賴，請以管理員身份重新運行此腳本"
            return $false
        }
        
        Write-Info "安裝系統依賴..."
        
        # 使用 Chocolatey 安裝依賴
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            foreach ($Pkg in $ToInstall) {
                Write-Host "安裝 $Pkg..." -ForegroundColor Cyan
                try {
                    choco install $Pkg -y
                } catch {
                    Write-Error "安裝 $Pkg 失敗: $_"
                }
            }
        } else {
            # 如果沒有 Chocolatey，提供手動安裝說明
            Write-Warning "無法自動安裝依賴，請手動安裝以下軟件:"
            foreach ($Pkg in $ToInstall) {
                switch ($Pkg) {
                    "python" {
                        Write-Host "- Python: https://www.python.org/downloads/" -ForegroundColor Cyan
                    }
                    "docker-desktop" {
                        Write-Host "- Docker Desktop: https://www.docker.com/products/docker-desktop" -ForegroundColor Cyan
                    }
                    default {
                        Write-Host "- $Pkg" -ForegroundColor Cyan
                    }
                }
            }
            return $false
        }
        
        # 如果是伺服器安裝，啟動 Docker 服務
        if ($Mode -eq "server" -and ($ToInstall -contains "docker-desktop")) {
            Write-Info "啟動 Docker 服務..."
            Start-Service docker
        }
        
        Write-Info "系統依賴安裝完成"
    } else {
        Write-Info "所有系統依賴已安裝"
    }
    
    # 檢查並安裝 Python 依賴
function Install-PythonDeps {
    Write-Info "檢查 Python 依賴..."
    
    $MissingDeps = $false
    $ToInstall = @()
    
    # 檢查 pymodbus
    if (-not (Test-PythonPackage "pymodbus")) {
        $MissingDeps = $true
        $ToInstall += "pymodbus"
    }
    
    # 檢查 prometheus_client
    if (-not (Test-PythonPackage "prometheus_client")) {
        $MissingDeps = $true
        $ToInstall += "prometheus-client"
    }
    
    # 檢查 requests
    if (-not (Test-PythonPackage "requests")) {
        $MissingDeps = $true
        $ToInstall += "requests"
    }
    
    # 如果有缺少的依賴，詢問是否安裝
    if ($MissingDeps) {
        Write-Warning "缺少 Python 依賴: $($ToInstall -join ', ')"
        
        if (-not $env:AUTO_INSTALL) {
            $InstallDeps = Read-Host "是否安裝缺少的 Python 依賴? (y/n)"
            if ($InstallDeps -notmatch "^[Yy]") {
                Write-Warning "跳過安裝 Python 依賴"
                return $false
            }
        }
        
        Write-Info "安裝 Python 依賴..."
        pip install $ToInstall
        
        Write-Info "Python 依賴安裝完成"
    } else {
        Write-Info "所有 Python 依賴已安裝"
    }
    
    return $true
}

# 主安裝函數
function Install-Main {
    param (
        [Parameter(Mandatory=$false)]
        [string]$Mode = "agent"
    )
    
    # 安裝系統依賴
    $SysDepsResult = Install-SystemDeps $Mode
    
    # 如果是 agent 模式，安裝 Python 依賴
    if ($Mode -eq "agent" -and $SysDepsResult) {
        $PyDepsResult = Install-PythonDeps
    }
    
    Write-Info "依賴安裝檢查完成"
}

# 設定自動安裝標誌
if ($env:AUTO_INSTALL -eq $null -and $args.Contains("auto")) {
    $env:AUTO_INSTALL = "1"
}

# 執行主函數
$Mode = "agent"
if ($args.Length -gt 0 -and $args[0] -ne "auto") {
    $Mode = $args[0]
}

Install-Main $Mode

return $true
}