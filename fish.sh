#!/bin/bash

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
FISH_BINARY="/usr/bin/fish"
STARSHIP_BINARY="$INSTALL_DIR/starship"
TARGET_USER="root"
TARGET_USER_HOME="/root"
FISH_CONFIG_DIR="$TARGET_USER_HOME/.config/fish"
FISH_CONFIG_FILE="$FISH_CONFIG_DIR/config.fish"

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Please run this script as root."
    exit 1
fi

check_dependencies() {
    local missing=()
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    if ! command -v xz &> /dev/null; then
        missing+=("xz-utils")
    fi
    if ! command -v tar &> /dev/null; then
        missing+=("tar")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo ">>> Installing dependencies: ${missing[*]}..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

check_dependencies

check_china_ip() {
    local country
    country=$(curl -s --max-time 5 "https://ipapi.co/country/" 2>/dev/null || echo "")
    if [ "$country" = "CN" ]; then
        return 0
    fi
    return 1
}

get_accelerated_url() {
    local url="$1"
    if check_china_ip; then
        echo "https://ac.yuumi.moe/$url"
    else
        echo "$url"
    fi
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            echo "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

get_latest_version() {
    local repo="$1"
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    if check_china_ip; then
        api_url=$(get_accelerated_url "$api_url")
    fi
    curl -s "$api_url" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

install_fish() {
    local arch
    arch=$(get_arch)
    
    echo ">>> Fetching latest Fish Shell version..."
    local version
    version=$(get_latest_version "fish-shell/fish-shell")
    local version_num="${version#v}"
    
    if [ -x "$FISH_BINARY" ]; then
        local current_version
        current_version=$("$FISH_BINARY" --version 2>/dev/null | awk '{print $3}' || echo "")
        if [ "$current_version" = "$version_num" ]; then
            echo ">>> Fish Shell $version_num is already installed and up to date."
            return 0
        fi
        echo ">>> Updating Fish Shell from $current_version to $version_num..."
    else
        echo ">>> Installing Fish Shell $version_num..."
    fi
    
    local download_url="https://github.com/fish-shell/fish-shell/releases/download/$version/fish-$version_num-linux-$arch.tar.xz"
    download_url=$(get_accelerated_url "$download_url")
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT
    
    echo ">>> Downloading Fish Shell..."
    curl -sL "$download_url" -o "$tmp_dir/fish.tar.xz"
    
    echo ">>> Extracting Fish Shell..."
    tar -xf "$tmp_dir/fish.tar.xz" -C "$tmp_dir"
    
    echo ">>> Installing Fish Shell to $INSTALL_DIR..."
    local extracted_dir
    extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "fish-*" | head -1)
    if [ -z "$extracted_dir" ]; then
        extracted_dir="$tmp_dir"
    fi
    
    if [ -f "$extracted_dir/bin/fish" ]; then
        cp -f "$extracted_dir/bin/fish" "$FISH_BINARY"
    elif [ -f "$extracted_dir/fish" ]; then
        cp -f "$extracted_dir/fish" "$FISH_BINARY"
    else
        local fish_bin
        fish_bin=$(find "$tmp_dir" -type f -name "fish" | head -1)
        if [ -n "$fish_bin" ]; then
            cp -f "$fish_bin" "$FISH_BINARY"
        else
            echo "Error: Could not find fish binary in archive"
            exit 1
        fi
    fi
    
    chmod +x "$FISH_BINARY"
    
    trap - EXIT
    rm -rf "$tmp_dir"
    
    echo ">>> Fish Shell $version_num installed successfully."
}

install_starship() {
    local arch
    arch=$(get_arch)
    
    echo ">>> Fetching latest Starship version..."
    local version
    version=$(get_latest_version "starship/starship")
    local version_num="${version#v}"
    
    if [ -x "$STARSHIP_BINARY" ]; then
        local current_version
        current_version=$("$STARSHIP_BINARY" --version 2>/dev/null | head -1 | awk '{print $2}' | tr -d '[:space:]' || echo "")
        version_num=$(echo "$version_num" | tr -d '[:space:]')
        if [ "$current_version" = "$version_num" ]; then
            echo ">>> Starship $version_num is already installed and up to date."
            return 0
        fi
        echo ">>> Updating Starship from $current_version to $version_num..."
    else
        echo ">>> Installing Starship $version_num..."
    fi
    
    local target_arch
    case "$arch" in
        x86_64)
            target_arch="x86_64-unknown-linux-gnu"
            ;;
        aarch64)
            target_arch="aarch64-unknown-linux-gnu"
            ;;
    esac
    
    local download_url="https://github.com/starship/starship/releases/download/$version/starship-$target_arch.tar.gz"
    download_url=$(get_accelerated_url "$download_url")
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT
    
    echo ">>> Downloading Starship..."
    curl -sL "$download_url" -o "$tmp_dir/starship.tar.gz"
    
    echo ">>> Extracting Starship..."
    tar -xzf "$tmp_dir/starship.tar.gz" -C "$tmp_dir"
    
    echo ">>> Installing Starship to $INSTALL_DIR..."
    cp -f "$tmp_dir/starship" "$STARSHIP_BINARY"
    chmod +x "$STARSHIP_BINARY"
    
    trap - EXIT
    rm -rf "$tmp_dir"
    
    echo ">>> Starship $version_num installed successfully."
}

configure_fish() {
    echo ">>> Configuring Fish Shell..."
    
    if ! grep -q "$FISH_BINARY" /etc/shells 2>/dev/null; then
        echo ">>> Adding $FISH_BINARY to /etc/shells..."
        echo "$FISH_BINARY" | tee -a /etc/shells > /dev/null
    fi
    
    echo ">>> Setting Fish as default shell for $TARGET_USER..."
    chsh -s "$FISH_BINARY"
    
    if [ ! -d "$FISH_CONFIG_DIR" ]; then
        echo ">>> Creating Fish config directory: $FISH_CONFIG_DIR"
        mkdir -p "$FISH_CONFIG_DIR"
    fi
    
    if ! grep -q "if status is-interactive" "$FISH_CONFIG_FILE" 2>/dev/null; then
        echo ">>> Adding interactive check to $FISH_CONFIG_FILE"
        echo 'if status is-interactive' | tee -a "$FISH_CONFIG_FILE" > /dev/null
        echo 'end' | tee -a "$FISH_CONFIG_FILE" > /dev/null
    fi
    
    if ! grep -q "starship init fish | source" "$FISH_CONFIG_FILE" 2>/dev/null; then
        echo ">>> Adding Starship init to $FISH_CONFIG_FILE"
        echo 'starship init fish | source' | tee -a "$FISH_CONFIG_FILE" > /dev/null
    fi
    
    if ! grep -q "set fish_greeting" "$FISH_CONFIG_FILE" 2>/dev/null; then
        echo ">>> Disabling Fish greeting message"
        echo 'set fish_greeting' | tee -a "$FISH_CONFIG_FILE" > /dev/null
    fi
}

uninstall() {
    echo "--- Starting Fish Shell and Starship uninstallation ---"
    
    local bash_path="/bin/bash"
    if [ ! -x "$bash_path" ]; then
        bash_path="/usr/bin/bash"
    fi
    
    echo ">>> Switching default shell back to bash..."
    chsh -s "$bash_path"
    
    if grep -q "$FISH_BINARY" /etc/shells 2>/dev/null; then
        echo ">>> Removing $FISH_BINARY from /etc/shells..."
        sed -i "\|$FISH_BINARY|d" /etc/shells
    fi
    
    if [ -x "$FISH_BINARY" ]; then
        echo ">>> Removing Fish Shell..."
        rm -f "$FISH_BINARY"
    fi
    
    if [ -x "$STARSHIP_BINARY" ]; then
        echo ">>> Removing Starship..."
        rm -f "$STARSHIP_BINARY"
    fi
    
    if [ -d "$FISH_CONFIG_DIR" ]; then
        echo ">>> Removing Fish config directory..."
        rm -rf "$FISH_CONFIG_DIR"
    fi
    
    echo "--- Uninstallation completed ---"
    echo ">>> Switching to bash..."
    exec "$bash_path"
}

case "${1:-}" in
    uninstall)
        uninstall
        exit 0
        ;;
esac

echo "--- Starting Fish Shell and Starship installation for root user ---"

install_fish
install_starship
configure_fish

echo "--- Script execution completed ---"
echo "Please logout and login again for the default shell change to take effect."
echo "On next login, you will be in Fish Shell with Starship prompt."