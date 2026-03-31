#!/bin/bash

set -u

INSTALL_DIR="/usr/local/bin"
FISH_BINARY="/usr/bin/fish"
STARSHIP_BINARY="$INSTALL_DIR/starship"
ZOXIDE_BINARY="$INSTALL_DIR/zoxide"
TARGET_USER="root"
TARGET_USER_HOME="/root"
FISH_CONFIG_DIR="$TARGET_USER_HOME/.config/fish"
FISH_CONFIG_FILE="$FISH_CONFIG_DIR/config.fish"
GITHUB_PROXY=""
OS=""

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    exit 1
fi

check_china_ip() {
    local country=""
    country=$(curl -s --max-time 5 "https://ipinfo.io/country" 2>/dev/null || true)
    if [ "$country" = "CN" ]; then
        GITHUB_PROXY="https://git.apad.pro/"
        echo "Detected China IP, using proxy: ${GITHUB_PROXY}"
    fi
}

detect_os() {
    OS="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    fi
}

pkg_install() {
    case $OS in
        ubuntu|debian)
            apt-get install -y "$@"
            ;;
        fedora|rhel|centos)
            dnf install -y "$@" || yum install -y "$@"
            ;;
        arch|manjaro)
            pacman -S --noconfirm "$@"
            ;;
        *)
            echo "Unsupported OS. Install $* manually"
            return 1
            ;;
    esac
}

check_dependencies() {
    local missing=()
    command -v curl &> /dev/null || missing+=(curl)
    command -v tar &> /dev/null || missing+=(tar)
    if ! command -v xz &> /dev/null; then
        case $OS in
            ubuntu|debian) missing+=(xz-utils) ;;
            *) missing+=(xz) ;;
        esac
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo ">>> Installing dependencies: ${missing[*]}..."
        case $OS in
            ubuntu|debian) apt-get update -qq ;;
        esac
        if ! pkg_install "${missing[@]}"; then
            echo "Error: Failed to install dependencies: ${missing[*]}"
            exit 1
        fi
        echo ">>> Dependencies installed"
    fi
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)
            echo "Unsupported architecture: $arch" >&2
            exit 1
            ;;
    esac
}

get_latest_version() {
    local repo="$1"
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    local response
    response=$(curl -s "$api_url" 2>/dev/null)

    if [ -z "$response" ]; then
        echo "Error: Failed to fetch version info" >&2
        return 1
    fi

    echo "$response" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

install_fish() {
    local arch
    arch=$(get_arch)

    echo ">>> Fetching latest Fish Shell version..."
    local version
    version=$(get_latest_version "fish-shell/fish-shell") || return 1
    local version_num="${version#v}"

    if [ -x "$FISH_BINARY" ]; then
        local current_version
        current_version=$("$FISH_BINARY" --version 2>/dev/null | awk '{print $3}' || echo "")
        if [ "$current_version" = "$version_num" ]; then
            echo ">>> Fish Shell $version_num is already up to date."
            return 0
        fi
        echo ">>> Updating Fish Shell from $current_version to $version_num..."
    else
        echo ">>> Installing Fish Shell $version_num..."
    fi

    local download_url="${GITHUB_PROXY}https://github.com/fish-shell/fish-shell/releases/download/$version/fish-$version_num-linux-$arch.tar.xz"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo ">>> Downloading Fish Shell..."
    if ! curl -sL "$download_url" -o "$tmp_dir/fish.tar.xz" || [ ! -s "$tmp_dir/fish.tar.xz" ]; then
        echo "Error: Download failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo ">>> Extracting Fish Shell..."
    tar -xf "$tmp_dir/fish.tar.xz" -C "$tmp_dir"

    local fish_bin
    fish_bin=$(find "$tmp_dir" -type f -name "fish" | head -1)
    if [ -z "$fish_bin" ]; then
        echo "Error: Could not find fish binary in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp -f "$fish_bin" "$FISH_BINARY"
    chmod +x "$FISH_BINARY"

    rm -rf "$tmp_dir"
    echo ">>> Fish Shell $version_num installed successfully."
}

install_starship() {
    local arch
    arch=$(get_arch)

    echo ">>> Fetching latest Starship version..."
    local version
    version=$(get_latest_version "starship/starship") || return 1
    local version_num="${version#v}"

    if [ -x "$STARSHIP_BINARY" ]; then
        local current_version
        current_version=$("$STARSHIP_BINARY" --version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '[:space:]' || echo "")
        version_num=$(echo "$version_num" | tr -d '[:space:]')
        if [ "$current_version" = "$version_num" ]; then
            echo ">>> Starship $version_num is already up to date."
            return 0
        fi
        echo ">>> Updating Starship from $current_version to $version_num..."
    else
        echo ">>> Installing Starship $version_num..."
    fi

    local target_arch
    case "$arch" in
        x86_64) target_arch="x86_64-unknown-linux-gnu" ;;
        aarch64) target_arch="aarch64-unknown-linux-gnu" ;;
    esac

    local download_url="${GITHUB_PROXY}https://github.com/starship/starship/releases/download/$version/starship-$target_arch.tar.gz"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo ">>> Downloading Starship..."
    if ! curl -sL "$download_url" -o "$tmp_dir/starship.tar.gz" || [ ! -s "$tmp_dir/starship.tar.gz" ]; then
        echo "Error: Download failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo ">>> Extracting Starship..."
    tar -xzf "$tmp_dir/starship.tar.gz" -C "$tmp_dir"

    if [ ! -f "$tmp_dir/starship" ]; then
        echo "Error: Could not find starship binary in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp -f "$tmp_dir/starship" "$STARSHIP_BINARY"
    chmod +x "$STARSHIP_BINARY"

    rm -rf "$tmp_dir"
    echo ">>> Starship $version_num installed successfully."
}

install_zoxide() {
    local arch
    arch=$(get_arch)

    local target_arch
    case "$arch" in
        x86_64) target_arch="x86_64-unknown-linux-musl" ;;
        aarch64) target_arch="aarch64-unknown-linux-musl" ;;
    esac

    echo ">>> Fetching latest zoxide version..."
    local version
    version=$(get_latest_version "ajeetdsouza/zoxide") || return 1
    local version_num="${version#v}"

    if [ -x "$ZOXIDE_BINARY" ]; then
        local current_version
        current_version=$("$ZOXIDE_BINARY" --version 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || echo "")
        version_num=$(echo "$version_num" | tr -d '[:space:]')
        if [ "$current_version" = "$version_num" ]; then
            echo ">>> zoxide $version_num is already up to date."
            return 0
        fi
        echo ">>> Updating zoxide from $current_version to $version_num..."
    else
        echo ">>> Installing zoxide $version_num..."
    fi

    local download_url="${GITHUB_PROXY}https://github.com/ajeetdsouza/zoxide/releases/download/$version/zoxide-$version_num-$target_arch.tar.gz"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo ">>> Downloading zoxide..."
    if ! curl -sL "$download_url" -o "$tmp_dir/zoxide.tar.gz" || [ ! -s "$tmp_dir/zoxide.tar.gz" ]; then
        echo "Error: Download failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo ">>> Extracting zoxide..."
    tar -xzf "$tmp_dir/zoxide.tar.gz" -C "$tmp_dir"

    if [ ! -f "$tmp_dir/zoxide" ]; then
        echo "Error: Could not find zoxide binary in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp -f "$tmp_dir/zoxide" "$ZOXIDE_BINARY"
    chmod +x "$ZOXIDE_BINARY"

    rm -rf "$tmp_dir"
    echo ">>> zoxide $version_num installed successfully."
}

configure_fish() {
    echo ">>> Configuring Fish Shell..."

    if ! grep -q "$FISH_BINARY" /etc/shells 2>/dev/null; then
        echo ">>> Adding $FISH_BINARY to /etc/shells..."
        echo "$FISH_BINARY" >> /etc/shells
    fi

    echo ">>> Setting Fish as default shell for $TARGET_USER..."
    chsh -s "$FISH_BINARY"

    mkdir -p "$FISH_CONFIG_DIR"

    if [ ! -f "$FISH_CONFIG_FILE" ] || ! grep -q "zoxide init fish" "$FISH_CONFIG_FILE" 2>/dev/null; then
        echo ">>> Writing $FISH_CONFIG_FILE"
        cat > "$FISH_CONFIG_FILE" << 'EOF'
set fish_greeting

if status is-interactive
    starship init fish | source
    zoxide init fish | source
    alias cd z
end
EOF
        echo ">>> Fish configured"
    else
        echo ">>> Fish already configured"
    fi
}

uninstall() {
    echo "--- Uninstalling Fish Shell and Starship ---"

    local bash_path="/bin/bash"
    [ -x "$bash_path" ] || bash_path="/usr/bin/bash"

    echo ">>> Switching default shell back to bash..."
    chsh -s "$bash_path"

    if grep -q "$FISH_BINARY" /etc/shells 2>/dev/null; then
        echo ">>> Removing $FISH_BINARY from /etc/shells..."
        sed -i "\|$FISH_BINARY|d" /etc/shells
    fi

    [ -x "$FISH_BINARY" ] && rm -f "$FISH_BINARY" && echo ">>> Fish Shell removed"
    [ -x "$STARSHIP_BINARY" ] && rm -f "$STARSHIP_BINARY" && echo ">>> Starship removed"
    [ -x "$ZOXIDE_BINARY" ] && rm -f "$ZOXIDE_BINARY" && echo ">>> zoxide removed"
    [ -d "$FISH_CONFIG_DIR" ] && rm -rf "$FISH_CONFIG_DIR" && echo ">>> Fish config removed"

    echo "--- Uninstall completed ---"
    exec "$bash_path"
}

show_help() {
    echo "Usage: $0 [install|uninstall]"
    echo ""
    echo "Commands:"
    echo "  install    Install or update Fish Shell + Starship + zoxide (default)"
    echo "  uninstall  Remove Fish Shell, Starship, zoxide and config"
}

main() {
    local action="${1:-install}"

    case "$action" in
        install)
            detect_os
            check_china_ip
            check_dependencies
            echo "--- Installing Fish Shell, Starship and zoxide ---"
            install_fish || { echo "Error: Fish Shell installation failed, aborting."; exit 1; }
            install_starship
            install_zoxide
            configure_fish
            echo "--- Installation completed ---"
            echo "Please re-login for Fish Shell to take effect."
            ;;
        uninstall)
            uninstall
            ;;
        -h|--help|help)
            show_help
            ;;
        *)
            echo "Error: Unknown command: $action"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
