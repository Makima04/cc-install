<#
.SYNOPSIS
    一键安装 Claude Code + Codex + cc-switch（Windows PowerShell）
.DESCRIPTION
    全程走国内镜像，无需梯子。运行时 API 走国内 LLM 厂商官方接口。
.NOTES
    版本：1.1.0
    要求：Windows 10/11，PowerShell 5.1+（或 PowerShell 7+）
.EXAMPLE
    # 一行命令（推荐）
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Makima04/cc-install/main/install.ps1).TrimStart([char]0xFEFF)))

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
    [ArgumentCompleter({ 'install','uninstall','check','update' })]
    [string]$Action,           # install / uninstall / check / update，跳过交互菜单
    [ArgumentCompleter({ 'all','claude','codex','ccswitch' })]
    [string]$Component         # all / claude / codex / ccswitch，默认 all
)

# 强制用 UTF-8 输出，避免中文乱码（PS5.1 默认 GBK）
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ----------------------------- 常量 ----------------------------------------
$script:VERSION               = '1.1.0'
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

# 查询 cc-switch 最新 release 版本号（走代理链 + 重定向，不依赖 API，规避限流）
# 思路：GitHub 对 /releases/latest 返回 302，Location 末段即 tag（如 v3.16.2）。
#       代理（ghfast.top 等）能转发该重定向，但无法转发 api.github.com（403），
#       所以这里坚决不碰 API。
function Get-CcSwitchLatestTag {
    $proxies = $script:GH_PROXIES
    if ($env:GH_PROXY) {
        $custom = $env:GH_PROXY.TrimEnd('/') + '/'
        $proxies = @($custom, '')
    }
    $releaseUrl = "https://github.com/$script:CC_SWITCH_REPO/releases/latest"
    foreach ($p in $proxies) {
        $full = "$p$releaseUrl"
        Write-Log "查询最新版本（跟随重定向）：$full"
        try {
            $resp = Invoke-WebRequest -Uri $full -UseBasicParsing -TimeoutSec 30
            # 落地 URL 末段即 tag；兼容 PS5.1（ResponseUri）与 PS7（RequestMessage.RequestUri）
            $finalUri = $null
            if ($resp.BaseResponse.ResponseUri) {
                $finalUri = $resp.BaseResponse.ResponseUri.AbsoluteUri
            } elseif ($resp.BaseResponse.RequestMessage.RequestUri) {
                $finalUri = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            }
            if ($finalUri -and $finalUri -match '/(v\d+\.\d+\.\d+)/?$') {
                Write-Log "最新版本：$($Matches[1])"
                return $Matches[1]
            }
        } catch {
            Write-Warn2 "此源失败，切换下一个..."
        }
    }
    return $null
}

# 用「tag + 命名规则」拼出当前平台对应的 cc-switch 安装包下载地址（不调 API，规避限流）
# 命名规则（v3.x 实测）：CC-Switch-{tag}-{Platform}[.ext]
#   Windows: CC-Switch-v3.16.2-Windows.msi（不分架构）
#   macOS  : CC-Switch-v3.16.2-macOS.dmg
#   Linux  : CC-Switch-v3.16.2-Linux-{x86_64|arm64}.AppImage
function Resolve-CcSwitchAsset {
    $tag = Get-CcSwitchLatestTag
    if (-not $tag) {
        Write-Err2 "无法获取 cc-switch 最新版本（GitHub API 限流，且所有代理/直连均失败）"
        Write-Err2 "  请稍后重试，或手动到 https://github.com/$script:CC_SWITCH_REPO/releases 下载"
        exit 1
    }
    $fname = switch ($script:OS_KIND) {
        'windows' { "CC-Switch-$tag-Windows.msi" }
        'macos'   { "CC-Switch-$tag-macOS.dmg" }
        'linux'   {
            if ($script:ARCH -eq 'arm64') { "CC-Switch-$tag-Linux-arm64.AppImage" }
            else { "CC-Switch-$tag-Linux-x86_64.AppImage" }
        }
        default { Die "不支持的平台：$script:OS_KIND" }
    }
    $url = "https://github.com/$script:CC_SWITCH_REPO/releases/download/$tag/$fname"
    Write-Log "cc-switch 安装包：$url"
    return $url
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

# 仅下载 cc-switch 安装包到「下载」文件夹，不自动安装
# 设计动机：
#   1) 原方案静默 MSI 安装需 UAC 提权，失败点多；改由用户双击自行安装更可控。
#   2) 全程走 GitHub 代理链下载，不调 API（规避限流）。
function Download-CcSwitch {
    Write-Section '下载 cc-switch 安装包'

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path $downloads)) {
        New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    }

    $url   = Resolve-CcSwitchAsset
    $fname = Split-Path $url -Leaf
    $dest  = Join-Path $downloads $fname

    # 已下载且非空 → 跳过（幂等）
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) {
        $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
        Write-Ok "已存在同名文件，跳过下载：$dest（${size} MB）"
        Write-Host  '  → 双击该文件即可安装 cc-switch（MSI 安装可能弹出 UAC）' -ForegroundColor DarkGray
        return
    }

    Download-GhAsset $url $dest

    $size = [math]::Round((Get-Item $dest).Length / 1MB, 1)
    Write-Ok "下载完成：$dest（${size} MB）"
    Write-Host  '  → 双击该文件即可安装 cc-switch（MSI 安装可能弹出 UAC）' -ForegroundColor DarkGray
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
        # cc-switch 由用户手动安装：未检测到不算失败，仅提示去「下载」文件夹双击安装包
        Write-Warn2 'cc-switch 桌面版：未检测到（安装包已下载到「下载」文件夹，请双击安装）'
    }
    return $allOk
}

# ----------------------------- 下一步指引 ----------------------------------
function Print-NextSteps {
    Write-Section '下一步：配置国内 LLM API'
    @"

1. 安装并启动 cc-switch
   打开「下载」文件夹，双击 CC-Switch-*.msi 安装；
   之后从开始菜单搜 "CC Switch" 启动

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

# 检测 Claude Code 的安装方式：'native'（原生安装器）/ 'npm' / 'none'
# 原生安装器把 claude.exe 放在 ~/.local/bin/，版本副本在 ~/.claude/local/
# 用路径判断而非 claude doctor（后者有大量误报 bug，不可靠）
function Get-ClaudeInstallType {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return 'none' }
    $src = $cmd.Source
    if ($src -match '\.local[\\/]+bin[\\/]+claude(\.exe)?$') { return 'native' }
    # 兜底：命令路径不在 .local/bin 但存在版本副本目录 → 也算原生
    $localDir = Join-Path $env:USERPROFILE '.claude\local'
    if (Test-Path $localDir) { return 'native' }
    return 'npm'
}

# 卸载 Claude Code 原生安装（文件级清理）
# 注意：只删二进制 + 版本副本目录，绝不删 ~/.claude（含用户配置/数据）
function Uninstall-ClaudeNative {
    # 1) 杀掉运行中的 claude 进程，避免 Windows 文件锁导致删除失败
    $procs = Get-Process claude -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "终止 claude 进程（$($procs.Count) 个）..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    # 2) 删启动器 ~/.local/bin/claude(.exe)
    $binDir = Join-Path $env:USERPROFILE '.local\bin'
    foreach ($name in @('claude.exe', 'claude')) {
        $bin = Join-Path $binDir $name
        if (Test-Path $bin) {
            Remove-Item $bin -Force -ErrorAction SilentlyContinue
            if (Test-Path $bin) {
                Write-Warn2 "无法删除 $bin（可能被占用，请关闭所有 claude 进程后重试）"
            } else {
                Write-Ok "已删除 $bin"
            }
        }
    }

    # 3) 删版本副本目录 ~/.claude/local（不删 ~/.claude 本身！）
    $localDir = Join-Path $env:USERPROFILE '.claude\local'
    if (Test-Path $localDir) {
        Remove-Item $localDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $localDir) {
            Write-Warn2 "无法删除 $localDir（可能被占用）"
        } else {
            Write-Ok "已删除版本副本目录 $localDir"
        }
    }

    # 4) PATH 不自动改：~/.local/bin 可能被其他工具共用
    #    仅在日志里提示，用户可按需手动从用户 PATH 移除 ~/.local/bin
    Write-Log '提示：~/.local/bin 未从 PATH 移除（可能被其他工具共用），如需可手动清理'

    # 5) 校验：claude 命令是否真的不可用了
    if (Test-Command claude) {
        Write-Warn2 '卸载后 claude 命令仍可用，可能存在多份安装（如同时有 npm 版）。可重跑卸载。'
    } else {
        Write-Ok 'Claude Code 原生安装已清理'
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

    # Claude Code：按安装方式卸载（原生安装不依赖 npm，必须放在 npm 守卫之外）
    $claudeType = Get-ClaudeInstallType
    switch ($claudeType) {
        'none'   { Write-Ok 'Claude Code：未安装，跳过' }
        'native' {
            Write-Warn2 '检测到 Claude Code 为原生安装（非 npm），改用文件清理方式'
            Uninstall-ClaudeNative
        }
        'npm'    { Uninstall-NpmGlobal '@anthropic-ai/claude-code' }
    }

    # Codex 仅通过 npm 安装；无 npm 则跳过
    if (Test-Command npm) {
        Uninstall-NpmGlobal '@openai/codex'
    } else {
        Write-Warn2 '未检测到 npm，跳过 Codex 卸载'
    }

    Uninstall-CcSwitch
    Restore-Npmrc

    Write-Section '卸载完成 ✅'
    @"

已清理：
  • Claude Code（npm 包，或 原生安装 ~/.local/bin + ~/.claude/local）
  • @openai/codex
  • cc-switch 桌面版
  • npm registry 配置（已还原/移除）

保留：Node.js（可能被其他项目使用）
如需连 Node 一起删：控制面板 → 程序和功能 → Node.js → 卸载

卸载日志：$script:LOG_FILE
"@ | Write-Host
}

# ----------------------------- 组件操作 ------------------------------------
# 安装单个组件（comp: all/claude/codex/ccswitch）
# Node/npm 仅在需要时准备一次；all 模式复用，避免重复检测
function Install-Component([string]$comp) {
    if ($comp -eq 'all') {
        Install-Component 'claude'
        Install-Component 'codex'
        Install-Component 'ccswitch'
        return
    }
    switch ($comp) {
        'claude'   { Ensure-Node; Configure-Npm; Install-NpmGlobal '@anthropic-ai/claude-code' }
        'codex'    { Ensure-Node; Configure-Npm; Install-NpmGlobal '@openai/codex' }
        # cc-switch 只下载安装包到「下载」文件夹（走 GitHub 代理链，不依赖 npm）
        'ccswitch' { Download-CcSwitch }
        default { Die "未知组件：$comp（应为 all/claude/codex/ccswitch）" }
    }
}

# 卸载单个组件
function Uninstall-Component([string]$comp) {
    if ($comp -eq 'all') {
        Uninstall-Component 'claude'
        Uninstall-Component 'codex'
        Uninstall-Component 'ccswitch'
        return
    }
    switch ($comp) {
        'claude' {
            # 按 install-type 分发（原生安装不依赖 npm）
            $t = Get-ClaudeInstallType
            switch ($t) {
                'none'   { Write-Ok 'Claude Code：未安装，跳过' }
                'native' {
                    Write-Warn2 '检测到 Claude Code 为原生安装（非 npm），改用文件清理方式'
                    Uninstall-ClaudeNative
                }
                'npm'    { Uninstall-NpmGlobal '@anthropic-ai/claude-code' }
            }
        }
        'codex' {
            if (Test-Command npm) { Uninstall-NpmGlobal '@openai/codex' }
            else { Write-Warn2 '未检测到 npm，跳过 Codex 卸载' }
        }
        'ccswitch' { Uninstall-CcSwitch }
        default { Die "未知组件：$comp" }
    }
}

# 更新单个组件（全部走国内镜像，不依赖外网）
# 设计原则：原生安装的更新通道（downloads.claude.ai / claude update）走外网，
# 国内通常连不上，所以对国内用户：npm 是唯一能稳定走镜像更新的方式。
function Update-Component([string]$comp) {
    if ($comp -eq 'all') {
        Update-Component 'claude'
        Update-Component 'codex'
        Update-Component 'ccswitch'
        return
    }
    switch ($comp) {
        'claude' {
            $t = Get-ClaudeInstallType
            if ($t -eq 'none') { Write-Warn2 'Claude Code 未安装，无法更新（请先安装）'; return }
            if ($t -eq 'native') {
                # 原生安装的更新走外网（downloads.claude.ai），国内基本连不上。
                # 提供出路：迁移到 npm 版，之后更新即可走国内镜像。
                Write-Warn2 '检测到 Claude Code 为原生安装。'
                Write-Warn2 '原生安装的更新走外网（downloads.claude.ai），国内通常无法访问。'
                Write-Host  '  → 建议迁移到 npm 版：之后更新即可走国内镜像（npmmirror）。' -ForegroundColor DarkGray
                if (Confirm-Action '是否迁移到 npm 版（卸载原生 + npm 安装）？') {
                    Write-Section '迁移 Claude Code：原生 → npm'
                    Uninstall-ClaudeNative
                    Ensure-Node; Configure-Npm
                    Install-NpmGlobal '@anthropic-ai/claude-code@latest'
                    Write-Ok '已迁移到 npm 版，后续更新可走国内镜像'
                } else {
                    Write-Warn2 '已跳过。如需更新，可手动挂代理后执行 claude update，或重新运行本命令选择迁移。'
                }
            } else {
                # npm 安装：重装 @latest（走 npmmirror）
                Write-Section '更新 Claude Code（npm：重装 @latest，走国内镜像）'
                Ensure-Node; Configure-Npm
                Install-NpmGlobal '@anthropic-ai/claude-code@latest'
            }
        }
        'codex' {
            if (-not (Test-Command codex)) { Write-Warn2 'Codex CLI 未安装，无法更新（请先安装）'; return }
            # codex update 同样走外网，国内用户直接走 npm 重装最稳
            Write-Section '更新 Codex CLI（npm 重装 @latest，走国内镜像）'
            Ensure-Node; Configure-Npm
            Install-NpmGlobal '@openai/codex@latest'
        }
        'ccswitch' {
            # cc-switch 由用户手动安装，无 CLI updater：更新 = 重下最新安装包到「下载」文件夹，
            # 用户自行双击覆盖安装即可。
            Write-Section '下载 cc-switch 最新安装包（覆盖安装请手动双击）'
            Download-CcSwitch
        }
        default { Die "未知组件：$comp" }
    }
}
# ----------------------------- 版本检查 ------------------------------------
# 取 npm 包最新版本（走已配置的 npmmirror）
function Get-NpmLatestVersion([string]$pkg) {
    try {
        $v = (& npm view $pkg version 2>$null)
        if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() }
    } catch { }
    return $null
}

# 取本机 claude 版本字符串
function Get-ClaudeLocalVersion {
    if (-not (Test-Command claude)) { return $null }
    return (claude --version 2>&1 | Select-Object -First 1)
}
function Get-CodexLocalVersion {
    if (-not (Test-Command codex)) { return $null }
    return (codex --version 2>&1 | Select-Object -First 1)
}

# 综合检查：本地状态 + 本地版本 + 远程最新 + 是否有更新
function Invoke-VersionCheck {
    Detect-Env
    Write-Section '组件状态与版本'

    # Claude Code
    $cv = Get-ClaudeLocalVersion
    if ($cv) {
        $ct = Get-ClaudeInstallType
        $clabel = switch ($ct) { 'native' { ' [原生安装]' } 'npm' { ' [npm]' } default { '' } }
        Write-Ok "Claude Code：$cv$clabel"
    } else { Write-Warn2 'Claude Code：未安装' }
    $clatest = Get-NpmLatestVersion '@anthropic-ai/claude-code'
    Write-Host  "    最新版本：$(if($clatest){$clatest}else{'查询失败'})" -ForegroundColor DarkGray

    # Codex CLI
    $dv = Get-CodexLocalVersion
    if ($dv) { Write-Ok "Codex CLI：$dv" } else { Write-Warn2 'Codex CLI：未安装' }
    $dlatest = Get-NpmLatestVersion '@openai/codex'
    Write-Host  "    最新版本：$(if($dlatest){$dlatest}else{'查询失败'})" -ForegroundColor DarkGray

    # cc-switch（桌面版无命令行版本输出，仅报告是否已装 + 最新 release tag）
    if (Test-CcSwitchInstalled) { Write-Ok 'cc-switch 桌面版：已安装' }
    else { Write-Warn2 'cc-switch 桌面版：未安装' }
    $slatest = Get-CcSwitchLatestTag
    Write-Host  "    最新版本：$(if($slatest){$slatest}else{'查询失败'})" -ForegroundColor DarkGray

    Write-Section '检查完成（未做任何改动，更新请用「更新」菜单/动作）'
}

# ----------------------------- 交互菜单 ------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host "━━ 请选择操作 ━━" -ForegroundColor White
    Write-Host "  1) 安装"   -ForegroundColor Green
    Write-Host "  2) 卸载"   -ForegroundColor Red
    Write-Host "  3) 检查（状态 + 版本，含远程最新版）" -ForegroundColor DarkGray
    Write-Host "  4) 更新"   -ForegroundColor Cyan
    Write-Host "  q) 退出
" -ForegroundColor DarkGray
}

# 二级菜单：选组件。返回 all/claude/codex/ccswitch/back
function Show-ComponentMenu([string]$action) {
    $cn = @{ install = '安装'; uninstall = '卸载'; update = '更新' }
    $verb = $cn[$action]
    Write-Host ""
    Write-Host "━━ 选择要$verb的组件 ━━" -ForegroundColor White
    Write-Host "  1) 全部（Claude Code + Codex + cc-switch）" -ForegroundColor White
    Write-Host "  2) Claude Code"   -ForegroundColor Green
    Write-Host "  3) Codex CLI"     -ForegroundColor Green
    Write-Host "  4) cc-switch"     -ForegroundColor Green
    Write-Host "  b) 返回上级
"    -ForegroundColor DarkGray
    while ($true) {
        $c = Read-Host '请输入选项 [1-4/b]'
        switch -Regex ($c) {
            '^(1|a|all)$'      { return 'all' }
            '^(2|claude)$'     { return 'claude' }
            '^(3|codex)$'      { return 'codex' }
            '^(4|cc|ccswitch)$' { return 'ccswitch' }
            '^(b|back|返回)$'  { return 'back' }
            default { Write-Warn2 '无效输入，请重选' }
        }
    }
}

# 解析动作 + 组件（来自 param 或交互）。返回哈希：@{ Action=...; Component=... }
# Action: install/uninstall/check/update/exit
function Resolve-Action {
    param([string]$ActionArg, [string]$ComponentArg)
    # 1) 命令行直接给定了 Action
    switch -Regex ($ActionArg) {
        '^(install|uninstall|update)$' {
            $comp = if ($ComponentArg) { $ComponentArg } else { 'all' }
            return @{ Action = $ActionArg; Component = $comp }
        }
        '^check$' { return @{ Action = 'check'; Component = 'all' } }
        '^$' { }   # 落到交互
        '.'  {
            Write-Err2 "未知动作：$ActionArg"
            Write-Err2 '用法：.\install.ps1 [-Action install|uninstall|check|update] [-Component all|claude|codex|ccswitch]'
            exit 2
        }
    }
    if ($NonInteractive) { return @{ Action = 'install'; Component = 'all' } }

    # 2) 交互主菜单
    while ($true) {
        Show-Menu
        $choice = Read-Host '请输入选项 [1-4/q]'
        switch -Regex ($choice) {
            '^(1|i|install)$'    { $act = 'install';   break }
            '^(2|u|uninstall)$'  { $act = 'uninstall'; break }
            '^(3|c|check)$'      { return @{ Action = 'check'; Component = 'all' } }
            '^(4|update)$'       { $act = 'update';    break }
            '^(q|quit|exit)$'    { return @{ Action = 'exit'; Component = 'all' } }
            default { Write-Warn2 '无效输入，请重选'; continue }
        }
        # 二级菜单选组件
        $comp = Show-ComponentMenu $act
        if ($comp -eq 'back') { continue }
        return @{ Action = $act; Component = $comp }
    }
}

# ----------------------------- 主流程 --------------------------------------
function Main {
    # 准备日志
    New-Item -ItemType Directory -Force -Path $script:LOG_DIR | Out-Null
    Set-Content -Path $script:LOG_FILE -Value "[install.ps1 v$($script:VERSION)] $(Get-Date)"

    Write-Host "Claude Code + Codex + cc-switch 管理工具（国内镜像）v$($script:VERSION)" -ForegroundColor White
    Write-Host "全程使用国内镜像，无需梯子" -ForegroundColor DarkGray

    $resolved = Resolve-Action -ActionArg $Action -ComponentArg $Component
    $action = $resolved.Action
    $comp   = $resolved.Component

    switch ($action) {
        'exit' { Write-Ok '已退出'; exit 0 }
        'check' { Invoke-VersionCheck; exit 0 }
        'uninstall' {
            Detect-Env
            Uninstall-Component $comp
            Write-Section '完成 🎉'
            Write-Ok "卸载流程结束。日志：$script:LOG_FILE"
            return
        }
        'update' {
            Detect-Env
            Update-Component $comp
            Write-Section '完成 🎉'
            Write-Ok "更新流程结束。日志：$script:LOG_FILE"
            return
        }
    }

    # install
    Detect-Env
    Install-Component $comp
    if ($comp -eq 'all') {
        if (-not (Invoke-Verify)) { Write-Warn2 '部分组件校验未通过，请查看上方提示' }
        Print-NextSteps
    }
    Write-Section '完成 🎉'
    Write-Ok "安装流程结束。如有问题，附上日志反馈：$script:LOG_FILE"
}

Main