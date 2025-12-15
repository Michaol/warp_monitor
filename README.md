# WARP 状态监控与自动修复脚本

[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2Fwarp_monitor&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

这是一个为 Linux 服务器全自动监控由 [fscarmen/warp-sh](https://github.com/fscarmen/warp-sh) 脚本安装的 Cloudflare WARP 连接。它不仅能报告详细的连接状态，还能在检测到连接丢失或配置不符时，自动尝试修复。

## ✨ 主要功能

- **全自动状态检测**：定期检查 WARP 连接的真实状态，包括 IPv4 和 IPv6 的可用性。
- **智能模式识别**：自动识别当前 WARP 的工作模式（网络接口、官方客户端、WireProxy），无需任何手动配置。
- **配置符合性分析**：读取预期配置（单/双栈），并与实际网络状态进行对比，确保连接符合预期。
- **循环自动修复**：当检测到连接完全丢失，或双栈配置降级为单栈时，会自动触发重连程序，最多尝试 10 次以恢复连接。
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

# 4. (可选) 删除日志文件
rm -f /var/log/warp_monitor.log*
```
