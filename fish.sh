#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "此脚本需要 root 权限运行。"
    echo "请直接以 root 身份运行此脚本。"
    exit 1
fi

TARGET_USER="root"
TARGET_USER_HOME="/root"

echo "--- 开始为 root 用户安装和配置 Fish Shell 和 Starship ---"

if ! command -v gpg &> /dev/null || ! command -v dirmngr &> /dev/null; then
    echo ">>> 检查并安装 gnupg 和 dirmngr..."
    apt update
    apt install -y gnupg dirmngr
fi

echo ">>> 添加 Fish Shell 软件源..."
echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/4/Debian_13/ /' | tee /etc/apt/sources.list.d/shells:fish:release:4.list > /dev/null

echo ">>> 添加 Fish Shell 软件源的 GPG 密钥..."
curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:4/Debian_13/Release.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/shells_fish_release_4.gpg > /dev/null

echo ">>> 更新 APT 缓存..."
apt update

echo ">>> 安装 Fish Shell..."
apt install fish -y

echo ">>> 将 root 用户的默认 Shell 更改为 /usr/bin/fish..."
if ! grep -q "/usr/bin/fish" /etc/shells; then
    echo "/usr/bin/fish" | tee -a /etc/shells > /dev/null
fi
chsh -s /usr/bin/fish

echo ">>> 安装 Starship Prompt..."
curl -sS https://starship.rs/install.sh | sh -s -- -y

echo ">>> 配置 Fish Shell..."
FISH_CONFIG_DIR="$TARGET_USER_HOME/.config/fish"
FISH_CONFIG_FILE="$FISH_CONFIG_DIR/config.fish"

if [ ! -d "$FISH_CONFIG_DIR" ]; then
    echo ">>> 创建 Fish 配置目录: $FISH_CONFIG_DIR"
    mkdir -p "$FISH_CONFIG_DIR"
fi

if ! grep -q "if status is-interactive" "$FISH_CONFIG_FILE" 2>/dev/null; then
    echo ">>> 添加交互式检查到 $FISH_CONFIG_FILE"
    echo 'if status is-interactive' | tee -a "$FISH_CONFIG_FILE" > /dev/null
    echo '    # Commands to run in interactive sessions can go here' | tee -a "$FISH_CONFIG_FILE" > /dev/null
    echo 'end' | tee -a "$FISH_CONFIG_FILE" > /dev/null
else
    echo ">>> 交互式检查已存在于 $FISH_CONFIG_FILE"
fi

if ! grep -q "starship init fish | source" "$FISH_CONFIG_FILE" 2>/dev/null; then
    echo ">>> 添加 Starship 初始化命令到 $FISH_CONFIG_FILE"
    echo 'starship init fish | source' | tee -a "$FISH_CONFIG_FILE" > /dev/null
else
    echo ">>> Starship 初始化命令已存在于 $FISH_CONFIG_FILE"
fi

if ! grep -q "set fish_greeting" "$FISH_CONFIG_FILE" 2>/dev/null; then
    echo ">>> 添加禁用 Fish 欢迎消息的命令到 $FISH_CONFIG_FILE"
    echo 'set fish_greeting' | tee -a "$FISH_CONFIG_FILE" > /dev/null
else
     echo ">>> 禁用 Fish 欢迎消息的命令已存在于 $FISH_CONFIG_FILE"
fi

echo "--- 脚本执行完毕 ---"
echo "为了使默认 Shell 的更改生效，请退出当前会话并重新登录。"
echo "下次登录时，您将直接进入 Fish Shell，并看到 Starship 提示符。"