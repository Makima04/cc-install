#!/usr/bin/env bash
# =============================================================================
# install.sh — 一键安装 Claude Code + Codex + cc-switch（macOS / Linux）
#
# 全程走国内镜像，无需梯子。运行时 API 走国内 LLM 厂商官方接口。
#
# 用法：
#   curl -fsSL <raw-url>/install.sh | bash
#   或： bash install.sh
#
# 可用环境变量：
#   GH_PROXY        自定义 GitHub 代理前缀，如 https://ghfast.top/
#   NPM_REGISTRY    自定义 npm 镜像，默认 https://registry.npmmirror.com
#   NODE_MIRROR     自定义 Node 二进制镜像，默认 https://registry.npmmirror.com/-/binary/node
#   NONINTERACTIVE  设为 1 跳过所有交互确认（默认交互）
# =============================================================================

set -euo pipefail

# ----------------------------- 常量 ----------------------------------------
readonly SCRIPT_NAME="install.sh"
readonly VERSION="1.0.0"
readonly REQUIRED_NODE_MAJOR=22          # Codex 要求 Node 22+，统一以它为准
readonly CC_SWITCH_REPO="farion1231/cc-switch"

# npm / node 镜像（用户可覆盖）
: "${NPM_REGISTRY:=https://registry.npmmirror.com}"
: "${NODE_MIRROR:=https://registry.npmmirror.com/-/binary/node}"

# GitHub 代理回退链（ghfast.top 已加 / 前缀，便于拼接）
DEFAULT_GH_PROXIES=(
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
  ""                                    # 空串 = 直连
)

# nvm 安装脚本镜像（Gitee，避开被墙的 raw.githubusercontent.com）
readonly NVM_GITEE_URL="https://gitee.com/mirrors/nvm/raw/v0.40.1/install.sh"

# cc-switch CLI 版（Linux 无 GUI 服务器用，命令名是 ccs）
readonly CCS_CLI_PKG="@songhe/cc-switch"
readonly CCS_CLI_BIN="ccs"

# 日志目录
readonly LOG_DIR="${HOME}/.cc-installer"
readonly LOG_FILE="${LOG_DIR}/install.log"

# ----------------------------- 输出美化 ------------------------------------
if [[ -t 1 ]]; then
  color_reset=$'\033[0m'
  c_red=$'\033[31m';  c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_bold=$'\033[1m';   c_dim=$'\033[2m'
else
  color_reset=""; c_red=""; c_green=""; c_yellow=""; c_blue=""; c_bold=""; c_dim=""
fi

log()  { printf '%s[%s]%s %s\n' "$c_blue"  "$(date +%H:%M:%S)" "$color_reset" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '%s✅ %s%s\n' "$c_green"  "$*" "$color_reset" | tee -a "$LOG_FILE"; }
warn() { printf '%s⚠️  %s%s\n' "$c_yellow" "$*" "$color_reset" | tee -a "$LOG_FILE"; }
err()  { printf '%s❌ %s%s\n' "$c_red"    "$*" "$color_reset" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; err "详细日志：$LOG_FILE"; exit 1; }

section() { printf '\n%s━━ %s ━━%s\n' "$c_bold" "$*" "$color_reset" | tee -a "$LOG_FILE"; }

# ----------------------------- 工具函数 ------------------------------------
# 判断命令是否存在
have() { command -v "$1" >/dev/null 2>&1; }

# 判断 Linux 是否为无头服务器（无 GUI）。
# 依据：$DISPLAY 为空，且没有 Wayland 会话。无头 → 装 cc-switch CLI 版而非桌面版。
is_linux_headless() {
  [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]
}

# 提取语义版本的主版本号；不存在返回 0
node_major() {
  local v
  v=$(node -v 2>/dev/null || echo "")
  v=${v#v}                      # 去掉 v 前缀
  v=${v%%.*}                    # 取主版本
  echo "${v:-0}"
}

# 比较数字：$1 >= $2 返回 0（true）
ge() { [[ "${1:-0}" -ge "${2:-0}" ]]; }

# 交互式确认；NONINTERACTIVE=1 自动 yes
confirm() {
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then return 0; fi
  local prompt="$1 [Y/n] "
  local reply
  read -r -p "$(printf '%s%s%s' "$c_yellow" "$prompt" "$color_reset")" reply || reply="y"
  reply=${reply:-y}
  [[ "$reply" =~ ^[Yy]$ ]]
}

# 通过 GitHub API 拿 cc-switch 最新 release 的 asset 下载地址
# 用法：resolve_cc_switch_asset "<平台关键词>" "<架构关键词>"
# 输出：<browser_download_url>
resolve_cc_switch_asset() {
  local platform_keyword="$1"
  local arch_keyword="$2"
  local api_url="https://api.github.com/repos/${CC_SWITCH_REPO}/releases/latest"
  local json

  json=$(curl -fsSL --max-time 30 "$api_url" 2>/dev/null) \
    || { err "无法访问 GitHub API：$api_url"; return 1; }

  # 用 grep+sed 解析（避免依赖 jq），按平台/架构关键词 + 文件后缀过滤
  # asset 行示例：  "browser_download_url": "https://.../cc-switch_1.2.3_x64.dmg"
  local url
  url=$(printf '%s\n' "$json" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | sed 's/.*: *"//; s/"$//' \
        | grep -iE "$platform_keyword" \
        | grep -iE "$arch_keyword" \
        | head -n1)

  if [[ -z "$url" ]]; then
    err "在最新 release 中未找到匹配的 cc-switch 安装包"
    err "  platform=$platform_keyword arch=$arch_keyword"
    err "  请到 https://github.com/$CC_SWITCH_REPO/releases 手动下载"
    return 1
  fi
  echo "$url"
}

# 通过代理链下载 GitHub 文件；用户可用 GH_PROXY 覆盖
# 用法：gh_download "<github下载url>" "<本地保存路径>"
gh_download() {
  local gh_url="$1"
  local dest="$2"
  local proxies=()

  if [[ -n "${GH_PROXY:-}" ]]; then
    # 用户自定义代理：自动补全末尾斜杠
    GH_PROXY="${GH_PROXY%/}/"
    proxies=("$GH_PROXY" "")
  else
    proxies=("${DEFAULT_GH_PROXIES[@]}")
  fi

  local prefix tmp
  for prefix in "${proxies[@]}"; do
    tmp="${prefix}${gh_url}"
    log "尝试下载：$tmp"
    if curl -fSL --connect-timeout 15 --max-time 300 -o "$dest" "$tmp"; then
      # 简单校验：文件非空
      if [[ -s "$dest" ]]; then
        ok "下载成功（$(du -h "$dest" | cut -f1)）"
        return 0
      fi
    fi
    warn "此源失败，切换下一个..."
  done
  err "所有下载源均失败：$gh_url"
  return 1
}

# ----------------------------- 环境检测 ------------------------------------
detect_env() {
  section "环境检测"

  OS_KIND="$(uname -s)"     # Darwin / Linux
  ARCH="$(uname -m)"        # arm64 / x86_64 / aarch64
  case "$OS_KIND" in
    Darwin) OS_KIND="macos" ;;
    Linux)  OS_KIND="linux" ;;
    *) die "不支持的系统：${OS_KIND}（本脚本仅支持 macOS / Linux，Windows 请用 install.ps1）" ;;
  esac
  case "$ARCH" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "不支持的 CPU 架构：$ARCH" ;;
  esac
  ok "系统：$OS_KIND / $ARCH"

  # 当前 shell（仅用于提示，不影响逻辑）
  CURRENT_SHELL="$(basename "${SHELL:-/bin/sh}")"
  log "当前默认 shell：$CURRENT_SHELL"

  # 网络连通性：能连国内镜像即可继续
  if curl -fsSL --max-time 10 -o /dev/null "$NPM_REGISTRY" 2>/dev/null; then
    ok "网络连通（npm 镜像可达）"
  else
    die "无法访问 npm 镜像 ${NPM_REGISTRY}，请检查网络"
  fi
}

# ----------------------------- Node.js -------------------------------------
# Node 检查策略（v1.1+，遵循"不强制升级用户可用环境"原则）：
#   - 完全没 Node：必须装（否则 npm 用不了），走 nvm
#   - 有 Node 但版本低于推荐：默认跳过（只警告），用户确认才升级
#     理由：claude/codex 的版本要求随其版本变化，旧版 codex 在 Node 20 下能正常工作，
#           强行 nvm 升级会改变用户默认 Node，影响其他项目。
#   - 版本够：直接通过
ensure_node() {
  section "检查 Node.js（推荐 ≥ ${REQUIRED_NODE_MAJOR}）"

  local cur
  if have node; then
    cur=$(node_major)
    if ge "$cur" "$REQUIRED_NODE_MAJOR"; then
      ok "已安装 Node v${cur}（$(command -v node)），满足推荐版本"
      return 0
    fi
    # 版本低于推荐：默认跳过，不强装
    warn "已安装 Node v${cur}，低于推荐版本 v${REQUIRED_NODE_MAJOR}"
    warn "若 claude/codex 能正常安装运行，可忽略此警告（旧版工具兼容低版本 Node）"
    if confirm "是否仍要通过 nvm 升级到 Node v${REQUIRED_NODE_MAJOR}？（默认 N，直接回车跳过）"; then
      install_node_via_nvm
    else
      ok "跳过 Node 升级，继续使用现有 Node v${cur}"
    fi
    return 0
  fi

  # 完全没 Node：必须装
  warn "未检测到 Node.js（npm 依赖 Node，必须安装）"
  if ! confirm "需要通过 nvm 安装 Node v${REQUIRED_NODE_MAJOR}，是否继续？"; then
    die "用户取消。请手动安装 Node 后重跑本脚本。"
  fi
  install_node_via_nvm
}

# 用 nvm 装 Node（macOS/Linux 通用）
install_node_via_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  # 1) 装 nvm（若不存在）
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log "安装 nvm（Gitee 镜像）..."
    # 优先 Gitee，失败回退官方 raw（少数能直连的环境）
    if curl -fsSL --max-time 60 "$NVM_GITEE_URL" -o /tmp/nvm-install.sh \
       && bash /tmp/nvm-install.sh 2>&1 | tee -a "$LOG_FILE"; then
      ok "nvm 安装完成"
    else
      die "nvm 安装失败（Gitee 镜像也不可达）。可手动装 nvm 后重跑。"
    fi
    rm -f /tmp/nvm-install.sh
  else
    ok "nvm 已存在"
  fi

  # shellcheck disable=SC1091
  source "$NVM_DIR/nvm.sh" || die "无法加载 nvm：$NVM_DIR/nvm.sh"

  # 2) 装 Node LTS（用 npmmirror 二进制镜像加速）
  log "通过 nvm 安装 Node v${REQUIRED_NODE_MAJOR}（npmmirror 镜像）..."
  # nvm 0.39+ 用 NVM_NODEJS_ORG_MIRROR 指向 mirror
  export NVM_NODEJS_ORG_MIRROR="$NODE_MIRROR"
  if ! nvm install --lts "$REQUIRED_NODE_MAJOR" 2>&1 | tee -a "$LOG_FILE"; then
    die "Node 安装失败"
  fi

  # 3) 设默认版本 + alias，避免 Codex "command not found" 坑
  nvm alias default "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1 || true
  nvm use "$REQUIRED_NODE_MAJOR"    >/dev/null 2>&1 || true

  # 4) 确保 nvm 初始化已写入 shell rc（幂等）
  ensure_nvm_in_rc

  local cur
  cur=$(node_major)
  ge "$cur" "$REQUIRED_NODE_MAJOR" \
    && ok "Node v$cur 安装成功" \
    || die "Node 安装后仍不可用，请检查 $LOG_FILE"
}

# 把 nvm 初始化追加到 .zshrc / .bashrc（幂等，已有则跳过）
ensure_nvm_in_rc() {
  local rc_file
  case "$CURRENT_SHELL" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
    *)    rc_file="$HOME/.profile" ;;
  esac
  touch "$rc_file"

  local marker="# >>> nvm initialize >>>"
  if grep -qF "$marker" "$rc_file" 2>/dev/null; then
    return 0
  fi
  {
    echo ""
    echo "$marker"
    echo 'export NVM_DIR="$HOME/.nvm"'
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    echo "# <<< nvm initialize <<<"
  } >> "$rc_file"
  log "已写入 nvm 初始化到 $(basename "$rc_file")（新终端窗口生效）"
}

# ----------------------------- npm 配置 ------------------------------------
configure_npm() {
  section "配置 npm 镜像"

  # 备份 .npmrc：只备份"未被本脚本改过"的原始版本。
  # 判据：.npmrc 存在、尚无 .bak、且当前内容不含本脚本写入的 registry。
  # 这样多次 install/uninstall 循环不会把"已被脚本污染的 .npmrc"当成原始版备份。
  local npmrc="$HOME/.npmrc"
  if [[ -f "$npmrc" && ! -f "${npmrc}.bak" ]]; then
    if ! grep -q "^registry=${NPM_REGISTRY}$" "$npmrc" 2>/dev/null; then
      cp "$npmrc" "${npmrc}.bak"
      log "已备份原始 .npmrc → .npmrc.bak"
    else
      log ".npmrc 已含本脚本 registry，无需备份（避免备份污染版本）"
    fi
  fi

  npm config set registry "$NPM_REGISTRY"
  ok "npm registry = $NPM_REGISTRY"
}

# ----------------------------- 安装 npm 全局包 -----------------------------
npm_install_global() {
  local pkg="$1"
  section "安装 $pkg"
  log "npm install -g $pkg"
  if npm install -g "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
    ok "$pkg 安装完成"
  else
    die "安装 $pkg 失败"
  fi
}

# ----------------------------- cc-switch ----------------------------------
# 安装策略：
#   macOS            → 桌面版 GUI（brew cask 或 dmg）
#   Linux 有 GUI     → 桌面版 AppImage
#   Linux 无头服务器 → CLI 版（npm @songhe/cc-switch，命令 ccs）
install_cc_switch() {
  if [[ "$OS_KIND" == "linux" ]] && is_linux_headless; then
    section "安装 cc-switch CLI 版（无头服务器）"
    install_cc_switch_cli
  else
    section "安装 cc-switch 桌面版"
    if cc_switch_already_installed; then
      ok "cc-switch 桌面版已安装，跳过"
      return 0
    fi
    case "$OS_KIND" in
      macos) install_cc_switch_macos ;;
      linux) install_cc_switch_linux_desktop ;;
    esac
  fi
}

# 返回当前 cc-switch 模式标签（用于文案显示）
cc_switch_mode_label() {
  if [[ "$OS_KIND" == "linux" ]] && is_linux_headless; then
    echo "CLI 版"
  else
    echo "桌面版"
  fi
}

# 检测 cc-switch 是否已安装（与卸载逻辑对齐，只认脚本会装的位置）。
# 注意：Linux 无头服务器检测 CLI 版（ccs 命令），桌面环境检测桌面版位置。
cc_switch_already_installed() {
  case "$OS_KIND" in
    macos)
      [[ -d "/Applications/CC Switch.app" || -d "/Applications/cc-switch.app" \
         || -d "$HOME/Applications/CC Switch.app" || -d "$HOME/Applications/cc-switch.app" ]] \
        || { have brew && brew list --cask cc-switch >/dev/null 2>&1; }
      ;;
    linux)
      if is_linux_headless; then
        # CLI 版：查 ccs 命令 或 npm 全局包
        have "$CCS_CLI_BIN" || npm ls -g --depth=0 2>/dev/null | grep -q "$CCS_CLI_PKG"
      else
        # 桌面版：AppImage / portable 目录 / dpkg 包
        ls "$HOME/.local/bin/"cc-switch*.AppImage >/dev/null 2>&1 \
          || [[ -d "$HOME/.local/bin/cc-switch" ]] \
          || { have dpkg && dpkg -l 2>/dev/null | grep -qi 'cc-switch'; }
      fi
      ;;
  esac
}

# ---- Linux 无头服务器：装 CLI 版 ----
install_cc_switch_cli() {
  if have "$CCS_CLI_BIN"; then
    ok "$CCS_CLI_BIN 已安装（$("$CCS_CLI_BIN" --version 2>/dev/null || echo '?')），跳过"
    return 0
  fi
  log "npm install -g $CCS_CLI_PKG"
  if npm install -g "$CCS_CLI_PKG" 2>&1 | tee -a "$LOG_FILE"; then
    ok "cc-switch CLI 版安装完成（命令：$CCS_CLI_BIN）"
  else
    err "cc-switch CLI 版安装失败"
    return 1
  fi
}

install_cc_switch_macos() {
  # 优先 Homebrew（已装 brew 时最省事）
  if have brew; then
    log "检测到 Homebrew，尝试 brew install --cask cc-switch ..."
    if brew install --cask cc-switch 2>&1 | tee -a "$LOG_FILE"; then
      ok "通过 Homebrew 安装 cc-switch 成功"
      return 0
    fi
    warn "Homebrew 安装失败，回退到直接下载 dmg"
  else
    log "未检测到 Homebrew，直接下载 dmg"
  fi

  # 回退：直接下 dmg 挂载
  local arch_kw
  # macOS 包通常 universal 或带 arm64/x64；尽量匹配架构，否则取通用
  arch_kw="(${ARCH}|universal|darwin|mac|dmg)"

  local url
  url=$(resolve_cc_switch_asset "mac|darwin|\.dmg" "$arch_kw") \
    || return 1

  local dmg="/tmp/cc-switch.dmg"
  gh_download "$url" "$dmg" || return 1

  log "挂载 dmg 并安装..."
  local mountpoint
  mountpoint=$(hdiutil attach "$dmg" -nobrowse -quiet | tail -n1 | awk '{print $NF}')
  local app_src
  app_src=$(find "$mountpoint" -maxdepth 2 -iname "*.app" | head -n1)
  [[ -n "$app_src" ]] || { err "dmg 内未找到 .app"; hdiutil detach "$mountpoint" -quiet; return 1; }

  cp -R "$app_src" /Applications/ 2>&1 | tee -a "$LOG_FILE"
  hdiutil detach "$mountpoint" -quiet
  rm -f "$dmg"
  ok "已安装到 /Applications/$(basename "$app_src")"
}

# ---- Linux 有 GUI：装桌面版 AppImage ----
install_cc_switch_linux_desktop() {
  local arch_kw
  case "$ARCH" in
    x64)   arch_kw="(x86_64|amd64|x64)" ;;
    arm64) arch_kw="(aarch64|arm64)" ;;
  esac

  # 优先 AppImage，回退 portable tar/zip
  local url
  url=$(resolve_cc_switch_asset "linux" "(${arch_kw}).*\.(AppImage|tar\.gz|zip)" ) \
    || return 1

  local ext="${url##*.}"
  local dest_dir="$HOME/.local/bin"
  mkdir -p "$dest_dir"

  local tmp="/tmp/cc-switch-download.$ext"
  gh_download "$url" "$tmp" || return 1

  case "$ext" in
    AppImage)
      mv "$tmp" "$dest_dir/cc-switch.AppImage"
      chmod +x "$dest_dir/cc-switch.AppImage"
      ;;
    gz)
      tar -xzf "$tmp" -C "$dest_dir"
      rm -f "$tmp"
      chmod +x "$dest_dir"/cc-switch* 2>/dev/null || true
      ;;
    zip)
      unzip -o "$tmp" -d "$dest_dir" >/dev/null
      rm -f "$tmp"
      ;;
  esac
  ok "已安装到 $dest_dir"
}

# ----------------------------- 校验 ----------------------------------------
verify() {
  section "安装校验"
  # bash 约定：0 = 成功，非 0 = 失败。这里用 0 表示"全部通过"
  local rc=0

  if have claude; then
    ok "Claude Code：$(claude --version 2>&1 | head -n1)"
  else
    err "claude 命令未找到（新装的命令行工具可能需要新开终端窗口）"
    rc=1
  fi

  if have codex; then
    ok "Codex CLI：$(codex --version 2>&1 | head -n1)"
  else
    err "codex 命令未找到"
    rc=1
  fi

  if cc_switch_already_installed; then
    ok "cc-switch：已安装（$(cc_switch_mode_label)）"
  else
    warn "cc-switch $(cc_switch_mode_label)：未安装"
  fi

  return $rc
}

# ----------------------------- 下一步指引 ----------------------------------
# 返回 Linux 上 cc-switch 的运行提示（区分 CLI/桌面版）
linux_cc_switch_run_hint() {
  if is_linux_headless; then
    echo "运行 ccs 查看供应商列表并交互切换（npm 安装的 CLI 版）"
  else
    echo "双击运行 $HOME/.local/bin/cc-switch.AppImage，或：cc-switch.AppImage &"
  fi
}


print_next_steps() {
  section "下一步：配置国内 LLM API"
  cat <<EOF

${c_bold}1. 启动 cc-switch${color_reset}
   ${c_dim}macOS：${color_reset}在启动台 / Spotlight 搜 "CC Switch"，或运行：
       open -a "CC Switch"
   ${c_dim}Linux：${color_reset}$(linux_cc_switch_run_hint)

${c_bold}2. 获取国内 LLM 的 API Key${color_reset}（任选其一，均无需梯子）：
   ${c_dim}•${color_reset} 智谱 GLM      https://open.bigmodel.cn/          (推荐 GLM-4.6)
   ${c_dim}•${color_reset} DeepSeek     https://platform.deepseek.com/
   ${c_dim}•${color_reset} 阿里通义/百炼 https://bailian.console.aliyun.com/
   ${c_dim}•${color_reset} 月之暗面 Kimi https://platform.moonshot.cn/

${c_bold}3. 在 cc-switch 里新增供应商${color_reset}：
   - 名称：自定义（如 "GLM"）
   - API Base URL：填供应商文档给的接口地址
   - API Key：填上一步拿到的 Key
   - 模型名：填供应商文档里的模型 ID（如 glm-4.6 / deepseek-chat）

${c_bold}4. 切换到该供应商后，启动 Claude Code / Codex 即可${color_reset}
   claude        # 启动 Claude Code
   codex         # 启动 Codex

${c_dim}详细字段对照见 README.md。安装日志：$LOG_FILE${color_reset}
EOF
}

# ----------------------------- 卸载 ----------------------------------------
# 卸载策略：删 npm 全局包 + 删 cc-switch 桌面版 + 还原 .npmrc
# Node.js / nvm 默认保留（可能被其他项目使用），用户可在菜单里单独选删
# 所有删除前都做存在性检查，幂等

# 卸载单个 npm 全局包
npm_uninstall_global() {
  local pkg="$1"
  if npm ls -g --depth=0 2>/dev/null | grep -qE "$(printf '%s' "$pkg" | sed 's/\./\\./g')@"; then
    log "npm uninstall -g $pkg"
    if npm uninstall -g "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
      ok "$pkg 已卸载"
    else
      warn "${pkg} 卸载失败（可手动：npm uninstall -g ${pkg}）"
    fi
  else
    ok "$pkg 未安装，跳过"
  fi
}

# 还原 .npmrc（从备份）
restore_npmrc() {
  local npmrc="$HOME/.npmrc"
  if [[ -f "${npmrc}.bak" ]]; then
    # 备份为空 → 原始就没有 .npmrc，直接删掉当前 .npmrc
    if [[ ! -s "${npmrc}.bak" ]]; then
      rm -f "${npmrc}.bak" "$npmrc"
      ok "原始无 .npmrc，已删除脚本创建的 .npmrc"
    else
      mv -f "${npmrc}.bak" "$npmrc"
      ok "已从备份还原 .npmrc"
    fi
  else
    log "未找到 .npmrc.bak，仅移除 registry 配置"
    npm config delete registry 2>/dev/null || true
    ok "已移除 npm registry 配置"
  fi
}

# 删 cc-switch 桌面版（macOS）
uninstall_cc_switch_macos() {
  local found=0
  for app in "/Applications/CC Switch.app" "/Applications/cc-switch.app" \
             "$HOME/Applications/CC Switch.app" "$HOME/Applications/cc-switch.app"; do
    if [[ -e "$app" ]]; then
      log "删除 $app"
      rm -rf "$app" && { ok "已删除 $(basename "$app")"; found=1; } || warn "删除失败：$app"
    fi
  done
  # 尝试 brew 卸载（如果是 brew 装的）
  if have brew && brew list --cask cc-switch >/dev/null 2>&1; then
    log "brew uninstall --cask cc-switch"
    brew uninstall --cask cc-switch 2>&1 | tee -a "$LOG_FILE" && ok "已通过 brew 卸载" || warn "brew 卸载失败"
    found=1
  fi
  [[ "$found" -eq 1 ]] || ok "cc-switch 未安装（macOS），跳过"
}

# 删 cc-switch（Linux）：无头服务器卸 CLI 版，有 GUI 卸桌面版
uninstall_cc_switch_linux() {
  if is_linux_headless; then
    uninstall_cc_switch_cli
    return
  fi
  # 桌面版
  local found=0
  if ls "$HOME/.local/bin/"cc-switch*.AppImage >/dev/null 2>&1; then
    rm -f "$HOME/.local/bin/"cc-switch*.AppImage && { ok "已删除 AppImage"; found=1; } || warn "AppImage 删除失败"
  fi
  if [[ -d "$HOME/.local/bin/cc-switch" ]]; then
    rm -rf "$HOME/.local/bin/cc-switch" && { ok "已删除 portable 目录"; found=1; }
  fi
  if have dpkg && dpkg -l 2>/dev/null | grep -qi 'cc-switch'; then
    log "sudo apt/dpkg 卸载 cc-switch（需要密码）"
    sudo dpkg -r cc-switch 2>&1 | tee -a "$LOG_FILE" && ok "已通过 dpkg 卸载" || warn "dpkg 卸载失败"
    found=1
  fi
  [[ "$found" -eq 1 ]] || ok "cc-switch 桌面版未安装，跳过"
}

# 卸 cc-switch CLI 版
uninstall_cc_switch_cli() {
  if have "$CCS_CLI_BIN"; then
    log "npm uninstall -g $CCS_CLI_PKG"
    if npm uninstall -g "$CCS_CLI_PKG" 2>&1 | tee -a "$LOG_FILE"; then
      ok "cc-switch CLI 版已卸载"
    else
      warn "CLI 版卸载失败（可手动：npm uninstall -g $CCS_CLI_PKG）"
    fi
  else
    ok "cc-switch CLI 版未安装，跳过"
  fi
}

# 可选：删 nvm 装的 Node（谨慎，默认不删）
remove_nvm_node() {
  if [[ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    warn "未检测到 nvm，跳过 Node 卸载"
    return 0
  fi
  # shellcheck disable=SC1091
  source "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if ! confirm "同时卸载 nvm 管理的 Node v${REQUIRED_NODE_MAJOR}？（如果你用 nvm 装其他版本，仅删此版本）"; then
    log "用户选择保留 Node"
    return 0
  fi
  if nvm ls "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1; then
    nvm uninstall "$REQUIRED_NODE_MAJOR" 2>&1 | tee -a "$LOG_FILE" \
      && ok "已卸载 Node v$REQUIRED_NODE_MAJOR" \
      || warn "Node 卸载失败"
  else
    ok "Node v$REQUIRED_NODE_MAJOR 未通过 nvm 管理，跳过"
  fi
}

uninstall() {
  section "卸载 Claude Code + Codex + cc-switch"

  # 需要可用的 node/npm 才能卸 npm 包；没有就直接跳到删桌面版 + 还原配置
  if have npm; then
    npm_uninstall_global "@anthropic-ai/claude-code"
    npm_uninstall_global "@openai/codex"
  else
    warn "未检测到 npm，跳过 npm 包卸载（命令行工具可能已随 Node 一并移除）"
  fi

  case "$OS_KIND" in
    macos) uninstall_cc_switch_macos ;;
    linux) uninstall_cc_switch_linux ;;
  esac

  restore_npmrc

  section "卸载完成 ✅"
  cat <<EOF

${c_dim}已清理：${color_reset}
  ${c_dim}•${color_reset} @anthropic-ai/claude-code
  ${c_dim}•${color_reset} @openai/codex
  ${c_dim}•${color_reset} cc-switch（$(cc_switch_mode_label)）
  ${c_dim}•${color_reset} npm registry 配置（已还原/移除）

${c_dim}保留：Node.js / nvm（可能被其他项目使用）${color_reset}
${c_dim}如需连 Node 一起删，重跑本脚本选「卸载」后再执行：${color_reset}
  nvm uninstall $REQUIRED_NODE_MAJOR   # 或 brew uninstall node（macOS）

${c_dim}卸载日志：$LOG_FILE${color_reset}
EOF

  # 询问是否连 Node 一起删
  remove_nvm_node
}

# ----------------------------- 交互菜单 ------------------------------------
show_menu() {
  # 菜单输出到 stderr，避免被 $(resolve_action) 捕获污染返回值
  printf '\n%s━━ 请选择操作 ━━%s\n\n' "$c_bold" "$color_reset" >&2
  printf '  %s1)%s 安装 Claude Code + Codex + cc-switch\n' "$c_green" "$color_reset" >&2
  printf '  %s2)%s 卸载（还原可用的初始状态）\n'     "$c_red"   "$color_reset" >&2
  printf '  %s3)%s 仅检查环境（不做任何改动）\n'     "$c_dim"   "$color_reset" >&2
  printf '  %sq)%s 退出\n\n'                          "$c_dim"   "$color_reset" >&2
}

# 解析命令行参数 / 交互输入，返回动作：install / uninstall / check / exit
resolve_action() {
  case "${1:-}" in
    install|uninstall|check) echo "$1"; return 0 ;;
    "") : ;;  # 落到交互
    *)
      err "未知参数：$1"
      err "用法：bash install.sh [install|uninstall|check]"
      exit 2
      ;;
  esac

  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    echo "install"
    return 0
  fi

  local choice
  while true; do
    show_menu
    read -r -p "$(printf '%s请输入选项 [1-3/q]: %s' "$c_yellow" "$color_reset")" choice >&2 || { echo "exit"; return 0; }
    case "$choice" in
      1|i|install)   echo "install";   return 0 ;;
      2|u|uninstall) echo "uninstall"; return 0 ;;
      3|c|check)     echo "check";     return 0 ;;
      q|quit|exit)   echo "exit";      return 0 ;;
      *) warn "无效输入，请重选" ;;
    esac
  done
}

# 仅检查环境，不改动
run_check_only() {
  detect_env
  section "当前已安装"
  if have node; then ok "Node.js $(node -v)"; else warn "Node.js：未安装"; fi
  if have claude; then ok "Claude Code：$(claude --version 2>&1 | head -1)"; else warn "Claude Code：未安装"; fi
  if have codex; then ok "Codex CLI：$(codex --version 2>&1 | head -1)"; else warn "Codex CLI：未安装"; fi
  if cc_switch_already_installed; then ok "cc-switch：已安装（$(cc_switch_mode_label)）"; else warn "cc-switch $(cc_switch_mode_label)：未安装"; fi
  section "检查完成（未做任何改动）"
}

# ----------------------------- 主流程 --------------------------------------
main() {
  # 准备日志
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"   # 每次重置（如需保留可改追加）
  echo "[install.sh v$VERSION] $(date)" | tee -a "$LOG_FILE"

  printf '%s\n' "${c_bold}Claude Code + Codex + cc-switch 管理工具（国内镜像）v$VERSION${color_reset}"
  printf '%s\n' "${c_dim}全程使用国内镜像，无需梯子${color_reset}"

  local action
  action=$(resolve_action "${1:-}")
  case "$action" in
    exit)  ok "已退出"; exit 0 ;;
    check)
      run_check_only
      exit 0
      ;;
  esac

  # install / uninstall 都需要先检测环境
  detect_env

  if [[ "$action" == "uninstall" ]]; then
    uninstall
    section "完成 🎉"
    ok "卸载流程结束。日志：$LOG_FILE"
    return
  fi

  # install
  ensure_node
  configure_npm
  npm_install_global "@anthropic-ai/claude-code"
  npm_install_global "@openai/codex"
  install_cc_switch
  verify || warn "部分组件校验未通过，请查看上方提示"
  print_next_steps

  section "完成 🎉"
  ok "安装流程结束。如有问题，附上日志反馈：$LOG_FILE"
}

main "$@"
