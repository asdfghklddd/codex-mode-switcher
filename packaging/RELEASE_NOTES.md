## 下载与使用

### macOS

下载 `codex-mode-switcher-*-macos.zip`，解压后双击 `Codex Mode Switcher.app`。首次启动若被 Gatekeeper 阻止，请右键应用并选择“打开”。

需要 PowerShell 7 和 Python 3：

```bash
brew install --cask powershell
brew install python
```

默认使用 `~/.codex`。自定义目录可通过 `CODEX_HOME`，或者把绝对路径写入 `~/.config/codex-mode-switcher/codex-home`。

### Windows

下载 `codex-mode-switcher-*-windows.zip`，完整解压后双击 `Switch-CodexMode.bat`。

## 安全说明

切换前请关闭所有 Codex 应用。工具只操作选定 `CODEX_HOME` 中的 provider 配置与会话 provider 元数据，并维护一个全量基线和有限数量的轻量回滚日志。
