#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MAIN_DIR="/opt/sing-box"
CORE_DIR="${MAIN_DIR}/src/bin"
CONFIG_FILE="${MAIN_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        exit 1
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "无法检测操作系统"
        exit 1
    fi
}

install_dependencies() {
    print_info "检查并安装依赖包..."
    
    detect_os
    
    case $OS in
        ubuntu|debian)
            apt-get update > /dev/null 2>&1
            for pkg in chrony curl; do
                if ! dpkg -l | grep -q "^ii  $pkg "; then
                    print_info "安装 $pkg..."
                    apt-get install -y $pkg > /dev/null 2>&1
                else
                    print_success "$pkg 已安装"
                fi
            done
            ;;
        centos|rhel|fedora)
            if command -v dnf > /dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            
            for pkg in chrony curl; do
                if ! rpm -qa | grep -q "$pkg"; then
                    print_info "安装 $pkg..."
                    $PKG_MANAGER install -y $pkg > /dev/null 2>&1
                else
                    print_success "$pkg 已安装"
                fi
            done
            ;;
        *)
            print_warning "未知的操作系统，请手动安装 chrony curl"
            ;;
    esac
}

generate_password() {
    openssl rand -base64 16
}

generate_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        if ! ss -tuln | grep -q ":$port "; then
            echo $port
            break
        fi
    done
}

host_name() {
    hostname
}

ip() {
    curl https://ipinfo.io/ip
}

get_latest_version() {
    local api_response
    api_response=$(curl -s "$GITHUB_API" 2>/dev/null)
    
    if [[ -z "$api_response" ]]; then
        print_error "无法获取版本信息，请检查网络连接" >&2
        exit 1
    fi

    
    local version=$(echo "$api_response" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": "v([^"]+)".*/\1/')
    local arch=$(detect_arch)
    local download_url=$(echo "$api_response" | grep '"browser_download_url"' | grep "linux-$arch" | head -n1 | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/')
    
    if [[ -z "$version" || -z "$download_url" ]]; then
        print_error "无法解析版本信息: version=$version, download_url=$download_url" >&2
        print_error "arch=$arch" >&2
        exit 1
    fi
    
    echo "$version|$download_url"
}

download_and_install() {
    print_info "获取最新版本信息..."
    local version_info=$(get_latest_version)
    local version=$(echo "$version_info" | cut -d'|' -f1)
    local download_url=$(echo "$version_info" | cut -d'|' -f2)
    local arch=$(detect_arch)
    
    print_info "下载 sing-box v$version ($arch)..."
    
    local temp_dir=$(mktemp -d)
    local archive_file="$temp_dir/sing-box.tar.gz"
    
    if ! curl -L "$download_url" -o "$archive_file" --progress-bar; then
        print_error "下载失败"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    print_info "解压文件..."
    cd "$temp_dir"
    tar -xzf "$archive_file"
    
    local extracted_dir=$(find . -type d -name "sing-box-*" | head -n1)
    if [[ -z "$extracted_dir" ]]; then
        print_error "无法找到解压后的目录"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    local sing_box_binary="$extracted_dir/sing-box"
    if [[ ! -f "$sing_box_binary" ]]; then
        print_error "无法找到sing-box可执行文件"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    mkdir -p "$CORE_DIR"
    
    cp "$sing_box_binary" "$CORE_DIR/"
    chmod +x "$CORE_DIR/sing-box"
    
    print_success "sing-box v$version 安装完成"
    
    rm -rf "$temp_dir"
}

find_existing_singbox() {
    print_info "搜索已安装的sing-box..."
    
    local locations=$(find / -type f -name "sing-box" -exec dirname {} \;)
    
    local found_files=$(find / -name "sing-box" -type f -executable 2>/dev/null | grep -v "/proc\|/sys\|/dev\|/tmp")
    
    if [[ -n "$found_files" ]]; then
        print_success "找到以下sing-box安装："
        echo "$found_files"
        return 0
    else
        print_info "未找到已安装的sing-box"
        return 1
    fi
}

create_config() {
    print_info "创建配置文件..."
    
    local random_port=$(generate_port)
    local random_password=$(generate_password)
    local host_name=$(host_name)
    local ip=$(ip)
    
    cat > "$CONFIG_FILE" << EOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "server": "1.1.1.1"
      }
    ]
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": ${random_port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${random_password}"
    }
  ],
  "route": {
    "rules":[
      {
        "action": "sniff"
      }
    ]
  }
}
EOF
    
    print_success "配置文件已创建: $CONFIG_FILE"
    print_info "端口: $random_port"
    print_info "密码: $random_password"
    print_info "$host_name=ss,$ip,$random_port,encrypt-method=2022-blake3-aes-128-gcm,password=$random_password,udp-relay=true"
}

create_service() {
    print_info "创建systemd服务..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${CORE_DIR}/sing-box run -D ${MAIN_DIR} -c ${MAIN_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable sing-box
    
    print_success "systemd服务已创建并启用"
}

install_singbox() {
    print_info "开始安装sing-box..."
    
    install_dependencies
    
    if [[ -f "$CORE_DIR/sing-box" ]]; then
        print_warning "sing-box已安装在 $CORE_DIR"
        print_info "如需更新，请使用更新功能"
        return 0
    fi
    
    download_and_install

    if [[ ! -f "$CONFIG_FILE" ]]; then
        create_config
    else
        print_info "配置文件已存在，跳过创建"
    fi
    
    create_service
    
    systemctl start sing-box
    
    print_success "sing-box安装完成并已启动"
    print_info "状态: $(systemctl is-active sing-box)"
}

update_singbox() {
    print_info "开始更新sing-box..."
    
    if systemctl is-active --quiet sing-box; then
        print_info "停止sing-box服务..."
        systemctl stop sing-box
    fi
    
    if [[ -f "$CORE_DIR/sing-box" ]]; then
        cp "$CORE_DIR/sing-box" "$CORE_DIR/sing-box.bak"
        print_info "已备份当前版本"
    fi
    
    local existing_files=$(find / -name "sing-box" -type f -executable 2>/dev/null | grep -v "/proc\|/sys\|/dev\|/tmp")
    
    if [[ -n "$existing_files" ]]; then
        print_info "找到以下sing-box实例，将进行更新："
        echo "$existing_files"
        
        print_info "获取最新版本信息..."
        local version_info=$(get_latest_version)
        local version=$(echo "$version_info" | cut -d'|' -f1)
        local download_url=$(echo "$version_info" | cut -d'|' -f2)
        
        local temp_dir=$(mktemp -d)
        local archive_file="$temp_dir/sing-box.tar.gz"
        
        curl -L "$download_url" -o "$archive_file" --progress-bar
        cd "$temp_dir"
        tar -xzf "$archive_file"
        
        local extracted_dir=$(find . -type d -name "sing-box-*" | head -n1)
        local new_binary="$extracted_dir/sing-box"
        
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                print_info "更新 $file"
                cp -f "$new_binary" "$file"
                chmod +x "$file"
            fi
        done <<< "$existing_files"
        
        rm -rf "$temp_dir"
        print_success "所有sing-box实例已更新到 v$version"
    else
        print_warning "未找到已安装的sing-box，执行全新安装"
        download_and_install
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        systemctl start sing-box
        print_success "sing-box服务已重新启动"
    fi
}

uninstall_singbox() {
    print_info "开始卸载sing-box..."
    
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box
        print_info "已停止sing-box服务"
    fi
    
    if systemctl is-enabled --quiet sing-box; then
        systemctl disable sing-box
        print_info "已禁用sing-box服务"
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        print_info "已删除systemd服务文件"
    fi
    
    if [[ -d "$MAIN_DIR" ]]; then
        rm -rf "$MAIN_DIR"
        print_info "已删除主目录: $MAIN_DIR"
    fi
    
    local existing_files=$(find / -name "sing-box" -type f -executable 2>/dev/null | grep -v "/proc\|/sys\|/dev\|/tmp")
    
    if [[ -n "$existing_files" ]]; then
        print_info "找到其他sing-box实例："
        echo "$existing_files"
        
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                rm -f "$file"
                print_info "已删除: $file"
            fi
        done <<< "$existing_files"
    fi
    
    print_success "sing-box卸载完成"
}

main() {
    check_root
    
    local action="${1:-auto}"
    
    case "$action" in
        install)
            install_singbox
            ;;
        update)
            update_singbox
            ;;
        uninstall)
            uninstall_singbox
            ;;
        auto|*)
            if [[ -f "$CORE_DIR/sing-box" ]] || find_existing_singbox > /dev/null 2>&1; then
                print_info "检测到已安装的sing-box，执行更新操作..."
                update_singbox
            else
                print_info "未检测到sing-box安装，执行安装操作..."
                install_singbox
            fi
            ;;
    esac
}

main "$@"