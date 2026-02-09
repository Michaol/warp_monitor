#!/bin/bash
# warp_cli_installer.sh - WARP 官方 CLI 融合安装脚本
# 版本: 1.0.1
# 功能: 安装官方 WARP CLI + Teams 认证 + 便利功能

VERSION="1.0.1"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 系统检测
# ============================================================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        OS="unknown"
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) ARCH="unsupported" ;;
    esac
}

# ============================================================
# 安装函数
# ============================================================

install_warp_debian() {
    echo -e "${CYAN}[安装]${NC} 添加 Cloudflare 源..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y cloudflare-warp
}

install_warp_rhel() {
    echo -e "${CYAN}[安装]${NC} 添加 Cloudflare 源..."
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | sudo tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    sudo yum install -y cloudflare-warp
}

install_warp() {
    if command -v warp-cli &>/dev/null; then
        echo -e "${GREEN}[✓]${NC} WARP 已安装"
        return 0
    fi

    echo -e "${CYAN}[安装]${NC} 正在安装 WARP..."
    
    case $OS in
        ubuntu|debian)
            install_warp_debian
            ;;
        centos|rhel|fedora|rocky|alma)
            install_warp_rhel
            ;;
        *)
            echo -e "${RED}[错误]${NC} 不支持的系统: $OS"
            echo "官方 CLI 仅支持 Ubuntu/Debian/RHEL/CentOS/Fedora"
            echo "建议使用 fscarmen 脚本: https://gitlab.com/fscarmen/warp"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}[✓]${NC} WARP 安装完成"
}

# ============================================================
# 注册函数
# ============================================================

register_free() {
    echo -e "${CYAN}[注册]${NC} 注册免费账户..."
    warp-cli registration new
    enable_pmtud
    warp-cli connect
    echo -e "${GREEN}[✓]${NC} 注册完成"
}

register_teams() {
    local TEAM=$1
    
    echo -e "${CYAN}[注册]${NC} 发起 Teams 注册..."
    warp-cli registration new "$TEAM" 2>/dev/null
    
    echo ""
    echo -e "${YELLOW}[获取 Token]${NC}"
    echo -e "  1. 浏览器打开: ${GREEN}https://${TEAM}.cloudflareaccess.com/warp${NC}"
    echo -e "  2. 登录后按 ${GREEN}F12${NC} → ${GREEN}Console${NC} → 运行:"
    echo ""
    echo -e "     ${CYAN}copy(document.body.innerHTML.match(/com\\.cloudflare\\.warp:\\/\\/[^\"]*/)[0])${NC}"
    echo ""
    read -p "  3. 粘贴 Token: " TOKEN
    
    if [[ -z "$TOKEN" ]]; then
        echo -e "${RED}[错误]${NC} Token 为空"
        exit 1
    fi
    
    echo -e "${CYAN}[注册]${NC} 完成注册..."
    warp-cli registration token "$TOKEN"
    enable_pmtud
    warp-cli connect
    echo -e "${GREEN}[✓]${NC} Teams 注册完成"
}

# ============================================================
# 状态检查
# ============================================================

check_status() {
    echo ""
    echo -e "${CYAN}[状态]${NC}"
    warp-cli status
    echo ""
    local WARP=$(curl -s https://www.cloudflare.com/cdn-cgi/trace/ | grep "warp=" | cut -d= -f2)
    echo -e "  WARP: ${GREEN}$WARP${NC}"
}

# ============================================================
# 便利功能
# ============================================================

toggle_warp() {
    local STATUS=$(warp-cli status 2>/dev/null | grep -i "status" | head -1)
    if echo "$STATUS" | grep -qi "connected"; then
        warp-cli disconnect
        echo -e "${YELLOW}[✓]${NC} WARP 已断开"
    else
        warp-cli connect
        echo -e "${GREEN}[✓]${NC} WARP 已连接"
    fi
}

optimize_mtu() {
    enable_pmtud
}

enable_pmtud() {
    echo -e "${CYAN}[MTU]${NC} 启用 PMTUD..."
    sudo mkdir -p /var/lib/cloudflare-warp
    
    # 检查是否已有配置
    if [[ -f /var/lib/cloudflare-warp/mdm.xml ]]; then
        # 检查是否已启用
        if grep -q "enable_pmtud" /var/lib/cloudflare-warp/mdm.xml; then
            echo -e "${GREEN}[✓]${NC} PMTUD 已启用"
            return 0
        fi
    fi
    
    # 创建或更新配置
    sudo tee /var/lib/cloudflare-warp/mdm.xml > /dev/null << 'EOF'
<dict>
    <key>warp_tunnel_protocol</key>
    <string>masque</string>
    <key>enable_pmtud</key>
    <true />
</dict>
EOF
    echo -e "${GREEN}[✓]${NC} PMTUD 已启用"
}

upgrade_plus() {
    local KEY=$1
    
    [[ -z "$KEY" ]] && read -p "License Key: " KEY
    
    if [[ -z "$KEY" ]]; then
        echo -e "${RED}[错误]${NC} Key 为空"
        return 1
    fi
    
    echo -e "${CYAN}[WARP+]${NC} 应用 License..."
    warp-cli registration license "$KEY"
    
    local ACCOUNT=$(warp-cli registration show 2>/dev/null | grep -i "account" | head -1)
    if echo "$ACCOUNT" | grep -qi "unlimited\|plus"; then
        echo -e "${GREEN}[✓]${NC} WARP+ 升级成功"
    else
        echo -e "${YELLOW}[!]${NC} 请验证账户类型: $ACCOUNT"
    fi
}

uninstall_warp() {
    echo -e "${YELLOW}[卸载]${NC} 正在卸载 WARP..."
    warp-cli disconnect 2>/dev/null
    warp-cli registration delete 2>/dev/null
    
    case $OS in
        ubuntu|debian)
            sudo apt-get remove -y cloudflare-warp
            sudo rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|fedora|rocky|alma)
            sudo yum remove -y cloudflare-warp
            sudo rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac
    
    echo -e "${GREEN}[✓]${NC} 卸载完成"
}

# ============================================================
# 菜单
# ============================================================

show_menu() {
    echo ""
    echo -e "${CYAN}WARP CLI 安装脚本 v${VERSION}${NC}"
    echo ""
    echo "  1. 安装 WARP (免费账户)"
    echo "  2. 升级 WARP+"
    echo "  3. 安装 WARP (Teams 账户)"
    echo "  4. 查看状态"
    echo "  5. 开关 WARP"
    echo "  6. 卸载 WARP"
    echo "  0. 退出"
    echo ""
}

# ============================================================
# 主函数
# ============================================================

main() {
    detect_os
    detect_arch
    
    # 命令行参数
    case "$1" in
        -f|--free)
            install_warp
            register_free
            check_status
            exit 0
            ;;
        -t|--teams)
            [[ -z "$2" ]] && { echo "用法: $0 -t <team-name>"; exit 1; }
            install_warp
            register_teams "$2"
            check_status
            exit 0
            ;;
        -s|--status)
            check_status
            exit 0
            ;;
        -o|--toggle)
            toggle_warp
            exit 0
            ;;
        -m|--mtu)
            optimize_mtu
            exit 0
            ;;
        -l|--license)
            upgrade_plus "$2"
            exit 0
            ;;
        -u|--uninstall)
            uninstall_warp
            exit 0
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  -f, --free         安装并注册免费账户"
            echo "  -t, --teams <name> 安装并注册 Teams 账户"
            echo "  -l, --license <key> 升级为 WARP+"
            echo "  -s, --status       查看状态"
            echo "  -o, --toggle       开关 WARP"
            echo "  -m, --mtu          MTU 优化"
            echo "  -u, --uninstall    卸载 WARP"
            echo "  -h, --help         显示帮助"
            echo ""
            echo "无参数运行显示菜单"
            exit 0
            ;;
    esac
    
    # 交互菜单
    while true; do
        show_menu
        read -p "请选择: " choice
        
        case $choice in
            1)
                install_warp
                register_free
                check_status
                ;;
            2)
                upgrade_plus
                ;;
            3)
                read -p "Team Name: " TEAM
                install_warp
                register_teams "$TEAM"
                check_status
                ;;
            4)
                check_status
                ;;
            5)
                toggle_warp
                ;;
            6)
                uninstall_warp
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项${NC}"
                ;;
        esac
    done
}

main "$@"
