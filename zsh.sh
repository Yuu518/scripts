#!/bin/bash

set -e

BIN_DIR="/usr/local/bin"
GITHUB_PROXY=""

run_cmd() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        OS="unknown"
    fi
}

check_china_ip() {
    local country=""
    country=$(curl -s --max-time 5 "https://ipinfo.io/country" 2>/dev/null || true)
    if [ "$country" = "CN" ]; then
        GITHUB_PROXY="https://ac.yuumi.moe/"
        echo "Detected China IP, using proxy: ${GITHUB_PROXY}"
    fi
}

get_architecture() {
    local _ostype _cputype _arch
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"

    case "${_ostype}" in
    Linux) _ostype="unknown-linux-musl" ;;
    Darwin) _ostype="apple-darwin" ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) _ostype="pc-windows-msvc" ;;
    *) echo "Error: unsupported OS: ${_ostype}" >&2 && exit 1 ;;
    esac

    case "${_cputype}" in
    x86_64 | x86-64 | x64 | amd64) _cputype="x86_64" ;;
    aarch64 | arm64) _cputype="aarch64" ;;
    armv7l | armv8l) _cputype="armv7" && _ostype="${_ostype}eabihf" ;;
    i386 | i486 | i686 | i786 | x86) _cputype="i686" ;;
    *) echo "Error: unsupported CPU: ${_cputype}" >&2 && exit 1 ;;
    esac

    _arch="${_cputype}-${_ostype}"
    echo "${_arch}"
}

fix_hostname() {
    if [[ "$OS" != "macos" ]] && ! grep -q "127.0.0.1.*$(hostname)" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 $(hostname)" | run_cmd tee -a /etc/hosts > /dev/null 2>&1
        echo "Hostname configured"
    fi
}

check_and_install_dependencies() {
    local deps_needed=()
    
    command -v curl &> /dev/null || deps_needed+=(curl)
    command -v git &> /dev/null || deps_needed+=(git)
    command -v tar &> /dev/null || deps_needed+=(tar)
    
    if [ ${#deps_needed[@]} -gt 0 ]; then
        echo "Installing dependencies: ${deps_needed[*]}"
        case $OS in
            ubuntu|debian)
                run_cmd apt-get update -qq
                for dep in "${deps_needed[@]}"; do
                    run_cmd apt-get install -y $dep > /dev/null 2>&1
                done
                ;;
            fedora|rhel|centos)
                for dep in "${deps_needed[@]}"; do
                    run_cmd dnf install -y $dep > /dev/null 2>&1 || run_cmd yum install -y $dep > /dev/null 2>&1
                done
                ;;
            arch|manjaro)
                for dep in "${deps_needed[@]}"; do
                    run_cmd pacman -S --noconfirm $dep > /dev/null 2>&1
                done
                ;;
            macos)
                for dep in "${deps_needed[@]}"; do
                    brew install $dep > /dev/null 2>&1
                done
                ;;
            *)
                echo "Unsupported OS. Install ${deps_needed[*]} manually"
                exit 1
                ;;
        esac
        echo "Dependencies installed"
    fi
}

install_zsh() {
    if command -v zsh &> /dev/null; then
        echo "Zsh already installed"
    else
        echo "Installing Zsh..."
        case $OS in
            ubuntu|debian)
                run_cmd apt-get install -y zsh > /dev/null 2>&1
                ;;
            fedora|rhel|centos)
                run_cmd dnf install -y zsh > /dev/null 2>&1 || run_cmd yum install -y zsh > /dev/null 2>&1
                ;;
            arch|manjaro)
                run_cmd pacman -S --noconfirm zsh > /dev/null 2>&1
                ;;
            macos)
                brew install zsh > /dev/null 2>&1
                ;;
            *)
                echo "Unsupported OS"
                exit 1
                ;;
        esac
        echo "Zsh installed"
    fi
}

install_oh_my_zsh() {
    local install_url="${GITHUB_PROXY}https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo "Updating Oh-My-Zsh..."
        cd "$HOME/.oh-my-zsh" && git pull origin master > /dev/null 2>&1
        echo "Oh-My-Zsh updated"
    else
        echo "Installing Oh-My-Zsh..."
        sh -c "$(curl -fsSL ${install_url})" "" --unattended > /dev/null 2>&1
        echo "Oh-My-Zsh installed"
    fi
}

ensure_zshrc() {
    if [ ! -f "$HOME/.zshrc" ]; then
        echo "Creating .zshrc file..."
        cat > "$HOME/.zshrc" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME=""

plugins=()

source $ZSH/oh-my-zsh.sh


EOF
        echo ".zshrc created"
    else
        echo ".zshrc already exists"
    fi
}

install_starship() {
    local arch
    arch="$(get_architecture)"
    
    local releases_url="https://api.github.com/repos/starship/starship/releases/latest"
    local releases
    releases=$(curl -sL "${releases_url}")
    
    if echo "${releases}" | grep -q 'API rate limit exceeded'; then
        echo "Error: GitHub API rate limit exceeded"
        exit 1
    fi
    
    local download_url
    download_url=$(echo "${releases}" | grep "browser_download_url" | cut -d '"' -f 4 | grep "${arch}" | grep -v ".sha256" | head -n 1)
    
    if [ -z "${download_url}" ]; then
        echo "Error: Could not find starship package for ${arch}"
        exit 1
    fi
    
    download_url="${GITHUB_PROXY}${download_url}"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "${tmp_dir}"
    
    if command -v starship &> /dev/null; then
        echo "Updating Starship..."
    else
        echo "Installing Starship..."
    fi
    
    curl -sL "${download_url}" -o starship.tar.gz
    tar -xzf starship.tar.gz
    run_cmd cp -f starship "${BIN_DIR}/starship"
    run_cmd chmod +x "${BIN_DIR}/starship"
    
    cd - > /dev/null
    rm -rf "${tmp_dir}"
    
    echo "Starship installed to ${BIN_DIR}"
}

configure_starship() {
    if [ -f "$HOME/.zshrc" ]; then
        sed -i.tmp 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$HOME/.zshrc" 2>/dev/null
        rm -f "$HOME/.zshrc.tmp"
        
        if ! grep -q 'starship init zsh' "$HOME/.zshrc"; then
            echo '' >> "$HOME/.zshrc"
            echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"
            echo "Starship configured"
        else
            echo "Starship already configured"
        fi
    else
        echo "Error: .zshrc not found"
        exit 1
    fi
}

install_zoxide() {
    local arch
    arch="$(get_architecture)"
    
    local releases_url="https://api.github.com/repos/ajeetdsouza/zoxide/releases/latest"
    local releases
    releases=$(curl -sL "${releases_url}")
    
    if echo "${releases}" | grep -q 'API rate limit exceeded'; then
        echo "Error: GitHub API rate limit exceeded"
        exit 1
    fi
    
    local download_url
    download_url=$(echo "${releases}" | grep "browser_download_url" | cut -d '"' -f 4 | grep "${arch}" | head -n 1)
    
    if [ -z "${download_url}" ]; then
        echo "Error: Could not find zoxide package for ${arch}"
        exit 1
    fi
    
    download_url="${GITHUB_PROXY}${download_url}"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "${tmp_dir}"
    
    if command -v zoxide &> /dev/null; then
        echo "Updating zoxide..."
    else
        echo "Installing zoxide..."
    fi
    
    local ext
    case "${download_url}" in
    *.tar.gz) ext="tar.gz" ;;
    *.zip) ext="zip" ;;
    esac
    
    curl -sL "${download_url}" -o "zoxide.${ext}"
    
    case "${ext}" in
    tar.gz) tar -xzf "zoxide.${ext}" ;;
    zip) unzip -oq "zoxide.${ext}" ;;
    esac
    
    run_cmd cp -f zoxide "${BIN_DIR}/zoxide"
    run_cmd chmod +x "${BIN_DIR}/zoxide"
    
    cd - > /dev/null
    rm -rf "${tmp_dir}"
    
    echo "zoxide installed to ${BIN_DIR}"
}

configure_zoxide() {
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q 'zoxide init zsh' "$HOME/.zshrc"; then
            echo '' >> "$HOME/.zshrc"
            echo 'eval "$(zoxide init zsh)"' >> "$HOME/.zshrc"
        fi

        if ! grep -q 'alias cd="z"' "$HOME/.zshrc"; then
            echo 'alias cd="z"' >> "$HOME/.zshrc"
            echo '' >> "$HOME/.zshrc"
            echo "zoxide configured"
        else
            echo "zoxide already configured"
        fi
    else
        echo "Error: .zshrc not found"
        exit 1
    fi
}

install_autosuggestions() {
    local repo_url="${GITHUB_PROXY}https://github.com/zsh-users/zsh-autosuggestions"
    PLUGIN_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"

    if [ -d "$PLUGIN_DIR" ]; then
        echo "Updating zsh-autosuggestions..."
        cd "$PLUGIN_DIR" && git pull origin master > /dev/null 2>&1
        echo "zsh-autosuggestions updated"
    else
        echo "Installing zsh-autosuggestions..."
        git clone ${repo_url} "$PLUGIN_DIR" > /dev/null 2>&1
        echo "zsh-autosuggestions installed"
    fi
}

configure_plugins() {
    if [ -f "$HOME/.zshrc" ]; then
        if grep -q "^plugins=" "$HOME/.zshrc"; then
            sed -i.tmp 's/^plugins=.*/plugins=(zsh-autosuggestions)/' "$HOME/.zshrc" 2>/dev/null
            rm -f "$HOME/.zshrc.tmp"
            echo "Plugins configured"
        fi
    fi
}

optimize_performance() {
    if [ -f "$HOME/.zshrc" ]; then
        cat > /tmp/zsh_optimization << 'EOF'

ZSH_DISABLE_COMPFIX=true
DISABLE_AUTO_UPDATE=true
DISABLE_UPDATE_PROMPT=true

autoload -Uz compinit
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi

HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_REDUCE_BLANKS
unsetopt correct_all

EOF

        if ! grep -q "ZSH_DISABLE_COMPFIX" "$HOME/.zshrc"; then
            if grep -q "source \$ZSH/oh-my-zsh.sh" "$HOME/.zshrc"; then
                awk '/source \$ZSH\/oh-my-zsh.sh/ && !inserted {
                    while ((getline line < "/tmp/zsh_optimization") > 0) {
                        print line
                    }
                    inserted=1
                }
                {print}' "$HOME/.zshrc" > "$HOME/.zshrc.new"
                mv "$HOME/.zshrc.new" "$HOME/.zshrc"
                echo "Performance optimized"
            fi
        else
            echo "Performance already optimized"
        fi
        
        rm -f /tmp/zsh_optimization
    fi
}

set_default_shell() {
    if [ "$SHELL" = "$(which zsh)" ]; then
        echo "Zsh is already default shell"
    else
        echo "Setting Zsh as default shell..."
        chsh -s "$(which zsh)" > /dev/null 2>&1
        echo "Zsh set as default shell (re-login required)"
    fi
}

add_custom_alias() {
    for alias_cmd in \
        'alias ..="cd .."' \
        'alias ...="cd ../.."' \
        'alias ....="cd ../../.."'
    do
        if ! grep -Fxq "$alias_cmd" "$HOME/.zshrc"; then
            echo "$alias_cmd" >> "$HOME/.zshrc"
        fi
    done
}

uninstall() {
    echo "Uninstalling..."
    
    if [ -f "${BIN_DIR}/starship" ]; then
        run_cmd rm -f "${BIN_DIR}/starship"
        echo "Starship removed"
    fi
    
    if [ -f "${BIN_DIR}/zoxide" ]; then
        run_cmd rm -f "${BIN_DIR}/zoxide"
        echo "zoxide removed"
    fi
    
    if [ -d "$HOME/.oh-my-zsh" ]; then
        rm -rf "$HOME/.oh-my-zsh"
        echo "Oh-My-Zsh removed"
    fi
    
    if [ -f "$HOME/.zshrc" ]; then
        rm -f "$HOME/.zshrc"
        echo ".zshrc removed"
    fi
    
    if [ -f "$HOME/.zsh_history" ]; then
        rm -f "$HOME/.zsh_history"
        echo ".zsh_history removed"
    fi
    
    echo "Uninstall completed"
}

show_help() {
    echo "Usage: $0 [install|uninstall]"
    echo ""
    echo "Commands:"
    echo "  install    Install or update Zsh environment (default)"
    echo "  uninstall  Remove Zsh environment and related tools"
}

main() {
    local action="${1:-install}"
    
    case "$action" in
        install)
            echo "Starting Zsh setup..."
            detect_os
            check_china_ip
            fix_hostname
            check_and_install_dependencies
            install_zsh
            install_oh_my_zsh
            ensure_zshrc
            install_starship
            configure_starship
            install_zoxide
            configure_zoxide
            install_autosuggestions
            configure_plugins
            optimize_performance
            add_custom_alias
            set_default_shell
            echo "Installation completed!"
            ;;
        uninstall)
            detect_os
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