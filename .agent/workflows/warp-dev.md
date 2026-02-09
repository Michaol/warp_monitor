---
description: WARP 融合脚本开发工作流程
---

# WARP 融合脚本开发工作流程

// turbo-all

## 项目文件

| 文件                         | 用途                   |
| ---------------------------- | ---------------------- |
| `warp_cli_installer.sh`      | 官方 CLI 融合安装脚本  |
| `warp_monitor.sh`            | 状态监控和自动修复脚本 |
| `docs/warp_cli_reference.md` | 官方 CLI 命令参考      |

## 快速使用

### 安装脚本

```bash
# 免费账户
bash warp_cli_installer.sh -f

# Teams 账户
bash warp_cli_installer.sh -t <team-name>

# 交互菜单
bash warp_cli_installer.sh
```

### 浏览器 Token 提取（Teams 注册用）

```javascript
copy(document.body.innerHTML.match(/com\.cloudflare\.warp:\/\/[^\"]*/)[0]);
```

## MCP 工具

| 工具                     | 用途                                             |
| ------------------------ | ------------------------------------------------ |
| `memory`                 | 查询 `Cloudflare_WARP_CLI`、`fscarmen_warp` 实体 |
| `augment-context-engine` | 代码库语义搜索                                   |
| `context7`               | 第三方库文档                                     |
