# Codex 模式切换器

用于在同一个共享 `CODEX_HOME` 中切换 Codex 顶层 provider 的小型 Windows/macOS 启动器。

双击启动器会打开零依赖的本地 HTML 控制面板。页面只使用 HTML、CSS 与浏览器 JavaScript；PowerShell 桥接只监听 `127.0.0.1`，负责调用既有的安全切换脚本。每次启动都会生成随机令牌，所有本地 API 请求都必须携带该令牌。

## 会修改什么

切换器会修改 `config.toml` 中顶层的 `model_provider`，并同步本地会话索引中的 provider：

- `Normal`：移除受管理的顶层 provider，使用正常的 OpenAI 默认配置。
- `Cockpit`：选择 `codex_local_access`。
- `CCSwitch`：选择 `custom`。
- `Status`：仅读取配置，不扫描或修改会话。

为保证切换后仍能看到同一批历史任务，非 `Status` 模式会同步：

- `state_5.sqlite` 中 `threads.model_provider`
- `sessions/` 与 `archived_sessions/` 中 `session_meta.model_provider`

每次同步前会创建 `backup-*-codex-mode-switch` 备份，其中包含切换前的配置、SQLite 快照和被修改的原始 JSONL。工具不会读取会话正文，不会修改认证、归档状态或全局状态。所有启动器仍须使用同一个 `CODEX_HOME`（通常为 `~/.codex`）。

## 文件说明

- `Switch-CodexMode.bat`：Windows 面板启动器（保留数字参数的命令行兼容）。
- `Switch-CodexMode.ps1`：核心切换逻辑。
- `Start-CodexModeSwitcher.ps1`：仅限回环地址的本地面板桥接。
- `CodexModeSwitcher.html`：无依赖的面板界面。
- `Switch-CodexMode.sh`：macOS/Linux 面板与命令行启动器。
- `Switch-CodexMode.command`：macOS Finder 面板启动器。
- `tests/Invoke-SwitcherSelfTest.ps1`：隔离环境下的 provider 同步与备份测试。

## 使用方法

先关闭所有 Codex 应用，再直接启动不带参数的启动器；它会在默认浏览器中打开本地控制面板。选择 provider 后，重新打开所有 Codex 应用，让它们重新加载 `config.toml`。

```powershell
.\Switch-CodexMode.bat       # 打开本地 HTML 面板
.\Switch-CodexMode.bat 1     # OpenAI 默认
.\Switch-CodexMode.bat 2     # Cockpit
.\Switch-CodexMode.bat 3     # CCSwitch
.\Switch-CodexMode.bat 4     # 仅查看状态
```

### macOS Apple Silicon（M1/M2/M3/M4）

核心脚本使用与架构无关的 PowerShell/.NET 代码。Apple Silicon 请安装原生 arm64 PowerShell 7；启动器检测到疑似 Rosetta 版本时会给出提示，而不会静默依赖它。

```bash
brew install --cask powershell
pwsh -NoProfile -Command '[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture'
# 预期输出：Arm64

chmod +x ./Switch-CodexMode.command
./Switch-CodexMode.command
```

也可以在 Finder 中双击 `Switch-CodexMode.command`。如果 macOS 将下载的副本标记为隔离文件，请确认仓库来源后再移除该文件的隔离属性：

```bash
xattr -d com.apple.quarantine ./Switch-CodexMode.command
```

macOS/Linux 不带参数时会打开 HTML 面板；需要命令行时可使用：

```bash
bash ./Switch-CodexMode.sh ui
bash ./Switch-CodexMode.sh status
bash ./Switch-CodexMode.sh normal
bash ./Switch-CodexMode.sh cockpit
bash ./Switch-CodexMode.sh ccswitch
```

macOS 的共享默认目录为 `~/.codex`。不要为各个 Codex 启动器设置不同的 `CODEX_HOME`，否则会产生彼此独立的本地状态和历史。启动前可用 `echo "$CODEX_HOME"` 检查 shell 值；空值表示使用共享默认目录。

## 自测

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SwitcherSelfTest.ps1
```

此测试会验证所有模式、SQLite/JSONL provider 同步、未知 provider 保留、备份生成，以及 `Status`/`SkipThreadRewrite` 不改会话。测试路径不依赖具体平台；复制仓库到 macOS 后，可运行：

```bash
pwsh -NoProfile -File ./tests/Invoke-SwitcherSelfTest.ps1
```

浏览器面板的隔离集成测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-WebPanelSelfTest.ps1
```
