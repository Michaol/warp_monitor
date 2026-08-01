#!/usr/bin/env bash
# warp_monitor.sh 模拟测试套件
# 通过 stub 系统命令 + 假配置文件，验证 check_status 的判定逻辑
# 用法: bash test_warp_monitor.sh

set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"


PASS=0; FAIL=0

STUB_DIR="$TMP/stubs"
mkdir -p "$STUB_DIR"

run_scenario() {
    local name="$1" wg_up="$2" conf="$3" api4="$4" api6="$5" handshake_delta="$6"
    local expected_msg="$7" expected_reconnect="${8:-0}"
    local log="$TMP/log_$name"
    : > "$log"
    mkdir -p "$TMP/conf_$name" "$TMP/logrotate_$name"
    printf '%b' "$conf" > "$TMP/conf_$name/warp.conf"

    # 实时计算握手时间戳 (避免测试套件长时间运行后 FRESH 过期)
    local handshake
    if [[ "$handshake_delta" == "fresh" ]]; then
        handshake=$(( $(date +%s) - 50 ))
    else
        handshake=$(( $(date +%s) - 500 ))
    fi

    # id: 模拟 root
    cat > "$STUB_DIR/id" <<EOF
#!/usr/bin/env bash
echo "0"
exit 0
EOF

    # wg: show 判断接口存活; latest-handshakes 输出握手时间
    cat > "$STUB_DIR/wg" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "show" && "\$2" == "warp" && "\$3" == "latest-handshakes" ]]; then
    echo "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=	$handshake"
    exit 0
elif [[ "\$1" == "show" && "\$2" == "warp" ]]; then
    $wg_up
fi
exit 0
EOF

    # ping / ping6: 总是成功
    cat > "$STUB_DIR/ping" <<EOF
#!/usr/bin/env bash
exit 0
EOF
    cat > "$STUB_DIR/ping6" <<EOF
#!/usr/bin/env bash
exit 0
EOF

    # curl: 按 -4/-6 返回对应多行 JSON (与真实 API 格式一致, awk 解析依赖换行)
    cat > "$STUB_DIR/curl" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"-6"* ]]; then
    cat <<'JSON'
$api6
JSON
else
    cat <<'JSON'
$api4
JSON
fi
exit 0
EOF

    # crontab: 拒绝真实写入
    cat > "$STUB_DIR/crontab" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
    exit 1
fi
exit 0
EOF

    # flock: 测试环境可能缺失, 放行 (跳过锁机制)
    cat > "$STUB_DIR/flock" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-n" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$STUB_DIR/"*

    # 复制脚本并打桩配置 (缩短等待时间加速测试)
    sed -e "s|^LOG_FILE=.*|LOG_FILE=\"$log\"|" \
        -e "s|^LOGROTATE_CONF=.*|LOGROTATE_CONF=\"$TMP/logrotate_$name/warp_monitor\"|" \
        -e "s|^WARP_CONF=.*|WARP_CONF=\"$TMP/conf_$name/warp.conf\"|" \
        -e "s|^RECONNECT_WAIT_TIME=.*|RECONNECT_WAIT_TIME=1|" \
        -e "s|^HARD_RECONNECT_DELAY=.*|HARD_RECONNECT_DELAY=0|" \
        "$BASE/warp_monitor.sh" > "$TMP/wm_$name.sh"

    PATH="$STUB_DIR:$PATH" bash "$TMP/wm_$name.sh" > "$TMP/stdout_$name" 2>&1

    local msg
    msg=$(grep -m1 "$expected_msg" "$log" 2>/dev/null)
    if [[ -n "$msg" ]]; then
        PASS=$((PASS+1)); echo "[PASS] $name: 判定 [$expected_msg]"
    else
        FAIL=$((FAIL+1)); echo "[FAIL] $name: 期望 [$expected_msg], 实际日志:"
        grep -E "最终诊断|符合状态|实际状态|预期配置" "$log" 2>/dev/null | sed 's/^/    /'
    fi

    if [[ $expected_reconnect -eq 1 ]]; then
        if grep -q "阶段 1/2" "$log" 2>/dev/null; then
            PASS=$((PASS+1)); echo "[PASS] $name: 触发重连"
        else
            FAIL=$((FAIL+1)); echo "[FAIL] $name: 应触发重连但未触发"
        fi
    else
        if ! grep -q "阶段 1/2" "$log" 2>/dev/null; then
            PASS=$((PASS+1)); echo "[PASS] $name: 未触发重连"
        else
            FAIL=$((FAIL+1)); echo "[FAIL] $name: 不应触发重连却触发了"
        fi
    fi
    echo "---"
}

NOW=$(date +%s)
FRESH="fresh"
OLD="old"

DUAL_CONF="[Interface]\nPrivateKey = x\nTable = off\n[Peer]\nAllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0\n"
DUAL_INLINE_CONF="[Interface]\nPrivateKey = x\nTable = off\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n"
V4_ONLY_CONF="[Interface]\nPrivateKey = x\nTable = off\n[Peer]\nAllowedIPs = 0.0.0.0/0\n"
V6_ONLY_CONF="[Interface]\nPrivateKey = x\nTable = off\n[Peer]\nAllowedIPs = ::/0\n"
GLOBAL_CONF="[Interface]\nPrivateKey = x\n[Peer]\nAllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0\n"

API4_ON=$'{\n  "ip": "1.2.3.4",\n  "country": "美国",\n  "isp": "AS13335 Cloudflare, Inc.",\n  "warp": "on"\n}'
API6_ON=$'{\n  "ip": "2606::1",\n  "country": "美国",\n  "isp": "AS13335 Cloudflare, Inc.",\n  "warp": "on"\n}'
API4_OFF=$'{\n  "ip": "209.141.43.118",\n  "country": "美国",\n  "isp": "BuyVM",\n  "warp": "off"\n}'
API6_OFF=$'{\n  "ip": "2605:6400:20::1",\n  "country": "美国",\n  "isp": "BuyVM",\n  "warp": "off"\n}'
API_EMPTY=""

WG_UP="echo \"interface: warp\""
WG_DOWN="exit 1"

# ---- 测试用例 ----
run_scenario "dual_ok"            "$WG_UP" "$DUAL_CONF"       "$API4_ON" "$API6_ON" "$FRESH" "符合预期配置" 0
run_scenario "dual_inline_ok"     "$WG_UP" "$DUAL_INLINE_CONF" "$API4_ON" "$API6_ON" "$FRESH" "符合预期配置" 0
run_scenario "dual_v6_down"       "$WG_UP" "$DUAL_CONF"       "$API4_ON" "$API_EMPTY" "$OLD" "与预期配置不符" 1
run_scenario "v4only_v6_down_ok"  "$WG_UP" "$V4_ONLY_CONF"    "$API4_ON" "$API_EMPTY" "$OLD" "符合预期配置" 0
run_scenario "v6only_v4_down"     "$WG_UP" "$V6_ONLY_CONF"    "$API_EMPTY" "$API6_ON" "$OLD" "符合预期配置" 0
run_scenario "iface_down_conf"    "$WG_DOWN" "$DUAL_CONF"     "$API4_OFF" "$API6_OFF" "$OLD" "连接丢失" 1
run_scenario "iface_down_na"      "$WG_DOWN" "$DUAL_CONF"     "$API_EMPTY" "$API_EMPTY" "$OLD" "连接丢失" 1
run_scenario "global_ok"          "$WG_UP" "$GLOBAL_CONF"     "$API4_ON" "$API6_ON" "$FRESH" "符合预期配置" 0
run_scenario "handshake_fresh_api" "$WG_UP" "$DUAL_CONF"      "$API_EMPTY" "$API_EMPTY" "$FRESH" "握手正常" 0
run_scenario "handshake_old_api"  "$WG_UP" "$DUAL_CONF"       "$API_EMPTY" "$API_EMPTY" "$OLD" "连接丢失" 1

echo "======================"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo "全部通过" || echo "存在失败用例"
exit $FAIL
