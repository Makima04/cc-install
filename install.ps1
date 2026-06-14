<#
.SYNOPSIS
    一键安装 Claude Code + Codex + cc-switch（Windows PowerShell）
.DESCRIPTION
    全程走国内镜像，无需梯子。运行时 API 走国内 LLM 厂商官方接口。
.NOTES
    版本：1.0.0
    要求：Windows 10/11，PowerShell 5.1+（或 PowerShell 7+）
.EXAMPLE
    # 一行命令（推荐）
    irm https://raw.githubusercontent.com/Makima04/cc-install/main/install.ps1 | iex

    # 本地运行
    powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
    # 用自定义 GitHub 代理 / npm 镜像
    $env:GH_PROXY = "https://ghfast.top/"
    $env:NPM_REGISTRY = "https://registry.npmmirror.com"
    .\install.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NonInteractive,   # 等价于 NONINTERACTIVE=1
    [ArgumentCompleter({ 'install','uninstall','check' })]
    [string]$Action            # 可选：install / uninstall / check，跳过交互菜单
)

# 强制用 UTF-8 输出，避免中文乱码（PS5.1 默认 GBK）
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ----------------------------- 常量 ----------------------------------------
$script:VERSION               = '1.0.0'
$script:REQUIRED_NODE_MAJOR   = 22
$script:CC_SWITCH_REPO        = 'farion1231/cc-switch'

if (-not $env:NPM_REGISTRY)  { $env:NPM_REGISTRY  = 'https://registry.npmmirror.com' }
if (-not $env:NODE_MIRROR)   { $env:NODE_MIRROR   = 'https://registry.npmmirror.com/-/binary/node' }

# GitHub 代理回退链（末尾带 /，拼接 url 时直接前置）
$script:GH_PROXIES = @(
    'https://ghfast.top/'
    'https://gh-proxy.com/'
    'https://ghproxy.net/'
    ''                              # 空串 = 直连
)

$script:LOG_DIR  = Join-Path $env:USERPROFILE '.cc-installer'
$script:LOG_FILE = Join-Path $script:LOG_DIR 'install.log'

# ----------------------------- 日志美化 ------------------------------------
function Write-Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -Path $script:LOG_FILE -Value $line -ErrorAction SilentlyContinue
}
function Write-Ok($msg)   { Write-Host "✅ $msg" -ForegroundColor Green;  Add-Content -Path $script:LOG_FILE -Value "✅ $msg" -ErrorAction SilentlyContinue }
function Write-Warn2($msg){ Write-Host "⚠️  $msg" -ForegroundColor Yellow; Add-Content -Path $script:LOG_FILE -Value "⚠ $msg" -ErrorAction SilentlyContinue }
function Write-Err2($msg) { Write-Host "❌ $msg" -ForegroundColor Red;     Add-Content -Path $script:LOG_FILE -Value "❌ $msg" -ErrorAction SilentlyContinue }
function Write-Section($t){ Write-Host ""; Write-Host "━━ $t ━━" -ForegroundColor White }
function Die($msg) {
    Write-Err2 $msg
    Write-Err2 "详细日志：$script:LOG_FILE"
    exit 1
}

# ----------------------------- 工具函数 ------------------------------------
function Test-Command($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Get-NodeMajor {
    if (-not (Test-Command node)) { return 0 }
    try {
        $v = (& node -v).TrimStart('v')
        return [int]($v.Split('.')[0])
    } catch { return 0 }
}

function Confirm-Action($prompt) {
    if ($NonInteractive) { return $true }
    $reply = Read-Host "$prompt [Y/n]"
    if (-not $reply) { $reply = 'y' }
    return $reply -match '^[Yy]'
}

# 通过 GitHub API 拿最新 release 中匹配的 asset 下载地址
function Resolve-CcSwitchAsset($platformKw, $archKw) {
    $api = "https://api.github.com/repos/$script:CC_SWITCH_REPO/releases/latest"
    try {
        $resp = Invoke-RestMethod -Uri $api -TimeoutSec 30 -Headers @{ 'User-Agent' = 'cc-installer' }
    } catch {
        Die "无法访问 GitHub API：$api`n$_"
    }
    # assets 里 browser_download_url 同时匹配平台/架构关键词（不区分大小写）
    $match = $resp.assets | Where-Object {
        $_.browser_download_url -match $platformKw -and $_.browser_download_url -match $archKw
    } | Select-Object -First 1

    if (-not $match) {
        Write-Err2 "在最新 release 中未找到匹配的 cc-switch 安装包"
        Write-Err2 "  platform=$platformKw arch=$archKw"
        Write-Err2 "  请到 https://github.com/$script:CC_SWITCH_REPO/releases 手动下载"
        exit 1
    }
    return $match.browser_download_url
}

# 通过代理链下载 GitHub 文件
function Download-GhAsset($ghUrl, $dest) {
    $proxies = $script:GH_PROXIES
    if ($env:GH_PROXY) {
        $custom = $env:GH_PROXY.TrimEnd('/') + '/'
        $proxies = @($custom, '')
    }
    foreach ($p in $proxies) {
        $full = "$p$ghUrl"
        Write-Log "尝试下载：$full"
        try {
            Invoke-WebRequest -Uri $full -OutFile $dest -UseBasicParsing -TimeoutSec 300
            if ((Get-Item $dest).Length -gt 0) {
                $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
                Write-Ok "下载成功（${size} MB）"
                return
            }
        } catch {
            Write-Warn2 "此源失败，切换下一个..."
        }
    }
    Die "所有下载源均失败：$ghUrl"
}

# ----------------------------- 环境检测 ------------------------------------
function Detect-Env {
    Write-Section '环境检测'

    $script:OS_KIND = 'windows'
    # Windows 架构：AMD64 → x64，ARM64 → arm64
    $cpu = $env:PROCESSOR_ARCHITECTURE
    if ($cpu -match 'ARM') { $script:ARCH = 'arm64' } else { $script:ARCH = 'x64' }
    Write-Ok "系统：$script:OS_KIND / $script:ARCH"

    # 网络连通性
    try {
        $null = Invoke-WebRequest -Uri $env:NPM_REGISTRY -UseBasicParsing -TimeoutSec 10
        Write-Ok '网络连通（npm 镜像可达）'
    } catch {
        Die "无法访问 npm 镜像 $($env:NPM_REGISTRY)，请检查网络"
    }
}

# ----------------------------- Node.js -------------------------------------
function Ensure-Node {
    Write-Section "检查 Node.js（要求 ≥ $($script:REQUIRED_NODE_MAJOR)）"

    $cur = Get-NodeMajor
    if ($cur -ge $script:REQUIRED_NODE_MAJOR) {
        $path = (Get-Command node).Source
        Write-Ok "已安装 Node v$cur（$path），满足要求"
        return
    }
    if ($cur -gt 0) {
        Write-Warn2 "已安装 Node v$cur，低于要求 v$($script:REQUIRED_NODE_MAJOR)"
    } else {
        Write-Warn2 '未检测到 Node.js'
    }

    if (-not (Confirm-Action "需要安装/升级 Node.js v$($script:REQUIRED_NODE_MAJOR)（静默 MSI），是否继续？")) {
        Die "用户取消。请手动安装 Node ≥ $($script:REQUIRED_NODE_MAJOR) 后重跑本脚本。"
    }
    Install-NodeViaMsi
}

function Install-NodeViaMsi {
    # 1) 取最新 LTS v22.x 版本号
    Write-Log '查询最新 Node v22.x 版本号...'
    $indexUrl = "$($env:NODE_MIRROR)/index.json"
    try {
        $index = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing -TimeoutSec 30
    } catch {
        Die "无法获取 Node 版本索引：$indexUrl"
    }
    $ver = ($index | Where-Object {
        $_.version -match "^v$($script:REQUIRED_NODE_MAJOR)\." -and $_.lts
    } | Select-Object -First 1)
    if (-not $ver) {
        # 没有 LTS 就取最新的 22.x
        $ver = ($index | Where-Object { $_.version -match "^v$($script:REQUIRED_NODE_MAJOR)\." } | Select-Object -First 1)
    }
    if (-not $ver) { Die "Node 镜像中找不到 v$($script:REQUIRED_NODE_MAJOR).x" }

    $nodeVer = $ver.version   # 形如 v22.x.y
    $url = "$($env:NODE_MIRROR)/$nodeVer/node-$nodeVer-win-$($script:ARCH).msi"
    $msi = Join-Path $env:TEMP "node-install.msi"

    Write-Log "下载 $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 300
    } catch {
        Die "Node MSI 下载失败：$url`n$_"
    }
    if (-not (Test-Path $msi) -or (Get-Item $msi).Length -eq 0) {
        Die "Node MSI 下载为空：$url"
    }

    # 2) 静默安装（/qb 带基础 UI，需 UAC 提权）
    Write-Log '静默安装 Node MSI（可能弹出 UAC 提权窗口）...'
    $args = @('/i', "`"$msi`"", '/qb', '/norestart')
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru -Verb RunAs
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        Die "Node MSI 安装失败（退出码 $($proc.ExitCode)）"
    }

    # 3) 刷新当前会话 PATH（Node 装在 C:\Program Files\nodejs）
    $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
    if (-not ($env:PATH -split ';' -contains $nodeDir)) {
        $env:PATH = "$nodeDir;$env:PATH"
    }

    # 4) 校验
    $cur = Get-NodeMajor
    if ($cur -ge $script:REQUIRED_NODE_MAJOR) {
        Write-Ok "Node v$cur 安装成功"
    } else {
        Die "Node 安装后仍不可用，请重开 PowerShell 后重跑，或检查 $script:LOG_FILE"
    }
}

# ----------------------------- npm 配置 ------------------------------------
function Configure-Npm {
    Write-Section '配置 npm 镜像'

    # 备份 .npmrc：只备份"未被本脚本改过"的原始版本，避免 install/uninstall 循环污染
    $npmrc = Join-Path $env:USERPROFILE '.npmrc'
    $bak   = "$npmrc.bak"
    if ((Test-Path $npmrc) -and -not (Test-Path $bak)) {
        $content = Get-Content $npmrc -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch "^registry=$($env:NPM_REGISTRY)`$") {
            Copy-Item $npmrc $bak
            Write-Log "已备份原始 .npmrc → .npmrc.bak"
        } else {
            Write-Log ".npmrc 已含本脚本 registry，无需备份"
        }
    }
    & npm config set registry $env:NPM_REGISTRY
    Write-Ok "npm registry = $($env:NPM_REGISTRY)"
}

# ----------------------------- npm 全局安装 --------------------------------
function Install-NpmGlobal($pkg) {
    Write-Section "安装 $pkg"
    Write-Log "npm install -g $pkg"
    & npm install -g $pkg 2>&1 | Tee-Object -FilePath $script:LOG_FILE -Append
    if ($LASTEXITCODE -ne 0) { Die "安装 $pkg 失败" }
    Write-Ok "$pkg 安装完成"
}

# ----------------------------- cc-switch 桌面版 ----------------------------
function Test-CcSwitchInstalled {
    # 常见安装路径
    $paths = @(
        Join-Path $env:LOCALAPPDATA 'Programs\cc-switch\cc-switch.exe'
        Join-Path $env:ProgramFiles 'cc-switch\cc-switch.exe'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

function Install-CcSwitch {
    Write-Section '安装 cc-switch 桌面版'

    if (Test-CcSwitchInstalled) {
        Write-Ok 'cc-switch 已安装，跳过'
        return
    }

    # Windows：匹配 .msi（首选）或 portable .zip
    $archKw = if ($script:ARCH -eq 'arm64') { '(arm64|aarch64)' } else { '(x64|amd64|x86_64)?' }
    $url = Resolve-CcSwitchAsset '(win|windows)' "$archKw.*\.(msi|zip)"

    if ($url -match '\.msi$') {
        Install-CcSwitchMsi $url
    } elseif ($url -match '\.zip$') {
        Install-CcSwitchPortable $url
    } else {
        Die "无法识别 cc-switch 安装包格式：$url"
    }
}

function Install-CcSwitchMsi($url) {
    $msi = Join-Path $env:TEMP 'cc-switch.msi'
    Download-GhAsset $url $msi

    Write-Log '静默安装 cc-switch MSI（可能弹出 UAC）...'
    $args = @('/i', "`"$msi`"", '/qb', '/norestart')
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru -Verb RunAs
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        Die "cc-switch MSI 安装失败（退出码 $($proc.ExitCode)）"
    }
    Write-Ok 'cc-switch 安装完成'
}

function Install-CcSwitchPortable($url) {
    $zip = Join-Path $env:TEMP 'cc-switch.zip'
    Download-GhAsset $url $zip

    $dest = Join-Path $env:LOCALAPPDATA 'Programs\cc-switch'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    # 尝试创建桌面快捷方式
    $exe = Get-ChildItem $dest -Filter 'cc-switch.exe' -Recurse | Select-Object -First 1
    if ($exe) {
        $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CC Switch.lnk'
        try {
            $shell = New-Object -ComObject WScript.Shell
            $s = $shell.CreateShortcut($shortcut)
            $s.TargetPath = $exe.FullName
            $s.Save()
            Write-Ok "已解压并创建桌面快捷方式：$shortcut"
        } catch {
            Write-Ok "已解压到 $dest"
        }
    } else {
        Write-Ok "已解压到 $dest"
    }
}

# ----------------------------- 校验 ----------------------------------------
function Invoke-Verify {
    Write-Section '安装校验'
    $allOk = $true

    if (Test-Command claude) {
        $v = (& claude --version 2>&1 | Select-Object -First 1)
        Write-Ok "Claude Code：$v"
    } else {
        Write-Err2 'claude 命令未找到（新装的工具可能需要重开 PowerShell 窗口）'
        $allOk = $false
    }

    if (Test-Command codex) {
        $v = (& codex --version 2>&1 | Select-Object -First 1)
        Write-Ok "Codex CLI：$v"
    } else {
        Write-Err2 'codex 命令未找到'
        $allOk = $false
    }

    if (Test-CcSwitchInstalled) {
        Write-Ok 'cc-switch 桌面版：已安装'
    } else {
        Write-Warn2 'cc-switch 未检测到（可能需要手动确认安装位置）'
    }
    return $allOk
}

# ----------------------------- 下一步指引 ----------------------------------
function Print-NextSteps {
    Write-Section '下一步：配置国内 LLM API'
    @"

1. 启动 cc-switch
   从开始菜单搜 "CC Switch" 或双击桌面快捷方式

2. 获取国内 LLM 的 API Key（任选其一，均无需梯子）：
   • 智谱 GLM      https://open.bigmodel.cn/          (推荐 GLM-4.6)
   • DeepSeek      https://platform.deepseek.com/
   • 阿里通义/百炼 https://bailian.console.aliyun.com/
   • 月之暗面 Kimi https://platform.moonshot.cn/

3. 在 cc-switch 里新增供应商：
   - 名称：自定义（如 "GLM"）
   - API Base URL：填供应商文档给的接口地址
   - API Key：填上一步拿到的 Key
   - 模型名：填供应商文档里的模型 ID（如 glm-4.6 / deepseek-chat）

4. 切换到该供应商后，启动 Claude Code / Codex 即可
   claude
   codex

详细字段对照见 README.md。安装日志：$script:LOG_FILE
"@ | Write-Host
}

# ----------------------------- 卸载 ----------------------------------------
# 卸载 npm 全局包（幂等：未安装则跳过）
function Uninstall-NpmGlobal($pkg) {
    $installed = & npm ls -g --depth=0 2>$null | Select-String -SimpleMatch $pkg
    if (-not $installed) {
        Write-Ok "$pkg 未安装，跳过"
        return
    }
    Write-Log "npm uninstall -g $pkg"
    & npm uninstall -g $pkg 2>&1 | Tee-Object -FilePath $script:LOG_FILE -Append
    if ($LASTEXITCODE -eq 0) { Write-Ok "$pkg 已卸载" }
    else { Write-Warn2 "$pkg 卸载失败（可手动：npm uninstall -g $pkg）" }
}

# 还原 .npmrc（从备份）
function Restore-Npmrc {
    $npmrc = Join-Path $env:USERPROFILE '.npmrc'
    $bak   = "$npmrc.bak"
    if (Test-Path $bak) {
        # 备份为空 → 原始无 .npmrc，删除脚本创建的 .npmrc
        if ((Get-Item $bak).Length -eq 0) {
            Remove-Item $bak, $npmrc -Force -ErrorAction SilentlyContinue
            Write-Ok '原始无 .npmrc，已删除脚本创建的 .npmrc'
        } else {
            Move-Item -Force $bak $npmrc
            Write-Ok '已从备份还原 .npmrc'
        }
    } else {
        Write-Log '未找到 .npmrc.bak，仅移除 registry 配置'
        & npm config delete registry 2>$null
        Write-Ok '已移除 npm registry 配置'
    }
}

# 删 cc-switch 桌面版：MSI 安装的从注册表卸载，portable 的删目录
function Uninstall-CcSwitch {
    # 1) MSI 安装：从注册表找卸载串
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = $false
    foreach ($key in $uninstallKeys) {
        try {
            $entry = Get-ItemProperty $key -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'CC ?Switch|cc-switch' } |
                Select-Object -First 1
            if ($entry -and $entry.UninstallString) {
                $uninst = $entry.UninstallString -replace '^"', '' -replace '"$', ''
                Write-Log "通过 MSI 卸载：$($entry.DisplayName)"
                # 静默卸载（/qb 带 UI，/qn 无 UI）
                $args = @('/x', "`"$($entry.PSChildName)`"", '/qb', '/norestart')
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru -Verb RunAs
                if ($proc.ExitCode -eq 0) { Write-Ok '已通过 MSI 卸载 cc-switch' }
                else { Write-Warn2 "MSI 卸载返回码 $($proc.ExitCode)" }
                $found = $true
                break
            }
        } catch { }
    }

    # 2) Portable 解压目录
    $portableDir = Join-Path $env:LOCALAPPDATA 'Programs\cc-switch'
    if (Test-Path $portableDir) {
        Remove-Item -Recurse -Force $portableDir -ErrorAction SilentlyContinue
        Write-Ok "已删除 portable 目录：$portableDir"
        $found = $true
    }

    # 3) 桌面快捷方式
    $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CC Switch.lnk'
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
        Write-Ok '已删除桌面快捷方式'
    }

    if (-not $found) { Write-Ok 'cc-switch 未检测到，跳过' }
}

function Invoke-Uninstall {
    Write-Section '卸载 Claude Code + Codex + cc-switch'

    if (Test-Command npm) {
        Uninstall-NpmGlobal '@anthropic-ai/claude-code'
        Uninstall-NpmGlobal '@openai/codex'
    } else {
        Write-Warn2 '未检测到 npm，跳过 npm 包卸载'
    }

    Uninstall-CcSwitch
    Restore-Npmrc

    Write-Section '卸载完成 ✅'
    @"

已清理：
  • @anthropic-ai/claude-code
  • @openai/codex
  • cc-switch 桌面版
  • npm registry 配置（已还原/移除）

保留：Node.js（可能被其他项目使用）
如需连 Node 一起删：控制面板 → 程序和功能 → Node.js → 卸载

卸载日志：$script:LOG_FILE
"@ | Write-Host
}

# ----------------------------- 交互菜单 ------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host "━━ 请选择操作 ━━" -ForegroundColor White
    Write-Host "  1) 安装 Claude Code + Codex + cc-switch" -ForegroundColor Green
    Write-Host "  2) 卸载（还原可用的初始状态）"           -ForegroundColor Red
    Write-Host "  3) 仅检查环境（不做任何改动）"           -ForegroundColor DarkGray
    Write-Host "  q) 退出`n"                                -ForegroundColor DarkGray
}

# 返回动作：install / uninstall / check / exit
function Resolve-Action {
    param([string]$Arg)
    switch -Regex ($Arg) {
        '^(install|uninstall|check)$' { return $Arg }
        '^$' { }                      # 落到交互
        '.'  {
            Write-Err2 "未知参数：$Arg"
            Write-Err2 '用法：.\install.ps1 [install|uninstall|check]'
            exit 2
        }
    }
    if ($NonInteractive) { return 'install' }

    while ($true) {
        Show-Menu
        $choice = Read-Host '请输入选项 [1-3/q]'
        switch -Regex ($choice) {
            '^(1|i|install)$'    { return 'install' }
            '^(2|u|uninstall)$'  { return 'uninstall' }
            '^(3|c|check)$'      { return 'check' }
            '^(q|quit|exit)$'    { return 'exit' }
            default { Write-Warn2 '无效输入，请重选' }
        }
    }
}

# 仅检查环境，不改动
function Invoke-CheckOnly {
    Detect-Env
    Write-Section '当前已安装'
    if (Test-Command node)   { Write-Ok "Node.js $(node -v)" }       else { Write-Warn2 'Node.js：未安装' }
    if (Test-Command claude) { Write-Ok "Claude Code：$(claude --version 2>&1 | Select-Object -First 1)" }
    else { Write-Warn2 'Claude Code：未安装' }
    if (Test-Command codex)  { Write-Ok "Codex CLI：$(codex --version 2>&1 | Select-Object -First 1)" }
    else { Write-Warn2 'Codex CLI：未安装' }
    if (Test-CcSwitchInstalled) { Write-Ok 'cc-switch 桌面版：已安装' }
    else { Write-Warn2 'cc-switch 桌面版：未安装' }
    Write-Section '检查完成（未做任何改动）'
}

# ----------------------------- 主流程 --------------------------------------
function Main {
    # 准备日志
    New-Item -ItemType Directory -Force -Path $script:LOG_DIR | Out-Null
    Set-Content -Path $script:LOG_FILE -Value "[install.ps1 v$($script:VERSION)] $(Get-Date)"

    Write-Host "Claude Code + Codex + cc-switch 管理工具（国内镜像）v$($script:VERSION)" -ForegroundColor White
    Write-Host "全程使用国内镜像，无需梯子" -ForegroundColor DarkGray

    # $Action 来自脚本 param 块；未传时为空串，Resolve-Action 会进入交互菜单
    $action = Resolve-Action -Arg $Action

    switch ($action) {
        'exit' { Write-Ok '已退出'; exit 0 }
        'check' { Invoke-CheckOnly; exit 0 }
        'uninstall' {
            Detect-Env
            Invoke-Uninstall
            Write-Section '完成 🎉'
            Write-Ok "卸载流程结束。日志：$script:LOG_FILE"
            return
        }
    }

    # install
    Detect-Env
    Ensure-Node
    Configure-Npm
    Install-NpmGlobal '@anthropic-ai/claude-code'
    Install-NpmGlobal '@openai/codex'
    Install-CcSwitch
    if (-not (Invoke-Verify)) { Write-Warn2 '部分组件校验未通过，请查看上方提示' }
    Print-NextSteps

    Write-Section '完成 🎉'
    Write-Ok "安装流程结束。如有问题，附上日志反馈：$script:LOG_FILE"
}

Main
