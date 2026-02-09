# Cloudflare WARP CLI 官方资料

> 收集时间：2026-01-12
> 来源：Cloudflare 官方文档 + pkg.cloudflareclient.com

---

## 1. 官方支持的 Linux 系统

### Debian/Ubuntu 系

| 发行版 | 版本                                                                | 架构          |
| ------ | ------------------------------------------------------------------- | ------------- |
| Ubuntu | 24.04 (Noble), 22.04 (Jammy), 20.04 (Focal), 18.04, 16.04           | x86_64, arm64 |
| Debian | 13 (Trixie), 12 (Bookworm), 11 (Bullseye), 10 (Buster), 9 (Stretch) | x86_64, arm64 |

### RHEL 系

| 发行版      | 版本   | 架构          |
| ----------- | ------ | ------------- |
| CentOS/RHEL | 8      | x86_64, arm64 |
| Fedora      | 34, 35 | x86_64, arm64 |

### 不支持的系统（需使用 wireguard-go）

- Alpine Linux
- Arch Linux / EndeavourOS
- OpenVZ / LXC 容器（部分）

---

## 2. 官方安装命令

### Ubuntu/Debian

```bash
# 添加 Cloudflare GPG 密钥
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# 添加 APT 源
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list

# 安装
sudo apt-get update && sudo apt-get install cloudflare-warp
```

### RHEL/CentOS

```bash
# 添加 YUM 源
curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | sudo tee /etc/yum.repos.d/cloudflare-warp.repo

# 更新并安装
sudo yum update
sudo yum install cloudflare-warp
```

### 重要提示

> **公钥更新**：2025-09-12 之前安装的需要更新公钥，否则 2025-12-04 后仓库将失效。

---

## 3. warp-cli 命令参考

### 注册与认证

| 命令                                      | 说明                 |
| ----------------------------------------- | -------------------- |
| `warp-cli registration new`               | 注册设备（免费账户） |
| `warp-cli registration new <team-name>`   | 注册到 Teams 组织    |
| `warp-cli registration token <TOKEN_URL>` | 使用 Token 注册      |
| `warp-cli registration license <KEY>`     | 应用 WARP+ 许可证    |
| `warp-cli registration show`              | 显示注册状态         |
| `warp-cli delete-device`                  | 删除设备注册         |

### 连接控制

| 命令                  | 说明      |
| --------------------- | --------- |
| `warp-cli connect`    | 连接 WARP |
| `warp-cli disconnect` | 断开连接  |
| `warp-cli reconnect`  | 重新连接  |
| `warp-cli status`     | 查看状态  |

### 模式设置

| 命令                         | 说明            |
| ---------------------------- | --------------- |
| `warp-cli set-mode warp`     | 全部流量走 WARP |
| `warp-cli set-mode warp+doh` | WARP + DoH      |
| `warp-cli set-mode doh`      | 仅 DoH          |
| `warp-cli set-mode proxy`    | 本地代理模式    |
| `warp-cli set-mode off`      | 关闭            |

### 隧道协议

| 命令                                     | 说明                |
| ---------------------------------------- | ------------------- |
| `warp-cli tunnel protocol set WireGuard` | 使用 WireGuard      |
| `warp-cli tunnel protocol set MASQUE`    | 使用 MASQUE（默认） |

### DNS 设置

| 命令                            | 说明                    |
| ------------------------------- | ----------------------- |
| `warp-cli dns families off`     | 关闭家庭过滤            |
| `warp-cli dns families malware` | 恶意软件防护            |
| `warp-cli dns families full`    | 恶意软件 + 成人内容过滤 |

### 分流设置

| 命令                                       | 说明              |
| ------------------------------------------ | ----------------- |
| `warp-cli add-excluded-route <IP/CIDR>`    | 排除 IP 不走 WARP |
| `warp-cli remove-excluded-route <IP/CIDR>` | 移除排除规则      |
| `warp-cli add-included-route <IP/CIDR>`    | 仅指定 IP 走 WARP |
| `warp-cli remove-included-route <IP/CIDR>` | 移除包含规则      |

### 其他

| 命令                 | 说明         |
| -------------------- | ------------ |
| `warp-cli settings`  | 显示详细设置 |
| `warp-cli network`   | 网络接口信息 |
| `warp-cli --version` | 版本信息     |
| `warp-cli --help`    | 帮助         |

---

## 4. 最新版本信息（2025-11）

- **最新稳定版**：2025.9.558.0
- **默认隧道协议**：MASQUE
- **Proxy 模式**：仅支持 MASQUE（不再支持 WireGuard）
- **新功能**：PMTUD（路径 MTU 发现）

---

## 5. MDM 自动化部署（Linux）

创建配置文件 `/var/lib/cloudflare-warp/mdm.xml`：

```xml
<dict>
    <key>organization</key>
    <string>your-team-name</string>
</dict>
```

安装 WARP 后会自动读取此配置加入组织。

---

## 6. 服务管理

```bash
# 查看服务状态
sudo systemctl status warp-svc

# 重启服务
sudo systemctl restart warp-svc

# 查看日志
journalctl -u warp-svc -f
```

---

## 7. 验证连接

```bash
curl https://www.cloudflare.com/cdn-cgi/trace/
# 检查输出中 warp=on 或 warp=plus
```
