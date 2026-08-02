# WARP 状态监控与自动修复脚本

[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2Fwarp_monitor&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

这是一个为 Linux 服务器全自动监控由 [fscarmen/warp-sh](https://github.com/fscarmen/warp-sh) 脚本安装的 Cloudflare WARP 连接。它不仅能报告详细的连接状态，还能在检测到连接丢失或配置不符时，自动尝试修复。

## 📝 更新日志

### v1.4.0 (2026-08-02)

**新增 warp-go 兼容支持**

- **warp-go 模式识别**：检测 `/opt/warp-go/warp-go` 二进制 + `pgrep warp-go` + `ip link show WARP`，识别 Go 用户态实现
- **接口大小写**：warp-go 接口名为大写 `WARP`（非小写 `warp`），curl 检测改用 `--interface WARP`
- **配置路径**：warp-go 配置在 `/opt/warp-go/warp.conf`（非 `/etc/wireguard/warp.conf`）
- **重连命令**：warp-go 用 `/usr/bin/warp-go o`（非 `warp n/o`）
- **非全局判定**：warp-go 用 `#AllowedIPs` 注释标记（非 `Table = off`），`read_expected_stack` 兼容注释格式
- **第二信源**：warp-go 无内核 wg 握手，改用进程存活 + 接口存在作第二信源，防止 API 不可用时误判
- **接口消失可重建**：warp-go 接口掉线但配置存在时，仍触发 `warp-go o` 重连
- 不影响已工作的 wg-quick 路径（32/32 测试用例全过）

### v1.3.0 (2026-08-01)

**全面修复检测可靠性 + 兼容上游 v3.1.8+**

- **修复引号 Bug**：`curl "$extra_curl_opts"` 把 `--interface warp` 当单参数导致所有模式检测失败，重构为显式模式参数传递（wg/socks5/global）
- **修复接口消失不重连**：重连命令赋值移出 `wg show warp` 分支，只要 warp.conf 存在即可重连重建
- **修复复检误判**：检测 API 不可用时以 wg 握手新鲜度（90s）为第二信源，避免"重连成功但复检仍 N/A"
- **修复 crontab SIGPIPE**：管道写 crontab 在 `set -euo pipefail` 下可能被 SIGPIPE 杀死，改用临时文件
- **兼容性加固**：`AllowedIPs` 解析放宽支持同行格式；兼容上游 v3.1.8~v3.2.6 全部模板变体
- **检测增强**：增加 IPv4/IPv6 ping 预检（与上游端点一致）；API 改用 HTTPS+`-k`+2s 超时
- **重连命令失败不再炸脚本**：`if ! cmd` 模式替代裸执行
- **上游版本标注**：v3.2.6（兼容 v3.1.8+）

<details>
<summary>历史版本</summary>

### v1.2.3 (2026-05-01)

**同步上游 v3.2.4 更新与代码质量优化**

- **同步上游修正**：跟随 fscarmen/warp v3.2.4 验证并同步兼容性
- **性能优化**：将 API 检测超时缩短至 5s，并增加 3s 连接超时，大幅提升异常环境下的响应速度
- **智能模式识别**：新增对官方客户端 (warp-cli) 工作模式（代理/全局）的自动识别
- **增强重连可靠性**：重构硬重连逻辑，使用显式命令替代字符串处理，并优化了 `client` 模式下的重连路径
- **故障诊断增强**：在所有重连尝试失败时，输出当前脚本及上游依赖版本，便于快速定位问题
- **文档更新**：更新历史记录，将旧版本说明移入折叠块，保持文档整洁

### v1.2.2 (2026-03-23)

**代码质量与功能增强**

- **修复变量引用风险**：`curl` 命令中的参数变量添加引号，避免分词导致的异常
- **改进 JSON 解析**：使用 `awk` 替代 `sed` 解析 API 返回的 JSON，与上游代码风格保持一致
- **添加配置文件支持**：支持通过 `/etc/warp_monitor.conf` 自定义参数（日志路径、重试次数等）
- **添加命令行参数**：支持 `-h/--help`、`-v/--version`、`-c/--config` 参数
- **优化错误处理**：改进 `set -u` 模式下的变量未定义处理
- **性能优化**：IPv4/IPv6 检测改为并行执行，提升检测速度

### v1.2.1 (2026-02-23)

跟随上游 fscarmen/warp v3.2.1 更新：

- **IP API 域名切回**：上游将 `ip.cloudflare.now.cc` 切回 `ip.cloudflare.nyc.mn`，同步跟进

### v1.2.0 (2026-02-18)

**诊断逻辑修复与重连策略优化**

- **修复误报 Bug**：未安装 WARP 服务时，最终诊断不再错误地报告"连接正常"，改为提示安装 WARP
- **智能硬重连**：`warp o` 硬重连改为根据 wg 接口状态智能执行——接口存活时先关后开，已断开时直接开启
- **修复未定义变量**：`warp.conf` 不存在时 `warp_conf_content` 不再触发 `set -u` 异常退出
- **修复 `grep -c` 逻辑**：在 `pipefail` 模式下避免无匹配时产生双行输出导致整数比较出错
- **修复硬重连命令生成**：`HARD_RECONNECT_CMD` 现在正确支持所有模式 (n/r/y → o)

### v1.1.1 (2026-02-17)

**紧急修复**：跟随上游 [fscarmen/warp-sh#253](https://github.com/fscarmen/warp-sh/issues/253) 修复

- **IP API 域名迁移**：`ip.cloudflare.nyc.mn` DNS 解析已失效，替换为上游新域名 `ip.cloudflare.now.cc`
- **更新脚本**：请再次执行下面的 `wget` 或 `curl` 完整命令更新到最新版本

### v1.1.0 (2026-02-09)

**重连策略改进**：解决 `warp n` 有时无法有效重新获取 WARP IP 的问题

- **两阶段重连**：阶段1 尝试软重连 (`warp n`) × 2次，失败后阶段2 Fallback 到硬重连 (`warp o`) × 2次
- **新增函数**：`attempt_reconnect()` 支持软重连（仅握手）和硬重连（关闭再开启接口）两种模式
- **详细日志**：每个重连步骤都有清晰的日志输出，便于排查问题

### v1.0.6 (2026-01-05)

跟随上游 fscarmen/warp v3.2.0 更新：

- **IP API 升级**：切换至 fscarmen 自建 API，提升 IP 信息获取速度和稳定性
- **性能优化**：直连模式下减少一次 HTTP 请求，原先需分别请求 trace 和 IP 详情，现一次请求即可获取 WARP 状态、IP、国家和 ISP
- **更新脚本**：若需更新到最新版本，请再次执行下面的 `wget` 或 `curl` 完整命令

</details>

## ✨ 主要功能

- **全自动状态检测**：定期检查 WARP 连接的真实状态，包括 IPv4 和 IPv6 的可用性。
- **智能模式识别**：自动识别当前 WARP 的工作模式（网络接口、官方客户端、WireProxy），无需任何手动配置。
- **配置符合性分析**：读取预期配置（单/双栈），并与实际网络状态进行对比，确保连接符合预期。
- **循环自动修复**：当检测到连接完全丢失，或双栈配置降级为单栈时，会自动触发两阶段重连程序（软重连 + 硬重连 Fallback）以恢复连接。
- **一键式部署**：
  - **自动配置日志轮替**：首次运行时，自动创建 `logrotate` 配置，防止日志文件无限增长。
  - **自动配置定时任务**：首次运行时，自动将自身添加到 `crontab`，实现每小时的周期性监控，脚本执行 20 分钟时限，超时强制终止。
- **广泛的系统兼容性**：支持 Debian, Ubuntu, CentOS, Fedora, Arch 等主流发行版，并为 Alpine Linux 自动处理依赖。
- **详细的状态报告**：输出信息包含系统概况、IP 地理位置、服务状态和配置分析，日志清晰易读。

## ⚙️ 环境要求

- 一台已通过 [fscarmen/warp-sh](https://github.com/fscarmen/warp-sh) 脚本成功安装 WARP 的 Linux 服务器。
- `root` 用户权限（用于配置日志和定时任务，以及执行网络命令）。

## 🚀 使用方法

### 首次安装与执行

你可以通过一行命令直接从 GitHub 下载并执行此脚本。脚本会自动完成所有初始配置。

**方法一：使用 `wget` (推荐)**

```bash
wget -O /root/warp_monitor.sh "https://raw.githubusercontent.com/Michaol/warp_monitor/main/warp_monitor.sh" && chmod +x /root/warp_monitor.sh && sudo /root/warp_monitor.sh
```

**方法二：使用 `curl`**

```bash
curl -sSL -o /root/warp_monitor.sh "https://raw.githubusercontent.com/Michaol/warp_monitor/main/warp_monitor.sh" && chmod +x /root/warp_monitor.sh && sudo /root/warp_monitor.sh
```

### 首次执行后

脚本首次运行后，会自动完成以下工作：

1. 在 `/etc/logrotate.d/` 目录下创建 `warp_monitor` 配置文件。
2. 在 `root` 用户的 `crontab` 中添加一条每小时执行一次的定时任务。

你可以通过以下命令来验证：

- **检查定时任务**: `sudo crontab -l`
- **修改定时任务**: `sudo crontab -e` 修改你需要时执行时间（！！！不要低于默认的 20 分钟执行时限，而且没有必要过于频密检查！！！） `0 * * * * /root/warp_monitor.sh # WARP_MONITOR_CRON`，脚本不会修改你的自定义执行时间。
- **查看日志文件**: `less /var/log/warp_monitor.log` 看完`q`退出。 btw：喜欢怎么看都行，cat/tail/grep……，less 倒不是每个发行版都有默认安装。

之后，脚本将根据定时任务在后台静默运行，守护你的 WARP 连接。

### 命令行参数

脚本支持以下命令行参数：

```bash
# 显示帮助信息
/root/warp_monitor.sh -h

# 显示版本信息
/root/warp_monitor.sh -v

# 使用自定义配置文件
/root/warp_monitor.sh -c /path/to/config.conf
```

### 配置文件

脚本支持通过配置文件自定义参数，默认配置文件路径为 `/etc/warp_monitor.conf`。

**创建配置文件**：

```bash
cat > /etc/warp_monitor.conf << 'EOF'
# WARP Monitor 配置文件
# 取消注释并修改需要自定义的参数

# 日志文件路径
# LOG_FILE="/var/log/warp_monitor.log"

# 最大重试次数
# MAX_RETRIES=2

# 重连等待时间（秒）
# RECONNECT_WAIT_TIME=15

# 硬重连延迟（秒）
# HARD_RECONNECT_DELAY=3
EOF
```

**配置文件参数说明**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `LOG_FILE` | `/var/log/warp_monitor.log` | 日志文件路径 |
| `MAX_RETRIES` | `2` | 每个阶段的最大重试次数 |
| `RECONNECT_WAIT_TIME` | `15` | 重连后等待网络稳定的时间（秒） |
| `HARD_RECONNECT_DELAY` | `3` | 硬重连时关闭接口后的延迟（秒） |

## 📊 输出示例

每次执行时，脚本会生成如下格式的详细报告：

```text
========================================================================
 WARP Status Report & Auto-Heal
------------------------------------------------------------------------
 日志管理配置检查:
   [INFO] Logrotate 配置文件已存在: /etc/logrotate.d/warp_monitor
   - 日志位置: /var/log/warp_monitor.log
   - 循环设定: 保留 30 天的历史日志。
------------------------------------------------------------------------
 定时任务配置检查:
   [INFO] 定时监控任务已存在, 跳过设置。
   - 已有设定: 每小时执行一次 (在第0分钟)
------------------------------------------------------------------------
 系统信息:
   当前操作系统: Ubuntu 24.04.3 LTS
   内核: 6.14.4-061404-generic
   处理器架构: amd64
   虚拟化: kvm
   IPv4: 104.00.000.000 火星 Cloudflare, Inc.
   IPv6: 2a09:000:000:8::abc:de 火星 Cloudflare, Inc.
------------------------------------------------------------------------
 服务状态:
   WARP 网络接口已开启
   工作模式: 非全局
   Client: 未安装
   WireProxy: 未安装
------------------------------------------------------------------------
 配置符合性分析:
   预期配置: 双栈 (Dual-Stack)
   实际状态: 双栈 (Dual-Stack)
   符合状态: 符合预期配置
========================================================================
 最终诊断: 连接正常且符合配置。
```

## 🗑️ 卸载脚本

如需完全移除此监控脚本，请执行以下步骤：

```bash
# 1. 移除定时任务
crontab -l | grep -v "WARP_MONITOR_CRON" | crontab -

# 2. 删除脚本文件
rm -f /root/warp_monitor.sh

# 3. 删除 logrotate 配置
rm -f /etc/logrotate.d/warp_monitor

# 4. (可选) 删除配置文件
rm -f /etc/warp_monitor.conf

# 5. (可选) 删除日志文件
rm -f /var/log/warp_monitor.log*
```
