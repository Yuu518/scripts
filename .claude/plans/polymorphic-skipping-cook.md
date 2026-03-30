# zsh.sh 优化计划

## Context
脚本功能完整，但存在大量重复代码和几个潜在 bug。优化目标：消除重复、修复 bug、增强健壮性，不改变功能。

## 1. 代码去重

### 1.1 提取通用包管理器安装函数 `pkg_install`
`check_and_install_dependencies` 和 `install_zsh` 中的 OS case 逻辑几乎一样，提取为：
```bash
pkg_install() {
    local pkg="$1"
    case $OS in
        ubuntu|debian) run_cmd apt-get install -y "$pkg" > /dev/null 2>&1 ;;
        fedora|rhel|centos) run_cmd dnf install -y "$pkg" > /dev/null 2>&1 || run_cmd yum install -y "$pkg" > /dev/null 2>&1 ;;
        arch|manjaro) run_cmd pacman -S --noconfirm "$pkg" > /dev/null 2>&1 ;;
        macos) brew install "$pkg" > /dev/null 2>&1 ;;
        *) echo "Unsupported OS for package: $pkg" >&2; return 1 ;;
    esac
}
```
- `check_and_install_dependencies`: 循环调用 `pkg_install`，apt-get update 单独保留
- `install_zsh`: 简化为 `pkg_install zsh`

### 1.2 提取 GitHub Release 下载函数 `install_github_release`
`install_starship` 和 `install_zoxide` 共享 ~90% 逻辑，提取为：
```bash
install_github_release() {
    local repo="$1"    # e.g. "starship/starship"
    local binary="$2"  # e.g. "starship"
    ...
}
```
处理：获取 release → 下载 → 解压(tar.gz/zip) → 复制到 BIN_DIR

### 1.3 提取 Git clone/pull 函数 `git_clone_or_pull`
`install_oh_my_zsh` 和 `install_autosuggestions` 共享 clone-or-update 模式：
```bash
git_clone_or_pull() {
    local repo_url="$1"
    local target_dir="$2"
    local name="$3"
    if [ -d "$target_dir" ]; then
        echo "Updating ${name}..."
        git -C "$target_dir" pull origin master > /dev/null 2>&1
    else
        echo "Installing ${name}..."
        git clone "$repo_url" "$target_dir" > /dev/null 2>&1
    fi
    echo "${name} ready"
}
```

## 2. Bug 修复

### 2.1 `cd` 污染工作目录（重要）
- `install_oh_my_zsh`: `cd "$HOME/.oh-my-zsh" && git pull` — 会改变后续函数的工作目录
- `install_autosuggestions`: 同样问题
- **修复**: 使用 `git -C <dir> pull` 替代 `cd && git pull`（已在 1.3 中解决）

### 2.2 `detect_os` 未设置 OS 的情况
- 如果 Linux 但没有 `/etc/os-release`，OS 变量未赋值，后续 `set -u` 会报错
- **修复**: 在函数开头 `OS="unknown"`

### 2.3 `configure_plugins` 覆盖用户插件
- `sed 's/^plugins=.*/plugins=(zsh-autosuggestions)/'` 会丢弃用户已有的插件
- **修复**: 检查 plugins 行是否已包含 `zsh-autosuggestions`，若无则追加到现有列表

### 2.4 `optimize_performance` awk 插入位置
- 当前逻辑：在 `source $ZSH/oh-my-zsh.sh` **之前**插入优化配置
- `ZSH_DISABLE_COMPFIX` 和 `DISABLE_AUTO_UPDATE` 需要在 source 之前设置 ✅ 正确
- 但 `compinit`、`HISTSIZE`、`setopt` 等应在 source **之后**
- **修复**: 拆分为 pre-source（ZSH_DISABLE_COMPFIX 等）和 post-source（compinit、history 等）两部分

## 3. 健壮性增强

### 3.1 临时目录清理 trap
```bash
# 在 install_github_release 中
trap "rm -rf '${tmp_dir}'" EXIT
```

### 3.2 `which` → `command -v`
- `set_default_shell` 使用 `which zsh`，不如 `command -v zsh` 可靠且一致

### 3.3 变量引用
- `git clone ${repo_url}` → `git clone "${repo_url}"`（多处）
- `run_cmd apt-get install -y $dep` → `"$dep"`

## 4. 需修改的文件

- [zsh.sh](zsh.sh) — 唯一需要修改的文件

## 5. 验证方式

- `bash -n zsh.sh` 语法检查
- `shellcheck zsh.sh` 静态分析（如可用）
- 在 Linux 环境中执行 `bash zsh.sh install` 验证功能正常
