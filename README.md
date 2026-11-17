# AGY SOCKS Watchdog

一个轻量的 SOCKS5 TCP 中继，为已有代理连接增加双向空闲超时。附带 Windows PowerShell 启动脚本、可选登录自启任务，以及 AGY 会话停滞告警脚本。

```text
Antigravity CLI (agy) → 127.0.0.1:18080 → 本地 SOCKS5 代理（如 sing-box）→ 目标服务
```

这不是 Google 官方项目，也不是新的代理节点或模型 API 网关。中继不解析 HTTPS/SSE 内容、不读取登录凭据、不自动重试 AGY 请求。**断开空闲连接不等于修复卡住，也可能中断模型正常的长时间等待。**

## 前提与限制

- 需要一个可用的、**无需认证的 SOCKS5 上游代理**。不支持用户名/密码认证、HTTP 上游、UDP ASSOCIATE 或 BIND。
- 中继使用 Go 标准库；Windows 包装脚本需要 Windows PowerShell 5.1 或 PowerShell 7。
- 脚本通过 `HTTPS_PROXY` 请求 AGY 使用代理；具体 AGY 版本是否遵守此变量，需要自行验证，不保证所有流量均被代理。
- 默认只监听 `127.0.0.1`。不要将这个无认证中继暴露到公网。
- 中继没有内置重连或进程自恢复；可选计划任务仅在登录时启动，并在进程异常退出后尝试重启。
- 复用监听端口时，包装脚本只检查 TCP 可连接性，不验证端口上的服务身份。请确保端口没有被其他程序占用。

## 构建与测试

需要 Go 1.25.0 或更新版本。在仓库根目录执行：

```powershell
go test ./...
go vet ./...
New-Item -ItemType Directory -Path bin -Force | Out-Null
go build -trimpath -o .\bin\agy-socks-watchdog.exe .
powershell -NoProfile -File .\tests\Test-Scripts.ps1
```

最后一项是 Windows 包装脚本测试，使用假 AGY 程序及独立中继进程，不调用真实 AGY、不访问模型服务、不注册计划任务。也可以使用 `pwsh` 运行。

非 Windows 环境可以构建 Go 中继本身，PowerShell 包装脚本仅面向 Windows：

```sh
go build -trimpath -o bin/agy-socks-watchdog .
```

## 直接运行中继

假设上游 SOCKS5 代理已经在 `127.0.0.1:10808` 监听：

```powershell
.\bin\agy-socks-watchdog.exe -listen 127.0.0.1:18080 -upstream 127.0.0.1:10808 -idle-timeout 5m
```

| 参数 | Go 程序默认值 | 含义 |
| --- | --- | --- |
| `-listen` | `127.0.0.1:18080` | 中继监听地址 |
| `-upstream` | `127.0.0.1:10808` | 无认证 SOCKS5 上游地址 |
| `-idle-timeout` | `25s` | 双向都无数据的超时时长，必须大于零 |
| `-log` | 空 | 追加日志文件；未指定时写入标准错误 |

只要任一方向有数据传输，空闲计时就会刷新；不是固定每隔一段时间断开。对于阻塞写入，截止时间同样会限制等待。命令行指定日志文件时，请先创建其父目录。

**兼容原有使用方式，Windows 包装脚本显式使用 `5m`，而 Go 程序单独运行的默认值保留为 `25s`。** 请根据业务等待时长选择合适值。

## 通过包装脚本启动 AGY

```powershell
# 按需启动中继，然后运行 AGY；支持透传参数
& .\scripts\agy.ps1
& .\scripts\agy.ps1 --print "say OK"

# 跳过中继，直接使用上游 SOCKS5 代理
& .\scripts\agy-direct.ps1
```

包装脚本默认查找 `%LOCALAPPDATA%\agy\bin\agy.exe`。仅在调用 AGY 时临时修改当前 PowerShell 进程的 `HTTPS_PROXY`，结束后恢复原值，并返回 AGY 的退出码；不修改系统代理、上游代理配置或 AGY 设置文件。

**不要假定输入 `agy` 就会运行本仓库的脚本。** PATH 中的 `agy.exe` 可能优先被找到；建议使用上述显式路径。

### 可选环境变量

在运行包装脚本或安装自启前设置：

| 变量 | 默认值 |
| --- | --- |
| `AGY_EXE` | `%LOCALAPPDATA%\agy\bin\agy.exe` |
| `AGY_RELAY_EXE` | 本仓库的 `bin\agy-socks-watchdog.exe` |
| `AGY_RELAY_PORT` | `18080`，脚本固定监听本地回环地址 |
| `AGY_UPSTREAM` | `127.0.0.1:10808` |
| `AGY_IDLE_TIMEOUT` | `5m` |
| `AGY_RELAY_LOG` | `%LOCALAPPDATA%\agy-socks-watchdog\socks-watchdog.log` |

```powershell
$env:AGY_UPSTREAM = '127.0.0.1:7890' # 必须是支持 SOCKS5 的端口
$env:AGY_IDLE_TIMEOUT = '10m'
& .\scripts\agy.ps1
```

已运行的中继不会因修改环境变量而自动更新。需要先停止对应的旧中继，再启动新配置；包装脚本结束后中继仍可保持运行。

## 可选登录自启

包装脚本已支持按需启动，通常无需安装自启。以下操作会注册或覆盖当前用户的 `Agy SOCKS Watchdog` 计划任务：

```powershell
& .\scripts\Install-AgyRelayStartup.ps1

# 卸载计划任务（不会主动结束已经运行的中继）
& .\scripts\Install-AgyRelayStartup.ps1 -Uninstall
```

任务在**登录 Windows 后**启动中继，不会启动 AGY，也不会在注册时立即启动。配置在注册时写入任务；修改配置后需重新注册。安装后不要移动或删除中继 EXE，否则需重新构建并注册任务。

## 可选会话停滞告警

```powershell
& .\scripts\Watch-AgyHang.ps1
& .\scripts\Watch-AgyHang.ps1 -Minutes 5 -Once
```

需要 PATH 中有 `sqlite3.exe`，并且 `%USERPROFILE%\.gemini\antigravity-cli\conversations` 中存在对应版本的会话数据库。默认每 15 秒检查一次：若数据库存在 `status=8` 的步骤，且数据库/WAL 三分钟没有更新，发出告警。

这是基于原有数据库结构的启发式提示，**不代表已确认网络故障**；不同 AGY 版本可能不兼容。脚本只读数据库，不取消任务或结束 AGY。请勿上传会话数据库、凭据和日志。

## 来源与许可

本仓库整理自已有的本地单文件 Go 中继及 PowerShell 脚本，发布整理时保留中继核心逻辑。原始作者及许可证尚未确认，因此暂未指定开源许可证；公开源码不代表已授予任意使用、修改或再分发许可。
