#!/bin/bash

set -e

echo "Starting Zsh setup..."

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

fix_hostname() {
    if [[ "$OS" != "macos" ]] && ! grep -q "127.0.0.1.*$(hostname)" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 $(hostname)" | run_cmd tee -a /etc/hosts > /dev/null 2>&1
        echo "✓ Hostname configured"
    fi
}

check_and_install_dependencies() {
    local deps_needed=()
    
    command -v curl &> /dev/null || deps_needed+=(curl)
    command -v git &> /dev/null || deps_needed+=(git)
    
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
        echo "✓ Dependencies installed"
    fi
}

install_zsh() {
    if command -v zsh &> /dev/null; then
        echo "✓ Zsh already installed"
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
        echo "✓ Zsh installed"
    fi
}

install_oh_my_zsh() {
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo "Updating Oh-My-Zsh..."
        cd "$HOME/.oh-my-zsh" && git pull origin master > /dev/null 2>&1
        echo "✓ Oh-My-Zsh updated"
    else
        echo "Installing Oh-My-Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended > /dev/null 2>&1
        echo "✓ Oh-My-Zsh installed"
    fi
}

ensure_zshrc() {
    if [ ! -f "$HOME/.zshrc" ]; then
        echo "Creating .zshrc file..."
        cat > "$HOME/.zshrc" << 'EOF'
# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load
ZSH_THEME=""

# Plugins
plugins=()

# Load Oh-My-Zsh
source $ZSH/oh-my-zsh.sh


EOF
        echo "✓ .zshrc created"
    else
        echo "✓ .zshrc already exists"
    fi
}

install_starship() {
    if command -v starship &> /dev/null; then
        echo "Updating Starship..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y > /dev/null 2>&1
        echo "✓ Starship updated"
    else
        echo "Installing Starship..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y > /dev/null 2>&1
        echo "✓ Starship installed"
    fi
}

configure_starship() {
    if [ -f "$HOME/.zshrc" ]; then
        sed -i.tmp 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$HOME/.zshrc" 2>/dev/null
        rm -f "$HOME/.zshrc.tmp"
        
        if ! grep -q 'starship init zsh' "$HOME/.zshrc"; then
            echo '' >> "$HOME/.zshrc"
            echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"
            echo "✓ Starship configured"
        else
            echo "✓ Starship already configured"
        fi
    else
        echo "Error: .zshrc not found"
        exit 1
    fi
}

install_zoxide() {
    if command -v zoxide &> /dev/null; then
        echo "Updating zoxide..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh > /dev/null 2>&1
        echo "✓ zoxide updated"
    else
        echo "Installing zoxide..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh > /dev/null 2>&1
        echo "✓ zoxide installed"
    fi
}

configure_zoxide() {
    cp -f "$HOME/.local/bin/zoxide" /usr/local/bin/
    rm -rf "$HOME/.local/bin/zoxide"
    if [ -f "$HOME/.zshrc" ]; then
        sed -i.tmp 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$HOME/.zshrc" 2>/dev/null
        rm -f "$HOME/.zshrc.tmp"
        
        if ! grep -q 'zoxide init zsh' "$HOME/.zshrc"; then
            echo '' >> "$HOME/.zshrc"
            echo 'eval "$(zoxide init zsh)"' >> "$HOME/.zshrc"
        fi

        if ! grep -q 'alias cd="z"' "$HOME/.zshrc"; then
            echo 'alias cd="z"' >> "$HOME/.zshrc"
            echo '' >> "$HOME/.zshrc"
            echo "✓ zoxide configured"
        else
            echo "✓ zoxide already configured"
        fi
    else
        echo "Error: .zshrc not found"
        exit 1
    fi
}

install_autosuggestions() {
    PLUGIN_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"

    if [ -d "$PLUGIN_DIR" ]; then
        echo "Updating zsh-autosuggestions..."
        cd "$PLUGIN_DIR" && git pull origin master > /dev/null 2>&1
        echo "✓ zsh-autosuggestions updated"
    else
        echo "Installing zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions "$PLUGIN_DIR" > /dev/null 2>&1
        echo "✓ zsh-autosuggestions installed"
    fi
}

configure_plugins() {
    if [ -f "$HOME/.zshrc" ]; then
        if grep -q "^plugins=" "$HOME/.zshrc"; then
            sed -i.tmp 's/^plugins=.*/plugins=(zsh-autosuggestions)/' "$HOME/.zshrc" 2>/dev/null
            rm -f "$HOME/.zshrc.tmp"
            echo "✓ Plugins configured"
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
                echo "✓ Performance optimized"
            fi
        else
            echo "✓ Performance already optimized"
        fi
        
        rm -f /tmp/zsh_optimization
    fi
}

set_default_shell() {
    if [ "$SHELL" = "$(which zsh)" ]; then
        echo "✓ Zsh is already default shell"
    else
        echo "Setting Zsh as default shell..."
        chsh -s "$(which zsh)" > /dev/null 2>&1
        echo "✓ Zsh set as default shell (re-login required)"
    fi
}

add_custom_alist() {
    for alias_cmd in \
        '# Enhancements to the cd command' \
        'alias ..="cd .."' \
        'alias ...="cd ../.."' \
        'alias ....="cd ../../.."'
    do
        if ! grep -Fxq "$alias_cmd" "$HOME/.zshrc"; then
            echo "$alias_cmd" >> "$HOME/.zshrc"
        fi
    done
}
 
main() {
    detect_os
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
    add_custom_alist
    set_default_shell
    echo "Installation completed!"
}

main