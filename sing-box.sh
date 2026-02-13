#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MAIN_DIR="/opt/sing-box"
CORE_DIR="${MAIN_DIR}/src/bin"
CONFIG_FILE="${MAIN_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}" >&2
}

print_error() {
    echo -e "${RED}$1${NC}" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限运行"
        exit 1
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        *)
            print_error "不支持的架构: $arch"
            return 1
            ;;
    esac
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "无法检测操作系统"
        return 1
    fi
}

install_dependencies() {
    detect_os || return 1

    case $OS in
        ubuntu|debian)
            apt-get update > /dev/null 2>&1 || true
            apt-get install -y chrony curl > /dev/null 2>&1 || {
                print_warning "部分依赖安装失败，继续..."
            }
            ;;
        centos|rhel|fedora)
            if command -v dnf > /dev/null 2>&1; then
                dnf install -y chrony curl > /dev/null 2>&1 || true
            else
                yum install -y chrony curl > /dev/null 2>&1 || true
            fi
            ;;
        *)
            print_warning "未知系统，请手动安装 chrony curl"
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
            echo "$port"
            break
        fi
    done
}

get_latest_version() {
    local api_response
    api_response=$(curl -s "$GITHUB_API" 2>/dev/null)

    if [[ -z "$api_response" ]]; then
        print_error "无法获取版本信息，请检查网络"
        return 1
    fi

    local version
    version=$(echo "$api_response" | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": "v([^"]+)".*/\1/')
    local arch
    arch=$(detect_arch) || return 1
    local download_url
    download_url=$(echo "$api_response" | grep '"browser_download_url"' | grep "linux-${arch}" | head -n1 | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/')

    if [[ -z "$version" || -z "$download_url" ]]; then
        print_error "无法解析版本信息"
        return 1
    fi

    echo "$version|$download_url"
}

download_and_install() {
    local version_info
    version_info=$(get_latest_version) || return 1
    local version=$(echo "$version_info" | cut -d'|' -f1)
    local download_url=$(echo "$version_info" | cut -d'|' -f2)

    local temp_dir=$(mktemp -d)
    local archive_file="$temp_dir/sing-box.tar.gz"

    if ! curl -L "$download_url" -o "$archive_file" -s; then
        print_error "下载失败"
        rm -rf "$temp_dir"
        return 1
    fi

    pushd "$temp_dir" > /dev/null || { rm -rf "$temp_dir"; return 1; }
    tar -xzf "$archive_file" 2>/dev/null

    local extracted_dir=$(find . -type d -name "sing-box-*" | head -n1)
    local sing_box_binary="$extracted_dir/sing-box"

    if [[ ! -f "$sing_box_binary" ]]; then
        print_error "解压失败，未找到核心文件"
        popd > /dev/null
        rm -rf "$temp_dir"
        return 1
    fi

    mkdir -p "$CORE_DIR"
    cp "$sing_box_binary" "$CORE_DIR/"
    chmod +x "$CORE_DIR/sing-box"

    popd > /dev/null
    rm -rf "$temp_dir"
    echo "$version"
}

find_existing_singbox() {
    find / -name "sing-box" -type f -executable 2>/dev/null | grep -v "/proc\|/sys\|/dev\|/tmp" || true
}

create_config() {
    mkdir -p "$MAIN_DIR"
    local random_port=$(generate_port)
    local random_password=$(generate_password)

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
}

create_service() {
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
    systemctl enable --now sing-box > /dev/null 2>&1
}

install_singbox() {
    if [[ -f "$CORE_DIR/sing-box" ]]; then
        print_warning "sing-box 已安装，使用 update 参数更新"
        return 0
    fi

    echo "安装中..."

    install_dependencies

    local version
    version=$(download_and_install) || {
        print_error "下载安装失败"
        exit 1
    }

    [[ ! -f "$CONFIG_FILE" ]] && create_config
    create_service

    print_success "安装完成 v${version}"

    local host_name=$(hostname)
    local ip=$(curl -s https://ipinfo.io/ip)
    local port=$(grep -oP '"listen_port":\s*\K\d+' "$CONFIG_FILE")
    local password=$(grep -oP '"password":\s*"\K[^"]+' "$CONFIG_FILE")

    echo ""
    echo "$host_name=ss,$ip,$port,encrypt-method=2022-blake3-aes-128-gcm,password=$password,udp-relay=true"
    echo ""
}

update_singbox() {
    systemctl is-active --quiet sing-box && systemctl stop sing-box || true

    local existing_files=$(find_existing_singbox)

    if [[ -n "$existing_files" ]]; then
        echo "更新中..."

        local version_info
        version_info=$(get_latest_version) || {
            print_error "获取版本失败"
            exit 1
        }
        local version=$(echo "$version_info" | cut -d'|' -f1)
        local download_url=$(echo "$version_info" | cut -d'|' -f2)

        local temp_dir=$(mktemp -d)
        if ! curl -L "$download_url" -o "$temp_dir/sing-box.tar.gz" -s; then
            print_error "下载失败"
            rm -rf "$temp_dir"
            exit 1
        fi

        pushd "$temp_dir" > /dev/null || { rm -rf "$temp_dir"; exit 1; }
        tar -xzf "sing-box.tar.gz" 2>/dev/null

        local extracted_dir=$(find . -type d -name "sing-box-*" | head -n1)
        local new_binary="$extracted_dir/sing-box"

        if [[ ! -f "$new_binary" ]]; then
            print_error "解压失败，未找到核心文件"
            popd > /dev/null
            rm -rf "$temp_dir"
            exit 1
        fi

        while IFS= read -r file; do
            [[ -f "$file" ]] && cp -f "$new_binary" "$file" && chmod +x "$file"
        done <<< "$existing_files"

        popd > /dev/null
        rm -rf "$temp_dir"
        print_success "更新完成 v${version}"
    else
        print_warning "未找到已安装的 sing-box"
        download_and_install > /dev/null || {
            print_error "安装失败"
            exit 1
        }
    fi

    [[ -f "$SERVICE_FILE" ]] && systemctl start sing-box
}

uninstall_singbox() {
    echo "卸载中..."

    systemctl is-active --quiet sing-box && systemctl stop sing-box || true
    systemctl is-enabled --quiet sing-box && systemctl disable sing-box > /dev/null 2>&1 || true

    [[ -f "$SERVICE_FILE" ]] && rm -f "$SERVICE_FILE" && systemctl daemon-reload
    [[ -d "$MAIN_DIR" ]] && rm -rf "$MAIN_DIR"

    local existing_files=$(find_existing_singbox)
    [[ -n "$existing_files" ]] && echo "$existing_files" | xargs rm -f

    print_success "卸载完成"
}

main() {
    check_root

    case "${1:-auto}" in
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
            if [[ -f "$CORE_DIR/sing-box" ]] || [[ -n "$(find_existing_singbox)" ]]; then
                update_singbox
            else
                install_singbox
            fi
            ;;
    esac
}

main "$@"