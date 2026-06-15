# Claude Code + Codex + cc-switch 安装管理工具（国内镜像）

> 全程使用国内镜像，**无需梯子**。运行时通过 [cc-switch](https://github.com/farion1231/cc-switch) 接入国内 LLM（智谱 GLM / DeepSeek / 通义 / Kimi）的官方 API，合规无风险。支持**安装 / 卸载 / 检查**三种模式。

## 📦 这套脚本帮你做什么

同一个脚本，启动时可选 **安装 / 卸载 / 仅检查**，安装模式会完成下面 5 件事：

| 步骤 | 工具 | 说明 |
|------|------|------|
| 1 | **Node.js 22 LTS** | Claude Code / Codex 的运行时（缺了或版本低才装） |
| 2 | **npm 镜像** | 配置 `registry.npmmirror.com` 加速 |
| 3 | **Claude Code** | `@anthropic-ai/claude-code` |
| 4 | **Codex CLI** | `@openai/codex` |
| 5 | **cc-switch** | 切换不同模型供应商（macOS/Linux桌面装 GUI 版，**Linux 服务器装 CLI 版 `ccs`**） |

---

## 🚀 快速开始

### macOS / Linux

**方式一：一行命令（直接从 GitHub 拉取）**

```bash
curl -fsSL https://raw.githubusercontent.com/Makima04/cc-install/main/install.sh | bash
```

**方式二：国内镜像加速（推荐，GitHub 在国内不稳定时用）**

国内访问 `raw.githubusercontent.com` 经常超时或龟速，可用下面任一镜像源：

```bash
# jsDelivr CDN（国内通用，稳定，永久缓存）
curl -fsSL https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.sh | bash

# GitHub 代理（实测最快，社区维护，偶尔不稳）
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Makima04/cc-install/main/install.sh | bash
```

> ⚠️ **`curl | bash` 无法交互**：管道方式下脚本的 stdin 被 curl 占用，菜单选择会立即"退出"。
> 如需使用交互菜单（选择安装/卸载/检查），请用下面的**方式三**先下载到本地再运行。

**方式三：先下载再运行（支持交互菜单，最稳）**

```bash
# 国内镜像下载（jsDelivr，推荐）
curl -fsSL https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.sh -o install.sh
bash install.sh

# 或 GitHub 直连（国外/有代理）
curl -fsSL https://raw.githubusercontent.com/Makima04/cc-install/main/install.sh -o install.sh
bash install.sh
```

或 clone 后本地运行：

```bash
git clone https://github.com/Makima04/cc-install.git
cd cc-install
bash install.sh
```

> 上面的命令直接用即可（这是官方仓库地址）。如果你 fork 了这个项目，记得把地址换成你自己的。

### Windows（PowerShell）

**方式一：一行命令（从 GitHub 拉取）**

```powershell
& ([scriptblock]::Create([System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest https://raw.githubusercontent.com/Makima04/cc-install/main/install.ps1 -UseBasicParsing).RawContentStream.ToArray()).TrimStart([char]0xFEFF)))
```

> 注：不直接用 `irm` 是因为 PowerShell 5.1 下 `irm` 解码 UTF-8 BOM 有 bug（BOM 三字节未被合并为单字符，导致 `TrimStart` 失效、脚本解析报错）。上面的写法取原始字节后显式按 UTF-8 解码，兼容 PS 5.1 与 PS 7。

**方式二：国内镜像加速（GitHub 不稳定时用）**

```powershell
# jsDelivr CDN（国内通用，稳定）
& ([scriptblock]::Create([System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.ps1 -UseBasicParsing).RawContentStream.ToArray()).TrimStart([char]0xFEFF)))
```

**方式三：先下载再运行（支持交互菜单，最稳）**

```powershell
irm https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> 若提示执行策略受限，加 `-ExecutionPolicy Bypass` 即可。

---

## 🎛 三种模式（安装 / 卸载 / 检查）

直接运行脚本会弹出交互菜单：

```
━━ 请选择操作 ━━
  1) 安装 Claude Code + Codex + cc-switch
  2) 卸载（还原可用的初始状态）
  3) 仅检查环境（不做任何改动）
  q) 退出
```

也可以用命令行参数跳过菜单（适合脚本/CI 自动化）：

| 平台 | 安装 | 卸载 | 仅检查 |
|------|------|------|--------|
| macOS/Linux | `bash install.sh install` | `bash install.sh uninstall` | `bash install.sh check` |
| Windows | `.\install.ps1 install` | `.\install.ps1 uninstall` | `.\install.ps1 check` |

> 不传参数则进入交互菜单。

### 卸载会做什么 / 不做什么

| 会清理 | 保留（可能被其他项目使用） |
|--------|--------------------------|
| `@anthropic-ai/claude-code` | Node.js / nvm |
| `@openai/codex` | npm 本体 |
| cc-switch（桌面版 App/MSI/portable，或 CLI 版 `ccs`） | 你的项目代码 |
| npm registry 配置（从 `.npmrc.bak` 还原） | cc-switch 里保存的供应商配置 |

卸载后 macOS/Linux 会询问是否连 nvm 管理的 Node 一起删；Windows 卸 Node 请走「控制面板 → 程序和功能」。

---

## 🖥 cc-switch：桌面版 vs CLI 版（重要）

脚本会根据**平台和有无图形环境**自动选择合适的 cc-switch 版本：

| 场景 | 装哪个 | 包/方式 | 启动命令 |
|------|--------|---------|---------|
| macOS | 桌面版 GUI | `brew --cask` 或 dmg | 启动台搜 "CC Switch" |
| Linux 桌面（有 `$DISPLAY`） | 桌面版 GUI | AppImage | `~/.local/bin/cc-switch.AppImage` |
| **Linux 服务器（无 `$DISPLAY`）** | **CLI 版** | `npm i -g @songhe/cc-switch` | **`ccs`** |
| Windows | 桌面版 GUI | MSI / portable | 开始菜单搜 "CC Switch" |

> 💡 **Linux 服务器（SSH 环境）没有 GUI**，桌面版 Tauri 应用无法运行，所以脚本自动改装 **CLI 版**（命令 `ccs`），用它能在终端里查看/切换供应商。判断依据是 `$DISPLAY` 和 `$WAYLAND_DISPLAY` 是否为空。

---

## ⚙️ 运行流程

**安装模式**按顺序执行（每一步都**幂等**，重复运行只会补齐缺失项）：

```
检测环境 → 装/升级 Node.js → 配 npm 镜像 → 装 Claude Code
   → 装 Codex → 装 cc-switch → 校验 → 打印下一步
```

- 安装过程**有交互确认**（每步装之前问你），不会偷偷改系统
- 想全自动：mac/linux 设 `NONINTERACTIVE=1`，windows 加 `-NonInteractive`
- 详细日志写到 `~/.cc-installer/install.log`（Windows 同名，位于 `%USERPROFILE%`）

---

## 🔧 可用环境变量

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `GH_PROXY` | 自动回退链 | 自定义 GitHub 代理前缀，如 `https://ghfast.top/` |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像 |
| `NODE_MIRROR` | `https://registry.npmmirror.com/-/binary/node` | Node 二进制镜像 |
| `NONINTERACTIVE` | 未设 | 设为 `1` 跳过所有交互确认（mac/linux） |

**示例**：用自定义代理装

```bash
GH_PROXY=https://ghfast.top/ bash install.sh
```

---

## 🔌 接入国内 LLM（安装完成后）

### 关键概念：必须用 Anthropic 兼容端点

Claude Code 原本只认 Anthropic 协议，所以国产模型厂商都提供了 **`/anthropic` 兼容端点**。在 cc-switch 里填的 **Base URL 一定要带 `/anthropic`**（DeepSeek 等是直接拼在域名后，智谱/Kimi 可能在 cc-switch 里有预设，不用手填）。

### 各厂商配置参考

| 供应商 | 获取 API Key | Base URL（填入 cc-switch） | 推荐模型 ID |
|--------|-------------|----------------------------|------------|
| **智谱 GLM** | https://open.bigmodel.cn/ | cc-switch 里有预设，选「智谱GLM」填 Key 即可 | `glm-4.6` |
| **DeepSeek** | https://platform.deepseek.com/ | `https://api.deepseek.com/anthropic` | `deepseek-chat` |
| **阿里通义/百炼** | https://bailian.console.aliyun.com/ | 百炼 Anthropic 兼容端点（控制台获取） | `qwen-max` / `qwen-plus` |
| **月之暗面 Kimi** | https://platform.moonshot.cn/ | Moonshot Anthropic 兼容端点 | `kimi-k2` |

> ⚠️ Base URL 具体形式以各厂商**当前文档**为准，上表供参考。智谱在 cc-switch 里有官方预设，最省事。

### 在 cc-switch 里怎么填

1. 打开 cc-switch
2. 点「添加供应商」
3. 填三样：
   - **名称**：自定义（如 `GLM`、`DeepSeek`）
   - **API Base URL**：上表对应的地址
   - **API Key**：对应厂商控制台拿到的 Key
4. 保存，切换到该供应商
5. 终端跑 `claude` 或 `codex`，即走你选的国产模型

---

## 🌐 国内镜像说明（脚本用到的）

| 资源 | 镜像源 | 备注 |
|------|--------|------|
| **下载本脚本** | `cdn.jsdelivr.net/gh/Makima04/cc-install@main`（jsDelivr） | 国内访问 GitHub 不稳定时用，见上方「快速开始」 |
| npm 包 | `registry.npmmirror.com`（淘宝） | 免费、稳定 |
| Node 二进制（Win） | `registry.npmmirror.com/-/binary/node` | 同上 |
| nvm 安装脚本（Mac/Linux） | Gitee nvm 镜像 | 避开被墙的 `raw.githubusercontent.com` |
| Homebrew（Mac 可选） | 清华/中科大（brew 自带） | 装 cc-switch 桌面版时用 |
| GitHub Releases 二进制（cc-switch Win/Linux） | GitHub 代理回退链 | `ghfast.top` → `gh-proxy.com` → `ghproxy.net` → 直连 |

**GitHub 代理说明**：cc-switch 的 Windows/Linux 桌面包来自 GitHub Releases，国内直连慢。脚本内置 3 个社区代理 + 直连回退，逐一尝试。代理不稳定时可用 `GH_PROXY` 环境变量指定你常用的那个。

**下载脚本本身的镜像**：本仓库的 `install.sh` / `install.ps1` 托管在 GitHub，国内直连 `raw.githubusercontent.com` 可能超时或龟速。可用 [jsDelivr](https://www.jsdelivr.com/)（全球 CDN，国内有节点，永久缓存 GitHub 仓库）或 GitHub 代理加速，命令见「快速开始」。jsDelivr 的 URL 格式为 `https://cdn.jsdelivr.net/gh/<用户>/<仓库>@<分支>/<文件>`。

---

## ❓ 常见问题

### Q0：用 `curl | bash` 跑起来后菜单"还没选就退出"了？

这是 `curl ... | bash` 的固有限制：管道方式下脚本的 stdin 被 curl 的输出占用，菜单里的交互读取（`read`）拿不到键盘输入，会立即走到"退出"分支。

**解决**：改用「先下载再运行」，让 stdin 留给键盘交互：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.sh -o install.sh
bash install.sh
```

或者跳过菜单直接指定动作（`curl | bash` 下这种用法没问题）：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/Makima04/cc-install@main/install.sh | NONINTERACTIVE=1 bash -s install
```

### Q1：装完 `claude`/`codex` 命令找不到？

**新装的命令行工具需要重开终端窗口**（让新的 PATH 生效）。macOS/Linux 重开 Terminal；Windows 重开 PowerShell。

### Q2：`codex` 提示 Node 版本不对？

Codex 要求 Node ≥ 22。脚本已统一装 Node 22 LTS。如果你之前用 nvm 装了多个版本，确保默认版本是 22：
```bash
nvm alias default 22
nvm use 22
```
> 已知坑：Codex 有时优先用系统 Node 而非 nvm 的 Node（[openai/codex#5192](https://github.com/openai/codex/issues/5192)）。全新安装可规避；如共存请卸掉系统 Node。

### Q3：cc-switch 桌面包下载失败 / 卡住？

GitHub Releases 在国内不稳定。请用代理变量重试：
```bash
GH_PROXY=https://ghfast.top/ bash install.sh
```
或到 https://github.com/farion1231/cc-switch/releases 手动下载对应平台的安装包。

### Q4：macOS 上 cc-switch 提示「无法验证开发者」？

v3.12.3 起已签名公证，正常不会有此提示。若版本较旧：系统设置 → 隐私与安全性 → 仍要打开。

### Q5：Windows 上 MSI 静默安装报错？

- 确认有管理员权限（会弹 UAC）
- 看日志 `%USERPROFILE%\.cc-installer\install.log`
- 或到 https://github.com/farion1231/cc-switch/releases 下 `.zip` 便携版手动解压

### Q6：脚本改了我的 `.npmrc` 怎么办？

脚本会先备份成 `.npmrc.bak`，要还原：
```bash
cp ~/.npmrc.bak ~/.npmrc     # mac/linux
copy %USERPROFILE%\.npmrc.bak %USERPROFILE%\.npmrc   # windows
```

### Q7：如何卸载？

直接用脚本内置的卸载模式（推荐）：

```bash
# mac/linux
bash install.sh uninstall
# 或运行后选 2

# windows
.\install.ps1 uninstall
# 或运行后选 2
```

卸载会清理：两个 npm 全局包 + cc-switch 桌面版 + npm registry 配置。**保留** Node.js（默认）。如需连 Node 一起删，mac/linux 卸载末尾会询问；Windows 走「控制面板 → 程序和功能 → Node.js」。

手动卸载（不推荐，作为备用）：
```bash
# mac/linux
npm uninstall -g @anthropic-ai/claude-code @openai/codex
# cc-switch 桌面版：拖到废纸篓 / 删 AppImage

# windows
npm uninstall -g @anthropic-ai/claude-code @openai/codex
# cc-switch：控制面板 → 卸载程序
```

---

## 📋 前置要求

| 平台 | 要求 |
|------|------|
| macOS | 11+ ，Intel 或 Apple Silicon |
| Linux | 主流发行版（Ubuntu/Debian/CentOS/Arch 等），`curl` + `bash` |
| Windows | Win 10/11，PowerShell 5.1+（或 PowerShell 7） |

需要联网（能访问国内镜像即可）。

---

## 📁 项目结构

```
.
├── install.sh       # macOS / Linux 一键脚本
├── install.ps1      # Windows PowerShell 脚本
├── README.md        # 本文档
└── test/
    └── smoke.sh     # 基础自检（语法 + 镜像连通性）
```

---

## ⚠️ 免责声明

- 本脚本仅做**软件安装加速**（npm 镜像 + GitHub 代理），不涉及任何网络代理/翻墙
- 运行时调用的 API 由用户**自行选择**的国内 LLM 厂商提供，请遵守各厂商服务条款
- 脚本不收集任何信息，日志仅写在本地

## 📚 参考链接

- [cc-switch GitHub](https://github.com/farion1231/cc-switch) / [官方文档](https://ccswitch.io/zh/docs)
- [Claude Code](https://github.com/anthropics/claude-code) / [Codex CLI](https://github.com/openai/codex)
- npm 镜像：[npmmirror.com](https://npmmirror.com/)
- nvm Gitee 镜像
