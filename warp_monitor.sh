#!/usr/bin/env bash
set -euo pipefail

VERSION="1.4.1"

# ============ 可配置参数 (配置文件可覆盖) ============
LOG_FILE="/var/log/warp_monitor.log"
LOGROTATE_CONF="/etc/logrotate.d/warp_monitor"
MAX_RETRIES=2
RECONNECT_WAIT_TIME=15
HARD_RECONNECT_DELAY=3
WARP_CONF="/etc/wireguard/warp.conf"              # wg-quick 路径 (fscarmen warp)
WARPGO_CONF="/opt/warp-go/warp.conf"              # warp-go 路径
WARPGO_BIN="/opt/warp-go/warp-go"                 # warp-go 二进制
WARPGO_IFACE="WARP"                               # warp-go 接口名 (大写, 与上游一致)
WARP_API="https://ip.cloudflare.nyc.mn"         # 上游默认 HTTP, 此处用 HTTPS+-k 兼顾安全与兼容
PING_V4="162.159.192.1"                         # Cloudflare engage IPv4
PING_V6="2606:4700:d0::a29f:c001"               # Cloudflare engage IPv6
HANDSHAKE_MAX_AGE=90                            # wg 握手新鲜度阈值 (秒)
SCRIPT_PATH=$(realpath "$0")
LOCK_FILE="/var/run/warp_monitor.lock"

# 确保锁文件目录存在 (避免非标准环境失败)
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || LOCK_FILE="/tmp/warp_monitor.lock"

# 配置文件支持
CONFIG_FILE="${CONFIG_FILE:-/etc/warp_monitor.conf}"

# 命令行参数解析
show_help() {
    echo "WARP 状态监控与自动修复脚本 v${VERSION}"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -c, --config FILE  指定配置文件 (默认: /etc/warp_monitor.conf)"
    echo "  -v, --version      显示版本信息"
    echo "  -h, --help         显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                          # 使用默认配置运行"
    echo "  $0 -c /path/to/config.conf  # 使用自定义配置文件"
    echo ""
    return
}

show_version() {
    echo "WARP Monitor v${VERSION}"
    echo "上游依赖: fscarmen/warp-sh v3.2.6 (兼容 v3.1.8+, 含 warp-go)"
    return
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "未知选项: $1" >&2
            echo "使用 -h 或 --help 查看帮助" >&2
            exit 1
            ;;
    esac
done

# 加载配置文件
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

if [[ "$(id -u)" -ne 0 ]]; then
   echo "错误: 此脚本必须以 root 权限运行才能管理 logrotate 和 crontab。" >&2
   exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "[INFO] flock 命令未找到, 正在尝试安装..." | tee -a "$LOG_FILE"
    INSTALL_CMD=""
    if command -v apt-get >/dev/null; then
        apt-get update >/dev/null
        INSTALL_CMD="apt-get install -y util-linux"
    elif command -v dnf >/dev/null; then
        INSTALL_CMD="dnf install -y util-linux"
    elif command -v yum >/dev/null; then
        INSTALL_CMD="yum install -y util-linux"
    elif command -v pacman >/dev/null; then
        INSTALL_CMD="pacman -S --noconfirm util-linux"
    elif command -v apk >/dev/null; then
        INSTALL_CMD="apk add util-linux"
    fi
    if [[ -n "$INSTALL_CMD" ]]; then
        $INSTALL_CMD >/dev/null 2>&1
        if ! command -v flock >/dev/null 2>&1; then
            echo "[ERROR] 自动安装 util-linux (flock) 失败, 脚本无法保证安全运行, 即将退出。" | tee -a "$LOG_FILE" >&2
            exit 1
        else
            echo "[SUCCESS] 成功安装 util-linux, flock 命令已可用。" | tee -a "$LOG_FILE"
        fi
    else
        echo "[ERROR] 未知的包管理器, 无法自动安装 util-linux。脚本无法保证安全运行, 即将退出。" | tee -a "$LOG_FILE" >&2
        exit 1
    fi
fi

if [[ -f /etc/alpine-release ]]; then
    if ! echo "test" | grep -P "test" > /dev/null 2>&1; then
        echo "[INFO] 检测到 Alpine Linux 且缺少 GNU grep, 正在尝试自动安装..." | tee -a "$LOG_FILE"
        if command -v apk > /dev/null; then
            apk update && apk add grep
            if [[ -z $(echo "test" | grep -P "test" 2>/dev/null) ]]; then
                echo "[ERROR] 自动安装 GNU grep 失败, 脚本无法继续。请手动执行 'apk add grep'。" | tee -a "$LOG_FILE" >&2
                exit 1
            else
                echo "[SUCCESS] 成功安装 GNU grep。" | tee -a "$LOG_FILE"
            fi
        else
            echo "[ERROR] 在 Alpine 系统上未找到 'apk' 命令, 无法安装依赖。" | tee -a "$LOG_FILE" >&2
            exit 1
        fi
    fi
fi

log_and_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# IPv4/IPv6 预检: ping Cloudflare engage 端点 (与上游 check_system_info 一致)
# 返回 0=可达 1=不可达
ping_precheck() {
    local v="$1"
    if [[ "$v" == "4" ]]; then
        ping -4 -c2 -W3 "$PING_V4" >/dev/null 2>&1
    else
        if [[ -x "$(type -p ping6)" ]]; then
            ping6 -c2 -W3 "$PING_V6" >/dev/null 2>&1
        else
            ping -6 -c2 -W3 "$PING_V6" >/dev/null 2>&1
        fi
    fi
}

# wg 握手新鲜度: 最近 HANDSHAKE_MAX_AGE 秒内有握手即视为连接存活
# (检测 API 不可用时的第二信源, 防止误判"连接丢失"触发无效重连)
# 仅适用 wg-quick 路径; warp-go 无内核 wg 接口, 用 warpgo_alive 替代。
wg_handshake_fresh() {
    local handshake now
    handshake=$(wg show warp latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    [[ -n "$handshake" && "$handshake" -ne 0 ]] || return 1
    now=$(date +%s)
    [[ $((now - handshake)) -le $HANDSHAKE_MAX_AGE ]]
}

# warp-go 连接存活判定 (第二信源): 进程在跑 + 接口存在
# warp-go 是用户态 Go 实现, 无内核 wg 握手可读, 故用进程/接口存活作信源。
warpgo_alive() {
    pgrep -x "warp-go" >/dev/null 2>&1 && ip link show "$WARPGO_IFACE" >/dev/null 2>&1
}

# 查询指定栈 (4/6) 的 WARP 状态。
# 参数: $1=4|6  $2=模式 (wg|warpgo|global|socks5)  $3=socks5 端口 (仅 socks5 模式)
# 输出: "IP 国家 ISP" (warp=on/plus) 或 "N/A"
get_warp_ip_details() {
    local ip_version="$1" mode="$2" port="${3:-}"
    local ip_json warp_status warp_ip country asn_org
    local curl_base=()

    if [[ "$mode" == "socks5" ]]; then
        # SOCKS5 代理模式: 先取出口 IP, 再查详情确认是否为 WARP IP
        warp_ip=$(curl -s -A a --retry 2 -m 2 --proxy "socks5h://127.0.0.1:${port}" "https://api-ipv${ip_version}.ip.sb/ip" 2>/dev/null) || true
        if [[ -z "$warp_ip" || "$warp_ip" =~ "error" ]]; then
            echo "N/A"
            return
        fi
        ip_json=$(curl -s --retry 2 -m 2 "${WARP_API}/${warp_ip}?lang=zh-CN" 2>/dev/null) || true
        if echo "$ip_json" | grep -qi '"isp".*Cloudflare' 2>/dev/null; then
            warp_status="on"
        else
            echo "N/A"
            return
        fi
    else
        # 直连 / --interface 模式: wg-quick 用小写 warp, warp-go 用大写 WARP
        if [[ "$mode" == "wg" ]]; then
            curl_base=(-s --retry 2 -k -m 2 --interface warp)
        elif [[ "$mode" == "warpgo" ]]; then
            curl_base=(-s --retry 2 -k -m 2 --interface "$WARPGO_IFACE")
        else
            curl_base=(-s --retry 2 -k -m 2)
        fi
        ip_json=$(curl "${curl_base[@]}" "-${ip_version}" "${WARP_API}?lang=zh-CN" 2>/dev/null) || true
        if [[ -z "$ip_json" ]]; then
            echo "N/A"
            return
        fi
        warp_status=$(awk -F '"' '/"warp"/{print $4}' <<< "$ip_json")
        warp_ip=$(awk -F '"' '/"ip"/{print $4}' <<< "$ip_json")
    fi

    if [[ "$warp_status" == "on" || "$warp_status" == "plus" ]]; then
        country=$(awk -F '"' '/"country"/{print $4}' <<< "$ip_json")
        asn_org=$(awk -F '"' '/"isp"/{print $4}' <<< "$ip_json")
        echo "$warp_ip $country $asn_org"
    else
        echo "N/A"
    fi
}

# 预检 + 查询封装 (供并行调用)
# 参数: $1=4|6  $2=模式  $3=socks5 端口
# 注意: wg/warpgo 非全局模式跳过 ping 预检——该模式 IPv6 无默认路由, 只能经
#       --interface 绑定访问, 预检默认路由反而误判 IPv6 不可达。
check_ip() {
    local v="$1" mode="$2" port="${3:-}"
    if [[ "$mode" != "wg" && "$mode" != "warpgo" ]]; then
        if ! ping_precheck "$v"; then
            echo "N/A"
            return
        fi
    fi
    get_warp_ip_details "$v" "$mode" "$port"
}

setup_log_rotation() {
    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 日志管理配置检查:"
    if [[ -f "$LOGROTATE_CONF" ]]; then
        log_and_echo "   [INFO] Logrotate 配置文件已存在: $LOGROTATE_CONF"
        local rotate_setting
        rotate_setting=$(grep -oP '^\s*rotate\s+\K\d+' "$LOGROTATE_CONF" 2>/dev/null) || rotate_setting="未知"
        log_and_echo "   - 日志位置: $LOG_FILE"
        log_and_echo "   - 循环设定: 保留 ${rotate_setting} 天的历史日志。"
    else
        log_and_echo "   [INFO] Logrotate 配置文件不存在, 正在创建..."
        cat << EOF > "$LOGROTATE_CONF"
/var/log/warp_monitor.log {
    daily
    rotate 30
    size 2M
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
        if [[ $? -eq 0 ]]; then log_and_echo "   [SUCCESS] 成功创建配置文件。"; else log_and_echo "   [ERROR] 创建配置文件失败, 请检查权限。"; fi
    fi
}

setup_cron_job() {
    local cron_comment="# WARP_MONITOR_CRON"
    local cron_job="0 * * * * timeout 20m ${SCRIPT_PATH} ${cron_comment}"

    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 定时任务配置检查:"

    if crontab -l 2>/dev/null | grep -qF "$cron_comment"; then
        log_and_echo "   [INFO] 定时监控任务已存在, 跳过设置。"
        local existing_job=$(crontab -l | grep -F "$cron_comment")
        local schedule=$(echo "$existing_job" | awk '{print $1, $2, $3, $4, $5}')
        local human_readable_schedule=""
        case "$schedule" in
            "0 * * * *") human_readable_schedule="每小时执行一次 (在第0分钟)" ;;
            "*/30 * * * *") human_readable_schedule="每30分钟执行一次" ;;
            *) human_readable_schedule="按自定义计划 '${schedule}' 执行" ;;
        esac
        log_and_echo "   - 已有设定: $human_readable_schedule"
        if ! echo "$existing_job" | grep -q "timeout"; then
            log_and_echo "   [INFO] 检测到现有任务缺少超时设置, 正在更新..."
            # 用临时文件而非管道, 避免 crontab 不读 stdin 时 SIGPIPE 导致脚本中止
            local tmp_cron
            tmp_cron=$(mktemp)
            (crontab -l 2>/dev/null || true; echo "$cron_job") > "$tmp_cron"
            crontab "$tmp_cron"
            local update_rc=$?
            rm -f "$tmp_cron"
            if [[ $update_rc -eq 0 ]]; then
                log_and_echo "   [SUCCESS] 成功为定时任务添加20分钟超时保护。"
            else
                log_and_echo "   [ERROR] 更新定时任务失败。"
            fi
        fi
    else
        log_and_echo "   [INFO] 定时监控任务不存在, 正在添加..."
        local tmp_cron
        tmp_cron=$(mktemp)
        (crontab -l 2>/dev/null || true; echo "$cron_job") > "$tmp_cron"
        crontab "$tmp_cron"
        local add_rc=$?
        rm -f "$tmp_cron"
        if [[ $add_rc -eq 0 ]]; then
            log_and_echo "   [SUCCESS] 成功添加定时任务 (带20分钟超时保护), 脚本将每小时自动运行。"
        else
            log_and_echo "   [ERROR] 添加定时任务失败。"
        fi
    fi
    return
}

# 从 warp.conf 读取预期栈 (与上游兼容: 分行或同行 AllowedIPs 均可)
# wg-quick: AllowedIPs 未注释 (Table=off 标记非全局)
# warp-go:  全局=未注释, 非全局=#AllowedIPs (注释)。两种均视为"配置了该栈"
# 输出: "双栈 (Dual-Stack)" / "仅 IPv4 (IPv4-Only)" / "仅 IPv6 (IPv6-Only)" / "N/A"
read_expected_stack() {
    local conf_content="$1"
    local ipv4_active=0 ipv6_active=0
    # 行首允许 [[:space:]]* 和可选的 # (warp-go 非全局注释)
    if echo "$conf_content" | grep -qE '^[[:space:]]*#?[[:space:]]*AllowedIPs[^#]*0\.0\.0\.0/0' 2>/dev/null; then ipv4_active=1; fi
    if echo "$conf_content" | grep -qE '^[[:space:]]*#?[[:space:]]*AllowedIPs[^#]*::/0' 2>/dev/null; then ipv6_active=1; fi
    if [[ $ipv4_active -eq 1 && $ipv6_active -eq 1 ]]; then
        echo "双栈 (Dual-Stack)"
    elif [[ $ipv4_active -eq 1 ]]; then
        echo "仅 IPv4 (IPv4-Only)"
    elif [[ $ipv6_active -eq 1 ]]; then
        echo "仅 IPv6 (IPv6-Only)"
    else
        echo "N/A"
    fi
}

check_status() {
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 2>/dev/null || echo "N/A")
    kernel_info=$(uname -r 2>/dev/null || echo "N/A")
    arch_info=$(uname -m 2>/dev/null || echo "N/A")
    [[ "$arch_info" == "x86_64" ]] && arch_info="amd64"
    virt_info=$(systemd-detect-virt 2>/dev/null || echo "N/A")
    IPV4="N/A"; IPV6="N/A"
    expected_stack="N/A"; actual_stack="已断开 (Disconnected)"
    WORK_MODE=""; CLIENT_STATUS=""; WIREPROXY_STATUS=""; WARPGO_STATUS=""
    RECONNECT_CMD=""; HARD_RECONNECT_CMD=""
    needs_reconnect=0; detection_note=""
    local mode="" socks5_port=""

    if [[ -x "$(type -p warp-cli)" ]]; then
        if pgrep -x "warp-svc" > /dev/null; then CLIENT_STATUS="运行中"; else CLIENT_STATUS="已安装但未运行"; fi
    else
        CLIENT_STATUS="未安装"
    fi
    if [[ -f "/usr/bin/wireproxy" ]]; then
        if pgrep -x "wireproxy" > /dev/null; then WIREPROXY_STATUS="运行中"; else WIREPROXY_STATUS="已安装但未运行"; fi
    else
        WIREPROXY_STATUS="未安装"
    fi
    # warp-go 识别: 二进制存在 + 进程在跑
    if [[ -x "$WARPGO_BIN" ]] || [[ -L "/usr/bin/warp-go" ]]; then
        if pgrep -x "warp-go" > /dev/null; then WARPGO_STATUS="运行中"; else WARPGO_STATUS="已安装但未运行"; fi
    else
        WARPGO_STATUS="未安装"
    fi

    # ---- 模式识别与重连命令赋值 (与接口是否存活无关) ----
    if [[ "$CLIENT_STATUS" == "运行中" ]]; then
        socks5_port=$(ss -nltp 2>/dev/null | grep -m1 '"warp-svc"' | awk '{print $4}' | awk -F: '{print $NF}') || true
        mode="socks5"
        local client_mode
        client_mode=$(warp-cli --accept-tos settings 2>/dev/null | awk '/Mode:/{print $2}' || echo "")
        if [[ "$client_mode" == "WarpProxy" ]]; then
            WORK_MODE="代理模式 (Proxy)"
        elif [[ "$client_mode" == "Warp" ]]; then
            WORK_MODE="全局模式 (Global)"
        else
            WORK_MODE="未知模式"
        fi
        expected_stack="双栈 (Dual-Stack)"; RECONNECT_CMD="/usr/bin/warp r"; HARD_RECONNECT_CMD="/usr/bin/warp r"
    elif [[ "$WIREPROXY_STATUS" == "运行中" ]]; then
        socks5_port=$(ss -nltp 2>/dev/null | grep -m1 '"wireproxy"' | awk '{print $4}' | awk -F: '{print $NF}') || true
        mode="socks5"
        expected_stack="双栈 (Dual-Stack)"; RECONNECT_CMD="/usr/bin/warp y"; HARD_RECONNECT_CMD="/usr/bin/warp y"
    elif wg show warp >/dev/null 2>&1; then
        mode="wg"
        local warp_conf_content=""
        if [[ -f "$WARP_CONF" ]]; then
            warp_conf_content=$(cat "$WARP_CONF" 2>/dev/null) || warp_conf_content=""
        fi
        expected_stack=$(read_expected_stack "$warp_conf_content")
        if echo "$warp_conf_content" | grep -qE '^[[:space:]]*Table[[:space:]]*=?' 2>/dev/null; then
            WORK_MODE="非全局"
        else
            WORK_MODE="全局"
        fi
        RECONNECT_CMD="/usr/bin/warp n"; HARD_RECONNECT_CMD="/usr/bin/warp o"
    elif [[ "$WARPGO_STATUS" == "运行中" ]] && ip link show "$WARPGO_IFACE" >/dev/null 2>&1; then
        # warp-go 模式: 用户态 Go TUN, 接口名大写 WARP
        mode="warpgo"
        local warpgo_conf_content=""
        if [[ -f "$WARPGO_CONF" ]]; then
            warpgo_conf_content=$(cat "$WARPGO_CONF" 2>/dev/null) || warpgo_conf_content=""
        fi
        expected_stack=$(read_expected_stack "$warpgo_conf_content")
        # warp-go 非全局: AllowedIPs 被注释 (#AllowedIPs); 全局: 未注释
        if echo "$warpgo_conf_content" | grep -qE '^[[:space:]]*#AllowedIPs' 2>/dev/null; then
            WORK_MODE="非全局"
        else
            WORK_MODE="全局"
        fi
        RECONNECT_CMD="/usr/bin/warp-go o"; HARD_RECONNECT_CMD="/usr/bin/warp-go o"
    elif [[ -f "$WARPGO_CONF" ]]; then
        # warp-go 接口未激活但配置存在 (掉线/未拉起) → 仍可重连重建
        mode="down_warpgo"
        local warpgo_conf_content=""
        warpgo_conf_content=$(cat "$WARPGO_CONF" 2>/dev/null) || warpgo_conf_content=""
        expected_stack=$(read_expected_stack "$warpgo_conf_content")
        RECONNECT_CMD="/usr/bin/warp-go o"; HARD_RECONNECT_CMD="/usr/bin/warp-go o"
        detection_note="WARP-Go 接口未激活"
    elif [[ -f "$WARP_CONF" ]]; then
        # WARP 接口不存在但配置存在 (掉线/未拉起) → 仍可重连重建
        mode="down"
        local warp_conf_content=""
        warp_conf_content=$(cat "$WARP_CONF" 2>/dev/null) || warp_conf_content=""
        expected_stack=$(read_expected_stack "$warp_conf_content")
        RECONNECT_CMD="/usr/bin/warp n"; HARD_RECONNECT_CMD="/usr/bin/warp o"
        detection_note="WARP 接口未激活"
    fi

    # ---- 状态检测 ----
    local tmp4="/tmp/warp_ipv4.$$" tmp6="/tmp/warp_ipv6.$$"
    case "$mode" in
        wg)
            check_ip 4 "wg" > "$tmp4" &
            check_ip 6 "wg" > "$tmp6" &
            wait
            IPV4=$(cat "$tmp4" 2>/dev/null || echo "N/A")
            IPV6=$(cat "$tmp6" 2>/dev/null || echo "N/A")
            ;;
        warpgo)
            check_ip 4 "warpgo" > "$tmp4" &
            check_ip 6 "warpgo" > "$tmp6" &
            wait
            IPV4=$(cat "$tmp4" 2>/dev/null || echo "N/A")
            IPV6=$(cat "$tmp6" 2>/dev/null || echo "N/A")
            ;;
        down|down_warpgo)
            # 接口未激活: 直连检测 (无 --interface 绑定)
            check_ip 4 "global" > "$tmp4" &
            check_ip 6 "global" > "$tmp6" &
            wait
            IPV4=$(cat "$tmp4" 2>/dev/null || echo "N/A")
            IPV6=$(cat "$tmp6" 2>/dev/null || echo "N/A")
            ;;
        socks5)
            if [[ -n "$socks5_port" ]]; then
                IPV4=$(get_warp_ip_details 4 "socks5" "$socks5_port")
                IPV6=$(get_warp_ip_details 6 "socks5" "$socks5_port")
            fi
            ;;
        *)
            detection_note="未安装 WARP 服务"
            ;;
    esac
    rm -f "$tmp4" "$tmp6"

    # ---- 实际栈 ----
    local ipv4_ok=0 ipv6_ok=0
    [[ "$IPV4" != "N/A" ]] && ipv4_ok=1
    [[ "$IPV6" != "N/A" ]] && ipv6_ok=1
    if [[ $ipv4_ok -eq 1 && $ipv6_ok -eq 1 ]]; then
        actual_stack="双栈 (Dual-Stack)"
    elif [[ $ipv4_ok -eq 1 ]]; then
        actual_stack="仅 IPv4 (IPv4-Only)"
    elif [[ $ipv6_ok -eq 1 ]]; then
        actual_stack="仅 IPv6 (IPv6-Only)"
    fi

    # ---- 符合性判定 ----
    local ipv4_expected=0 ipv6_expected=0
    case "$expected_stack" in
        *"双栈"*) ipv4_expected=1; ipv6_expected=1 ;;
        *"IPv4"*) ipv4_expected=1 ;;
        *"IPv6"*) ipv6_expected=1 ;;
    esac

    if [[ $ipv4_ok -eq 0 && $ipv6_ok -eq 0 ]]; then
        # 检测 API 完全不可用 (非 WARP 故障): 以第二信源判定, 防止误触发重连
        # wg-quick 用握手新鲜度; warp-go 用进程/接口存活
        if [[ "$mode" == "wg" ]] && wg_handshake_fresh; then
            conformity_status="符合预期配置 (握手正常, 检测 API 暂不可用)"
        elif [[ "$mode" == "warpgo" ]] && warpgo_alive; then
            conformity_status="符合预期配置 (进程存活, 检测 API 暂不可用)"
        else
            conformity_status="连接丢失"
            needs_reconnect=1
        fi
    else
        # API 有结果: 按预期栈对比缺失栈
        local missing=0
        if [[ $ipv4_expected -eq 1 && $ipv4_ok -eq 0 ]]; then missing=1; fi
        if [[ $ipv6_expected -eq 1 && $ipv6_ok -eq 0 ]]; then missing=1; fi
        if [[ $missing -eq 1 ]]; then
            conformity_status="与预期配置不符"
            needs_reconnect=1
        else
            conformity_status="符合预期配置"
        fi
    fi
    return
}

# ============================================================
# 重连函数 (支持 fallback)
# ============================================================

attempt_reconnect() {
    local method="$1"
    local cmd="$2"
    local is_connected="${3:-0}"  # 当前接口是否存活 (1=是, 0=否)
    local cmd_status=0

    case "$method" in
        "soft")
            log_and_echo "   [重连方法] 软重连 (warp n)"
            log_and_echo "   [执行命令] $cmd"
            # 注意: 不能用 `if ! cmd; then cmd_status=$?` —— `!` 反转后 $? 恒为 0
            if $cmd >> "$LOG_FILE" 2>&1; then
                cmd_status=0
            else
                cmd_status=$?
            fi
            ;;
        "hard")
            if [[ "$is_connected" -eq 1 ]]; then
                # 接口存活但 IP 异常 → 先关闭再开启
                log_and_echo "   [重连方法] 硬重连 (warp o - 先关闭再开启)"
                log_and_echo "   [执行命令] $cmd (关闭)"
                local close_status=0
                if $cmd >> "$LOG_FILE" 2>&1; then
                    close_status=0
                else
                    close_status=$?
                fi
                if [[ $close_status -eq 0 ]]; then
                    log_and_echo "   [状态] 接口已关闭，等待 ${HARD_RECONNECT_DELAY} 秒..."
                    sleep "$HARD_RECONNECT_DELAY"
                else
                    log_and_echo "   [警告] 关闭接口返回非零状态: $close_status"
                fi
            else
                log_and_echo "   [重连方法] 硬重连 (warp o - 接口已断开，直接开启)"
            fi
            # 统一执行开启
            log_and_echo "   [执行命令] $cmd (开启)"
            if $cmd >> "$LOG_FILE" 2>&1; then
                cmd_status=0
            else
                cmd_status=$?
            fi
            ;;
    esac
    return $cmd_status
}

main() {
    declare os_info kernel_info arch_info virt_info IPV4 IPV6
    declare expected_stack actual_stack conformity_status WORK_MODE CLIENT_STATUS WIREPROXY_STATUS WARPGO_STATUS
    declare RECONNECT_CMD HARD_RECONNECT_CMD needs_reconnect detection_note
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---" >> "$LOG_FILE"
    log_and_echo "========================================================================"
    log_and_echo " WARP Status Report & Auto-Heal  v${VERSION}"
    setup_log_rotation
    setup_cron_job
    check_status
    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 系统信息:"
    log_and_echo "   当前操作系统: $os_info"; log_and_echo "   内核: $kernel_info"
    log_and_echo "   处理器架构: $arch_info"; log_and_echo "   虚拟化: $virt_info"
    log_and_echo "   IPv4: $IPV4"; log_and_echo "   IPv6: $IPV6"
    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 服务状态:"
    if [[ "$actual_stack" != "已断开 (Disconnected)" ]]; then
        log_and_echo "   WARP 网络接口已开启"
        if [[ -n "$WORK_MODE" ]]; then log_and_echo "   工作模式: $WORK_MODE"; fi
    else
        # 接口已断开: 显示哪个后端断开 (wg-quick 或 warp-go)
        if wg show warp >/dev/null 2>&1; then
            log_and_echo "   WARP 网络接口已断开"
        elif [[ "$WARPGO_STATUS" == "运行中" ]] && ip link show "$WARPGO_IFACE" >/dev/null 2>&1; then
            log_and_echo "   WARP-Go 网络接口已断开"
        fi
        if [[ -n "$detection_note" ]]; then log_and_echo "   备注: $detection_note"; fi
    fi
    log_and_echo "   Client: $CLIENT_STATUS"; log_and_echo "   WireProxy: $WIREPROXY_STATUS"
    [[ "$WARPGO_STATUS" != "未安装" ]] && log_and_echo "   WARP-Go: $WARPGO_STATUS"
    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 配置符合性分析:"
    log_and_echo "   预期配置: $expected_stack"
    log_and_echo "   实际状态: $actual_stack"
    log_and_echo "   符合状态: $conformity_status"
    log_and_echo "========================================================================"
    if [[ $needs_reconnect -eq 1 && -n "$RECONNECT_CMD" ]]; then
        log_and_echo " 最终诊断: 连接异常或配置不符。启动自动重连程序..."

        # -------------------- 阶段 1: 软重连 (warp n) --------------------
        log_and_echo "------------------------------------------------------------------------"
        log_and_echo " [阶段 1/2] 尝试软重连 (warp n)..."
        local soft_success=0
        for i in $(seq 1 $MAX_RETRIES); do
            log_and_echo "   [尝试 $i/$MAX_RETRIES]"
            attempt_reconnect "soft" "$RECONNECT_CMD"
            log_and_echo "   等待 ${RECONNECT_WAIT_TIME} 秒以待网络稳定..."
            sleep "$RECONNECT_WAIT_TIME"
            check_status
            if [[ $needs_reconnect -eq 0 ]]; then
                log_and_echo "   [成功] 软重连成功，连接已恢复正常。"
                log_and_echo "   - 当前 IPv4: $IPV4"
                log_and_echo "   - 当前 IPv6: $IPV6"
                soft_success=1
                break
            else
                log_and_echo "   [失败] 软重连后状态仍不符合预期 ($conformity_status)。"
            fi
        done

        # -------------------- 阶段 2: 硬重连 Fallback (warp o) --------------------
        if [[ $soft_success -eq 0 ]]; then
            log_and_echo "------------------------------------------------------------------------"
            log_and_echo " [阶段 2/2] 软重连失败，Fallback 到硬重连 (warp o)..."

            for i in $(seq 1 $MAX_RETRIES); do
                log_and_echo "   [尝试 $i/$MAX_RETRIES]"
                # 判断 wg 接口当前是否存活
                local wg_alive=0
                if wg show warp >/dev/null 2>&1; then wg_alive=1; fi
                attempt_reconnect "hard" "$HARD_RECONNECT_CMD" "$wg_alive"
                log_and_echo "   等待 ${RECONNECT_WAIT_TIME} 秒以待网络稳定..."
                sleep "$RECONNECT_WAIT_TIME"
                check_status
                if [[ $needs_reconnect -eq 0 ]]; then
                    log_and_echo "   [成功] 硬重连成功，连接已恢复正常。"
                    log_and_echo "   - 当前 IPv4: $IPV4"
                    log_and_echo "   - 当前 IPv6: $IPV6"
                    break
                else
                    log_and_echo "   [失败] 硬重连后状态仍不符合预期 ($conformity_status)。"
                fi
                if [[ $i -eq $MAX_RETRIES ]]; then
                    log_and_echo " 最终诊断: 所有重连尝试均失败 (软重连 $MAX_RETRIES 次 + 硬重连 $MAX_RETRIES 次)。"
                    log_and_echo " 提示: 当前脚本 v${VERSION}, 上游依赖 fscarmen/warp-sh v3.2.6 (兼容 v3.1.8+)"
                    log_and_echo " 建议: 请手动检查 WARP 服务状态或网络连接。"
                fi
            done
        fi
    elif [[ $needs_reconnect -eq 1 ]]; then
        log_and_echo " 最终诊断: 连接异常，但未检测到已安装的 WARP 服务，无法执行自动重连。"
        log_and_echo " 建议: 请先安装 WARP (warp-cli / wireproxy / wg-quick) 后再运行此脚本。"
    else
        log_and_echo " 最终诊断: 连接正常且符合配置。"
    fi
    log_and_echo ""
}

(
    flock -n 200 || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - 已有warp_monitor进程运行中。" | tee -a "$LOG_FILE"; exit 1; }
    main
) 200>"$LOCK_FILE"
