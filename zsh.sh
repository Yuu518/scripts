#!/bin/bash

set -u

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
    OS="unknown"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    fi
}

pkg_install() {
    case $OS in
        ubuntu|debian)
            run_cmd apt-get install -y "$@" > /dev/null 2>&1
            ;;
        fedora|rhel|centos)
            run_cmd dnf install -y "$@" > /dev/null 2>&1 || run_cmd yum install -y "$@" > /dev/null 2>&1
            ;;
        arch|manjaro)
            run_cmd pacman -S --noconfirm "$@" > /dev/null 2>&1
            ;;
        macos)
            brew install "$@" > /dev/null 2>&1
            ;;
        *)
            echo "Unsupported OS. Install $* manually"
            exit 1
            ;;
    esac
}

check_china_ip() {
    local country=""
    country=$(curl -s --max-time 5 "https://ipinfo.io/country" 2>/dev/null || true)
    if [ "$country" = "CN" ]; then
        GITHUB_PROXY="https://git.apad.pro/"
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
            ubuntu|debian) run_cmd apt-get update -qq ;;
        esac
        pkg_install "${deps_needed[@]}"
        echo "Dependencies installed"
    fi
}

install_zsh() {
    if command -v zsh &> /dev/null; then
        echo "Zsh already installed"
    else
        echo "Installing Zsh..."
        pkg_install zsh
        echo "Zsh installed"
    fi
}

install_oh_my_zsh() {
    local repo_url="https://github.com/ohmyzsh/ohmyzsh.git"
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo "Updating Oh-My-Zsh..."
        cd "$HOME/.oh-my-zsh" && git pull origin master > /dev/null 2>&1
        echo "Oh-My-Zsh updated"
    else
        echo "Installing Oh-My-Zsh..."
        git clone --depth 1 ${repo_url} "$HOME/.oh-my-zsh" > /dev/null 2>&1
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

github_install() {
    local repo="$1"
    local binary="$2"
    local arch
    arch="$(get_architecture)"

    local releases_url="https://api.github.com/repos/${repo}/releases/latest"
    local releases
    releases=$(curl -sL "${releases_url}")

    if echo "${releases}" | grep -q 'API rate limit exceeded'; then
        echo "Error: GitHub API rate limit exceeded"
        exit 1
    fi

    local download_url
    download_url=$(echo "${releases}" | grep "browser_download_url" | cut -d '"' -f 4 | grep "${arch}" | grep -v ".sha256" | head -n 1)

    if [ -z "${download_url}" ]; then
        echo "Error: Could not find ${binary} package for ${arch}"
        exit 1
    fi

    download_url="${GITHUB_PROXY}${download_url}"

    if command -v "${binary}" &> /dev/null; then
        echo "Updating ${binary}..."
    else
        echo "Installing ${binary}..."
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    (
        cd "${tmp_dir}"

        if ! curl -sL "${download_url}" -o "${binary}.pkg"; then
            echo "Error: Failed to download ${binary}"
            exit 1
        fi

        if [ ! -s "${binary}.pkg" ]; then
            echo "Error: Downloaded file is empty"
            exit 1
        fi

        case "${download_url}" in
        *.tar.gz) tar -xzf "${binary}.pkg" ;;
        *.zip) unzip -oq "${binary}.pkg" ;;
        esac

        run_cmd cp -f "${binary}" "${BIN_DIR}/${binary}"
        run_cmd chmod +x "${BIN_DIR}/${binary}"
    )

    rm -rf "${tmp_dir}"
    echo "${binary} installed to ${BIN_DIR}"
}

install_starship() {
    github_install "starship/starship" "starship"
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
    github_install "ajeetdsouza/zoxide" "zoxide"
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
        git clone --depth 1 ${repo_url} "$PLUGIN_DIR" > /dev/null 2>&1
        echo "zsh-autosuggestions installed"
    fi
}

configure_plugins() {
    if [ -f "$HOME/.zshrc" ] && grep -q "^plugins=" "$HOME/.zshrc"; then
        if grep "^plugins=" "$HOME/.zshrc" | grep -q "zsh-autosuggestions"; then
            echo "Plugins already configured"
        else
            sed -i.tmp 's/^plugins=(\(.*\))/plugins=(\1 zsh-autosuggestions)/' "$HOME/.zshrc" 2>/dev/null
            rm -f "$HOME/.zshrc.tmp"
            echo "Plugins configured"
        fi
    fi
}

optimize_performance() {
    if [ -f "$HOME/.zshrc" ]; then
        if grep -q "ZSH_DISABLE_COMPFIX" "$HOME/.zshrc"; then
            echo "Performance already optimized"
            return
        fi

        if ! grep -q "source \$ZSH/oh-my-zsh.sh" "$HOME/.zshrc"; then
            return
        fi

        cat > /tmp/zsh_pre_source << 'EOF'

ZSH_DISABLE_COMPFIX=true
DISABLE_AUTO_UPDATE=true
DISABLE_UPDATE_PROMPT=true

EOF

        cat > /tmp/zsh_post_source << 'EOF'

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

        awk '
        /source \$ZSH\/oh-my-zsh.sh/ && !inserted {
            while ((getline line < "/tmp/zsh_pre_source") > 0) print line
            print
            while ((getline line < "/tmp/zsh_post_source") > 0) print line
            inserted=1
            next
        }
        {print}' "$HOME/.zshrc" > "$HOME/.zshrc.new"
        mv "$HOME/.zshrc.new" "$HOME/.zshrc"

        rm -f /tmp/zsh_pre_source /tmp/zsh_post_source
        echo "Performance optimized"
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