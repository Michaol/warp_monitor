#!/usr/bin/env bash
set -euo pipefail

VERSION="1.1.1"

LOG_FILE="/var/log/warp_monitor.log"
LOGROTATE_CONF="/etc/logrotate.d/warp_monitor"
MAX_RETRIES=2
RECONNECT_WAIT_TIME=15
HARD_RECONNECT_DELAY=3
SCRIPT_PATH=$(realpath "$0")
LOCK_FILE="/var/run/warp_monitor.lock"

if [ "$(id -u)" -ne 0 ]; then
   echo "错误: 此脚本必须以 root 权限运行才能管理 logrotate 和 crontab。"
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
    if [ -n "$INSTALL_CMD" ]; then
        $INSTALL_CMD >/dev/null 2>&1
        if ! command -v flock >/dev/null 2>&1; then
            echo "[ERROR] 自动安装 util-linux (flock) 失败, 脚本无法保证安全运行, 即将退出。" | tee -a "$LOG_FILE"
            exit 1
        else
            echo "[SUCCESS] 成功安装 util-linux, flock 命令已可用。" | tee -a "$LOG_FILE"
        fi
    else
        echo "[ERROR] 未知的包管理器, 无法自动安装 util-linux。脚本无法保证安全运行, 即将退出。" | tee -a "$LOG_FILE"
        exit 1
    fi
fi

if [ -f /etc/alpine-release ]; then
    if ! echo "test" | grep -P "test" > /dev/null 2>&1; then
        echo "[INFO] 检测到 Alpine Linux 且缺少 GNU grep, 正在尝试自动安装..." | tee -a "$LOG_FILE"
        if command -v apk > /dev/null; then
            apk update && apk add grep
            if ! echo "test" | grep -P "test" > /dev/null 2>&1; then
                echo "[ERROR] 自动安装 GNU grep 失败, 脚本无法继续。请手动执行 'apk add grep'。" | tee -a "$LOG_FILE"
                exit 1
            else
                echo "[SUCCESS] 成功安装 GNU grep。" | tee -a "$LOG_FILE"
            fi
        else
            echo "[ERROR] 在 Alpine 系统上未找到 'apk' 命令, 无法安装依赖。" | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
fi

log_and_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

get_warp_ip_details() {
    local ip_version="$1"
    local extra_curl_opts="$2"
    local ip_json warp_status warp_ip country asn_org
    
    # 使用上游自建 IP API (v3.2.0)，一次请求获取 WARP 状态、IP、国家和 ISP
    if grep -q 'socks5' <<< "$extra_curl_opts" 2>/dev/null; then
        # SOCKS5 代理模式：先获取 IP，再查询详情
        warp_ip=$(curl -s -A a --retry 2 $extra_curl_opts https://api-ipv${ip_version}.ip.sb/ip 2>/dev/null)
        if [[ -z "$warp_ip" ]]; then
            echo "N/A"
            return
        fi
        ip_json=$(curl -s --retry 2 --max-time 10 "https://ip.cloudflare.now.cc/${warp_ip}?lang=zh-CN" 2>/dev/null)
        # 检查是否为 Cloudflare IP
        if echo "$ip_json" | grep -qi '"isp".*Cloudflare'; then
            warp_status="on"
        else
            echo "N/A"
            return
        fi
    else
        # 直连或 --interface 模式
        ip_json=$(curl -s --retry 2 --max-time 10 $extra_curl_opts -${ip_version} "https://ip.cloudflare.now.cc?lang=zh-CN" 2>/dev/null)
        if [[ -z "$ip_json" ]]; then
            echo "N/A"
            return
        fi
        warp_status=$(echo "$ip_json" | sed -n 's/.*"warp":[ ]*"\([^"]*\)".*/\1/p')
        warp_ip=$(echo "$ip_json" | sed -n 's/.*"ip":[ ]*"\([^"]*\)".*/\1/p')
    fi
    
    if [[ "$warp_status" == "on" || "$warp_status" == "plus" ]]; then
        country=$(echo "$ip_json" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p')
        asn_org=$(echo "$ip_json" | sed -n 's/.*"isp":[ ]*"\([^"]*\)".*/\1/p')
        echo "$warp_ip $country $asn_org"
    else
        echo "N/A"
    fi
}

setup_log_rotation() {
    log_and_echo "------------------------------------------------------------------------"
    log_and_echo " 日志管理配置检查:"
    if [ -f "$LOGROTATE_CONF" ]; then
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
        if [ $? -eq 0 ]; then log_and_echo "   [SUCCESS] 成功创建配置文件。"; else log_and_echo "   [ERROR] 创建配置文件失败, 请检查权限。"; fi
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
            (crontab -l | grep -vF "$cron_comment"; echo "$cron_job") | crontab -
            log_and_echo "   [SUCCESS] 成功为定时任务添加20分钟超时保护。"
        fi
    else
        log_and_echo "   [INFO] 定时监控任务不存在, 正在添加..."
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        if [ $? -eq 0 ]; then
            log_and_echo "   [SUCCESS] 成功添加定时任务 (带20分钟超时保护), 脚本将每小时自动运行。"
        else
            log_and_echo "   [ERROR] 添加定时任务失败。"
        fi
    fi
}

check_status() {
    os_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 2>/dev/null || echo "N/A")
    kernel_info=$(uname -r 2>/dev/null || echo "N/A")
    arch_info=$(uname -m 2>/dev/null || echo "N/A")
    [[ "$arch_info" == "x86_64" ]] && arch_info="amd64"
    virt_info=$(systemd-detect-virt 2>/dev/null || echo "N/A")
    IPV4="N/A"; IPV6="N/A"; extra_opts=""; expected_stack="-"; actual_stack="已断开 (Disconnected)";
    WORK_MODE=""; CLIENT_STATUS=""; WIREPROXY_STATUS=""; RECONNECT_CMD=""; needs_reconnect=0;
    if [ -x "$(type -p warp-cli)" ]; then
        if pgrep -x "warp-svc" > /dev/null; then CLIENT_STATUS="运行中"; else CLIENT_STATUS="已安装但未运行"; fi
    else
        CLIENT_STATUS="未安装"
    fi
    if [ -f "/usr/bin/wireproxy" ]; then
        if pgrep -x "wireproxy" > /dev/null; then WIREPROXY_STATUS="运行中"; else WIREPROXY_STATUS="已安装但未运行"; fi
    else
        WIREPROXY_STATUS="未安装"
    fi
    if [[ "$CLIENT_STATUS" == "运行中" ]]; then
        local port=$(ss -nltp | grep -m1 '"warp-svc"' | awk '{print $4}' | awk -F: '{print $NF}')
        if [[ -n "$port" ]]; then extra_opts="--socks5 127.0.0.1:$port"; fi
        expected_stack="双栈 (Dual-Stack)"; RECONNECT_CMD="/usr/bin/warp r"
    elif [[ "$WIREPROXY_STATUS" == "运行中" ]]; then
        local port=$(ss -nltp | grep -m1 '"wireproxy"' | awk '{print $4}' | awk -F: '{print $NF}')
        if [[ -n "$port" ]]; then extra_opts="--socks5 127.0.0.1:$port"; fi
        expected_stack="双栈 (Dual-Stack)"; RECONNECT_CMD="/usr/bin/warp y"
    elif wg show warp >/dev/null 2>&1; then
        if [ -f /etc/wireguard/warp.conf ]; then
            # 一次读取配置文件，减少 I/O
            local warp_conf_content
            warp_conf_content=$(cat /etc/wireguard/warp.conf 2>/dev/null) || true
            local ipv4_active=$(echo "$warp_conf_content" | grep -c '^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*0.0.0.0/0' || echo 0)
            local ipv6_active=$(echo "$warp_conf_content" | grep -c '^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*::/0' || echo 0)
            if [[ $ipv4_active -gt 0 && $ipv6_active -gt 0 ]]; then expected_stack="双栈 (Dual-Stack)"; fi
            if [[ $ipv4_active -gt 0 && $ipv6_active -eq 0 ]]; then expected_stack="仅 IPv4 (IPv4-Only)"; fi
            if [[ $ipv4_active -eq 0 && $ipv6_active -gt 0 ]]; then expected_stack="仅 IPv6 (IPv6-Only)"; fi
        fi
        if echo "$warp_conf_content" | grep -q '^Table'; then WORK_MODE="非全局"; extra_opts="--interface warp"; else WORK_MODE="全局"; fi
        RECONNECT_CMD="/usr/bin/warp n"
    fi
    if [[ -n "$extra_opts" || "$WORK_MODE" == "全局" ]]; then
        IPV4=$(get_warp_ip_details 4 "$extra_opts"); IPV6=$(get_warp_ip_details 6 "$extra_opts")
    fi
    if [[ "$IPV4" != "N/A" && "$IPV6" != "N/A" ]]; then actual_stack="双栈 (Dual-Stack)"; fi
    if [[ "$IPV4" != "N/A" && "$IPV6" == "N/A" ]]; then actual_stack="仅 IPv4 (IPv4-Only)"; fi
    if [[ "$IPV4" == "N/A" && "$IPV6" != "N/A" ]]; then actual_stack="仅 IPv6 (IPv6-Only)"; fi
    if [[ "$actual_stack" == "已断开 (Disconnected)" ]]; then
        conformity_status="连接丢失"; needs_reconnect=1
    elif [[ "$actual_stack" == "$expected_stack" ]]; then
        conformity_status="符合预期配置"
    else
        conformity_status="与预期配置不符"
        if [[ "$expected_stack" == "双栈 (Dual-Stack)" ]]; then needs_reconnect=1; fi
    fi
}

# ============================================================
# 重连函数（支持 fallback）
# ============================================================

attempt_reconnect() {
    local method="$1"
    local cmd="$2"
    local cmd_status=0
    
    case "$method" in
        "soft")
            log_and_echo "   [重连方法] 软重连 (warp n)"
            log_and_echo "   [执行命令] $cmd"
            $cmd >> "$LOG_FILE" 2>&1
            cmd_status=$?
            ;;
        "hard")
            log_and_echo "   [重连方法] 硬重连 (warp o - 关闭接口)"
            log_and_echo "   [执行命令] $cmd"
            $cmd >> "$LOG_FILE" 2>&1
            local close_status=$?
            if [[ $close_status -eq 0 ]]; then
                log_and_echo "   [状态] 接口已关闭，等待 ${HARD_RECONNECT_DELAY} 秒..."
                sleep $HARD_RECONNECT_DELAY
                log_and_echo "   [重连方法] 硬重连 (warp o - 开启接口)"
                log_and_echo "   [执行命令] $cmd"
                $cmd >> "$LOG_FILE" 2>&1
                cmd_status=$?
            else
                log_and_echo "   [警告] 关闭接口返回非零状态: $close_status"
                cmd_status=$close_status
            fi
            ;;
    esac
    return $cmd_status
}

main() {
    declare os_info kernel_info arch_info virt_info IPV4 IPV6
    declare expected_stack actual_stack conformity_status WORK_MODE CLIENT_STATUS WIREPROXY_STATUS
    declare RECONNECT_CMD needs_reconnect
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
        if wg show warp >/dev/null 2>&1; then log_and_echo "   WARP 网络接口已断开"; fi
    fi
    log_and_echo "   Client: $CLIENT_STATUS"; log_and_echo "   WireProxy: $WIREPROXY_STATUS"
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
            sleep $RECONNECT_WAIT_TIME
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
            
            # 将重连命令末尾的 n 改为 o（避免误伤路径中的 n）
            local HARD_RECONNECT_CMD="${RECONNECT_CMD% n} o"
            
            for i in $(seq 1 $MAX_RETRIES); do
                log_and_echo "   [尝试 $i/$MAX_RETRIES]"
                attempt_reconnect "hard" "$HARD_RECONNECT_CMD"
                log_and_echo "   等待 ${RECONNECT_WAIT_TIME} 秒以待网络稳定..."
                sleep $RECONNECT_WAIT_TIME
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
                    log_and_echo " 建议: 请手动检查 WARP 服务状态或网络连接。"
                fi
            done
        fi
    else
        log_and_echo " 最终诊断: 连接正常且符合配置。"
    fi
    log_and_echo ""
}

(
    flock -n 200 || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] - 已有warp_monitor进程运行中。" | tee -a "$LOG_FILE"; exit 1; }
    main
) 200>"$LOCK_FILE"
