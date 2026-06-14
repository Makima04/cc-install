#!/usr/bin/env bash
# =============================================================================
# test/smoke.sh — install.sh 的基础自检（只读，不执行任何安装）
#
# 验证内容：
#   1. install.sh / install.ps1 语法正确（bash -n）
#   2. install.sh 里定义的关键函数都存在
#   3. 镜像源连通性（npm 镜像、Node 二进制索引、nvm Gitee、GitHub API）
#   4. GitHub API 能返回 cc-switch 最新 release 的可用 asset
#   5. GitHub 代理链中至少一个可达
#
# 用法：bash test/smoke.sh
# 退出码：0 全部通过；非 0 有失败
# =============================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$ROOT_DIR/install.sh"
INSTALL_PS1="$ROOT_DIR/install.ps1"

PASS=0; FAIL=0
c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'; c_reset=$'\033[0m'

pass() { printf '%s[PASS]%s %s\n' "$c_green" "$c_reset" "$1"; PASS=$((PASS+1)); }
fail() { printf '%s[FAIL]%s %s\n' "$c_red"   "$c_reset" "$1"; FAIL=$((FAIL+1)); }
info() { printf '%s[INFO]%s %s\n' "$c_blue"  "$c_reset" "$1"; }

# ---------- 1. 语法检查 ----------
info "1/5 语法检查"

if bash -n "$INSTALL_SH" 2>/dev/null; then
  pass "install.sh bash 语法正确"
else
  fail "install.sh 语法错误"
fi

# PowerShell 语法检查（有 pwsh 才测，没有就跳过）
if command -v pwsh >/dev/null 2>&1; then
  if pwsh -NoProfile -Command "& { \$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '$INSTALL_PS1'), [ref]\$null); 'ok' }" 2>/dev/null | grep -q ok; then
    pass "install.ps1 PowerShell 语法正确"
  else
    fail "install.ps1 语法错误"
  fi
else
  info "未检测到 pwsh，跳过 install.ps1 语法检查"
fi

# ---------- 2. 关键函数存在性 ----------
info "2/5 关键函数检查（install.sh）"

REQUIRED_FUNCS=(
  "main" "detect_env" "ensure_node" "install_node_via_nvm"
  "configure_npm" "npm_install_global" "install_cc_switch"
  "resolve_cc_switch_asset" "gh_download" "verify" "print_next_steps"
  # 卸载与交互菜单（v1.1+ 新增）
  "uninstall" "npm_uninstall_global" "restore_npmrc"
  "uninstall_cc_switch_macos" "uninstall_cc_switch_linux"
  "show_menu" "resolve_action" "run_check_only"
  # cc-switch CLI/桌面版区分（v1.2+ 新增，Linux 无头服务器走 CLI）
  "is_linux_headless" "cc_switch_mode_label" "linux_cc_switch_run_hint"
  "install_cc_switch_cli" "install_cc_switch_linux_desktop"
  "uninstall_cc_switch_cli"
)
for fn in "${REQUIRED_FUNCS[@]}"; do
  if grep -qE "^[[:space:]]*${fn}[[:space:]]*\(\)" "$INSTALL_SH"; then
    pass "函数 $fn 存在"
  else
    fail "函数 $fn 未找到"
  fi
done

# 关键常量
for const in "REQUIRED_NODE_MAJOR" "CC_SWITCH_REPO" "NVM_GITEE_URL"; do
  if grep -qE "readonly[[:space:]]+${const}=" "$INSTALL_SH"; then
    pass "常量 $const 已定义"
  else
    fail "常量 $const 未定义"
  fi
done

# install.ps1 关键函数（PowerShell 用 function Name 形式）
info "install.ps1 关键函数检查"
PS1_REQUIRED_FUNCS=(
  "Main" "Detect-Env" "Ensure-Node" "Configure-Npm" "Install-NpmGlobal"
  "Install-CcSwitch" "Resolve-CcSwitchAsset" "Download-GhAsset"
  "Invoke-Verify" "Print-NextSteps"
  "Invoke-Uninstall" "Uninstall-NpmGlobal" "Restore-Npmrc" "Uninstall-CcSwitch"
  "Show-Menu" "Resolve-Action" "Invoke-CheckOnly"
)
for fn in "${PS1_REQUIRED_FUNCS[@]}"; do
  if grep -qE "^function ${fn}" "$INSTALL_PS1"; then
    pass "ps1 函数 $fn 存在"
  else
    fail "ps1 函数 $fn 未找到"
  fi
done
# install.ps1 必须声明 -Action 参数（用于命令行跳过菜单）
grep -qE '\[string\]\$Action' "$INSTALL_PS1" \
  && pass "ps1 支持 -Action 参数" \
  || fail "ps1 缺少 -Action 参数声明"

# ---------- 3. 镜像连通性 ----------
info "3/5 镜像连通性"

check_url() {
  local name="$1" url="$2" pattern="${3:-}"
  local body
  # 重试一次，容忍偶发网络抖动
  body=$(curl -fsSL --max-time 15 "$url" 2>/dev/null) \
    || body=$(curl -fsSL --max-time 15 "$url" 2>/dev/null)
  if [[ -z "$body" ]]; then
    fail "$name 不可达：$url"
    return 1
  fi
  # 匹配检查：pattern 为空则只看可达性
  # 注意：用 bash 原生 [[ == *substr* ]] 做包含匹配，避免 grep 对超长单行（如大 JSON）的行长度限制
  local matched=1
  if [[ -z "$pattern" ]]; then
    matched=0
  elif [[ "$body" == *"$pattern"* ]]; then
    matched=0
  fi
  if [[ "$matched" -eq 0 ]]; then
    pass "$name 可达"
    return 0
  fi
  fail "$name 返回内容不符合预期（缺 ${pattern:-<空>}）"
  return 1
}

check_url "npm 镜像(npmmirror)"   "https://registry.npmmirror.com" "registry"
check_url "Node 二进制索引"        "https://registry.npmmirror.com/-/binary/node/index.json" "version"
check_url "nvm Gitee 镜像"         "https://gitee.com/mirrors/nvm/raw/v0.40.1/install.sh"  "nvm"

# ---------- 4. GitHub API cc-switch release ----------
info "4/5 GitHub API（cc-switch release）"

API_URL="https://api.github.com/repos/farion1231/cc-switch/releases/latest"
if API_JSON=$(curl -fsSL --max-time 20 "$API_URL" 2>/dev/null); then
  pass "GitHub API 可达"
  # 解析 asset 数量
  ASSET_COUNT=$(printf '%s\n' "$API_JSON" | grep -c '"browser_download_url"')
  if [[ "$ASSET_COUNT" -gt 0 ]]; then
    pass "最新 release 含 $ASSET_COUNT 个可下载 asset"
    # 抽样打印 3 个下载 URL，便于人工核对命名
    info "  示例 asset："
    printf '%s\n' "$API_JSON" \
      | grep -o '"browser_download_url": *"[^"]*"' \
      | sed 's/.*: *"//; s/"$//' \
      | head -n3 \
      | while read -r u; do printf '%s    - %s%s\n' "$c_yellow" "$u" "$c_reset"; done
  else
    fail "最新 release 没有 asset（可能是源码-only release，脚本将无法下载二进制）"
  fi
else
  fail "GitHub API 不可达（国内偶发，重试或配 GH_PROXY）"
fi

# ---------- 5. GitHub 代理链可达性 ----------
info "5/5 GitHub 代理链可达性"

# 用一个轻量文件测代理是否能正常代理 github raw（约几 KB）
TEST_GH_URL="https://raw.githubusercontent.com/farion1231/cc-switch/main/README.md"
PROXIES=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" "")

PROXY_OK=0
for p in "${PROXIES[@]}"; do
  label="${p:-直连}"
  if curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null "${p}${TEST_GH_URL}" 2>/dev/null; then
    pass "代理可达：$label"
    PROXY_OK=$((PROXY_OK+1))
  else
    info "代理不可达：$label（正常，会自动切下一个）"
  fi
done

if [[ "$PROXY_OK" -ge 1 ]]; then
  pass "至少有一个下载源可用（共 $PROXY_OK 个）"
else
  fail "所有代理 + 直连均不可达（网络问题）"
fi

# ---------- 汇总 ----------
echo ""
printf '%s━━ 汇总 ━━%s\n' "$c_blue" "$c_reset"
printf '通过: %s%d%s  失败: %s%d%s\n' \
  "$c_green" "$PASS" "$c_reset" \
  "$([ $FAIL -gt 0 ] && printf '%s' "$c_red")" "$FAIL" "$c_reset"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
