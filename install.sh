#!/bin/sh

# Unified installer for v2ray-tproxy via firewall include
# Usage: sh install.sh

# Colors (optional)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
CONFIG_SRC="$SCRIPT_DIR/config.conf"
CONFIG_DST="/etc/v2ray-tproxy.conf"
FW_INCLUDE="/etc/firewall.v2ray"

say() { echo "$1"; }
ok() { echo "${GREEN}[✓]${NC} $1"; }
warn() { echo "${YELLOW}[WARN]${NC} $1"; }
err() { echo "${RED}[ERROR]${NC} $1"; }

require_root() {
	[ "$(id -u)" -eq 0 ] || { err "需要 root 权限"; exit 1; }
}

precheck() {
	say "${BLUE}[PRE-CHECK] 检查系统依赖...${NC}"
	# BusyBox ash 环境下尽量少依赖
	for cmd in uci iptables ip iptables-save sh; do
		command -v "$cmd" >/dev/null 2>&1 || { err "缺少命令: $cmd"; exit 1; }
	done
	# 透明代理内核模块通常需要：xt_TPROXY、xt_socket
	# 这里只提示，不强制退出
	lsmod 2>/dev/null | grep -Eq '\bxt_TPROXY\b' || warn "未检测到 xt_TPROXY 模块，若规则失败请安装相应内核模块"
	lsmod 2>/dev/null | grep -Eq '\bxt_socket\b' || warn "未检测到 xt_socket 模块，若规则失败请安装相应内核模块"
	# 检查 ipset 和 xt_set 模块支持（UDP智能分流必需）
	command -v ipset >/dev/null 2>&1 || warn "未检测到 ipset 命令，chinadns-ng 分流功能可能无法正常工作"
	lsmod 2>/dev/null | grep -Eq '\bxt_set\b' || warn "未检测到 xt_set 模块，UDP智能分流可能无法正常工作"
	# 检查 ipset 集合是否存在
	if command -v ipset >/dev/null 2>&1; then
		[ -f "$CONFIG_DST" ] && . "$CONFIG_DST"
		CHN_IPSET4="${CHN_IPSET4:-chnip}"
		CHN_IPSET6="${CHN_IPSET6:-chnip6}"
		ipset list "$CHN_IPSET4" >/dev/null 2>&1 || warn "ipset 集合 $CHN_IPSET4 不存在，UDP智能分流将失效"
		[ "${ENABLE_IPV6:-0}" = "1" ] && ipset list "$CHN_IPSET6" >/dev/null 2>&1 || true
	fi
	ok "依赖检查完成"
}

check_after_config() {
	# 根据配置给出更具体的提示（如 IPv6 开启但缺 ip6tables）
	[ -f "$CONFIG_DST" ] && . "$CONFIG_DST"
	# 统一计算 MARK 以做基本校验
	MARK_COMPUTED="${FW_MARK:-$MARK_VALUE}"
	if [ -z "${TPROXY_PORT:-}" ] || [ -z "${MARK_COMPUTED:-}" ]; then
		warn "未设置 TPROXY_PORT 或 FW_MARK/MARK_VALUE，透明代理规则可能不生效"
	fi
	if [ "${ENABLE_IPV6:-0}" = "1" ]; then
		if ! command -v ip6tables >/dev/null 2>&1; then
			warn "检测到 ENABLE_IPV6=1，但系统缺少 ip6tables，IPv6 规则将无法应用"
		fi
	fi
}

install_config() {
	if [ -f "$CONFIG_SRC" ]; then
		if [ -f "$CONFIG_DST" ]; then
			# 如果目标存在但不同，做一次备份
			if ! cmp -s "$CONFIG_SRC" "$CONFIG_DST" 2>/dev/null; then
				cp -f "$CONFIG_DST" "$CONFIG_DST.bak" 2>/dev/null && warn "已备份现有配置到 $CONFIG_DST.bak"
				cp -f "$CONFIG_SRC" "$CONFIG_DST" || { err "复制配置失败"; exit 1; }
				ok "更新配置到 $CONFIG_DST"
			else
				ok "配置已是最新 ($CONFIG_DST)"
			fi
		else
			cp -f "$CONFIG_SRC" "$CONFIG_DST" || { err "复制配置失败"; exit 1; }
			ok "安装配置到 $CONFIG_DST"
		fi
	else
		warn "未找到仓库内配置 $CONFIG_SRC，继续使用已存在的 $CONFIG_DST（若有）"
	fi
}

write_fw_include() {
	cat > "$FW_INCLUDE" <<'EOF'
#!/bin/sh
# firewall include for v2ray-tproxy (iptables) with chinadns-ng integration

CONFIG_FILE="/etc/v2ray-tproxy.conf"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# 统一 fwmark：优先使用 FW_MARK；若为空兼容旧 MARK_VALUE
MARK="${FW_MARK:-$MARK_VALUE}"

# chinadns-ng ipset 集合名称（从配置文件读取，兼容默认值）
# 确保在防火墙脚本中正确设置这些变量
CHN_IPSET4="${CHN_IPSET4:-chnip}"
CHN_IPSET6="${CHN_IPSET6:-chnip6}"
GFW_IPSET4="${GFW_IPSET4:-gfwip}"
GFW_IPSET6="${GFW_IPSET6:-gfwip6}"

# 调试信息（可选）
# echo "DEBUG: CHN_IPSET4=$CHN_IPSET4, CHN_IPSET6=$CHN_IPSET6"

# 清理旧规则（幂等）
# 先从 PREROUTING 移除挂载点，再删除自定义链（IPv4）
iptables -t mangle -D PREROUTING -j V2RAY 2>/dev/null
iptables -t mangle -D PREROUTING -j V2RAY_EXCLUDE 2>/dev/null
iptables -t mangle -F V2RAY 2>/dev/null
iptables -t mangle -X V2RAY 2>/dev/null
iptables -t mangle -F V2RAY_EXCLUDE 2>/dev/null
iptables -t mangle -X V2RAY_EXCLUDE 2>/dev/null
iptables -t mangle -F DIVERT 2>/dev/null
iptables -t mangle -X DIVERT 2>/dev/null

# IPv6 清理（按需，若 ip6tables 可用）。同时清理旧命名和新命名链。
if command -v ip6tables >/dev/null 2>&1; then
	# 新命名
	ip6tables -t mangle -D PREROUTING -j V2RAY6 2>/dev/null
	ip6tables -t mangle -D PREROUTING -j V2RAY6_EXCLUDE 2>/dev/null
	ip6tables -t mangle -F V2RAY6 2>/dev/null
	ip6tables -t mangle -X V2RAY6 2>/dev/null
	ip6tables -t mangle -F V2RAY6_EXCLUDE 2>/dev/null
	ip6tables -t mangle -X V2RAY6_EXCLUDE 2>/dev/null
	ip6tables -t mangle -F DIVERT6 2>/dev/null
	ip6tables -t mangle -X DIVERT6 2>/dev/null
	# 兼容旧命名（若之前使用过 V2RAY/V2RAY_EXCLUDE/DIVERT）
	ip6tables -t mangle -D PREROUTING -j V2RAY 2>/dev/null
	ip6tables -t mangle -D PREROUTING -j V2RAY_EXCLUDE 2>/dev/null
	ip6tables -t mangle -F V2RAY 2>/dev/null
	ip6tables -t mangle -X V2RAY 2>/dev/null
	ip6tables -t mangle -F V2RAY_EXCLUDE 2>/dev/null
	ip6tables -t mangle -X V2RAY_EXCLUDE 2>/dev/null
	ip6tables -t mangle -F DIVERT 2>/dev/null
	ip6tables -t mangle -X DIVERT 2>/dev/null
fi

# 创建并填充 DIVERT 链（IPv4）
iptables -t mangle -N DIVERT 2>/dev/null || true
iptables -t mangle -F DIVERT 2>/dev/null || true
[ -n "$MARK" ] && iptables -t mangle -A DIVERT -j MARK --set-mark "$MARK"
iptables -t mangle -A DIVERT -j ACCEPT

# 创建并填充 V2RAY_EXCLUDE（先排除再导流，IPv4）
iptables -t mangle -N V2RAY_EXCLUDE 2>/dev/null || true
iptables -t mangle -F V2RAY_EXCLUDE 2>/dev/null || true

# 排除本地/内网地址
for subnet in \
	0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 \
	169.254.0.0/16 172.16.0.0/12 \
	224.0.0.0/4 240.0.0.0/4; do
	iptables -t mangle -A V2RAY_EXCLUDE -d "$subnet" -j RETURN
done
[ -n "$LOCAL_SUBNET" ] && iptables -t mangle -A V2RAY_EXCLUDE -d "$LOCAL_SUBNET" -j RETURN

# 排除 chinadns-ng 标记的国内IP（直连）
# 注意：这里不需要再次排除，因为 chinadns-ng 已经在更高优先级处理了
# 但为了保险起见，我们仍然检查并记录

# 创建并填充 V2RAY（处理国外IP，IPv4）
iptables -t mangle -N V2RAY 2>/dev/null || true
iptables -t mangle -F V2RAY 2>/dev/null || true
iptables -t mangle -A V2RAY_EXCLUDE -j V2RAY

# 可选：限速日志，避免刷屏（需要 LOG 目标支持）
if [ -n "$LOG_PREFIX" ]; then
	iptables -t mangle -A V2RAY -m limit --limit 10/min -j LOG --log-prefix "$LOG_PREFIX " --log-level 6 2>/dev/null || true
fi

# TCP 透明代理（优先基于 socket 匹配做旁路）
iptables -t mangle -A V2RAY -p tcp -m socket -j DIVERT 2>/dev/null || true
[ -n "$TPROXY_PORT" ] && [ -n "$MARK" ] && iptables -t mangle -A V2RAY -p tcp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"

# UDP（可选）
if [ "${ENABLE_UDP:-0}" = "1" ] && [ -n "$TPROXY_PORT" ] && [ -n "$MARK" ]; then
	# 先排除关键UDP端口，避免网络问题
	if [ -n "${UDP_EXCLUDE_PORTS:-}" ]; then
		# 使用兼容性更好的方式解析端口列表
		OLD_IFS="$IFS"
		IFS=','
		set -- $UDP_EXCLUDE_PORTS
		IFS="$OLD_IFS"
		for port in "$@"; do
			[ -n "$port" ] && iptables -t mangle -A V2RAY -p udp --dport "$port" -j RETURN
		done
	fi
	
	# UDP智能分流：国内IP直连，国外IP走代理
	# 改进的条件判断：先检查ipset命令，再检查集合存在性
	if command -v ipset >/dev/null 2>&1; then
		# ipset命令可用，检查集合是否存在
		if ipset list "$CHN_IPSET4" >/dev/null 2>&1; then
			# 国内IP直连（不走代理）
			iptables -t mangle -A V2RAY -p udp -m set --match-set "$CHN_IPSET4" dst -j RETURN
			# 国外IP走代理
			iptables -t mangle -A V2RAY -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
			echo "INFO: UDP智能分流已启用，使用ipset集合 $CHN_IPSET4" >&2
		else
			# ipset命令可用但集合不存在，降级处理
			echo "WARN: ipset 集合 $CHN_IPSET4 不存在，UDP 智能分流已降级为全代理模式" >&2
			iptables -t mangle -A V2RAY -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
		fi
	else
		# ipset命令不可用，降级处理
		echo "WARN: ipset 命令不可用，UDP 智能分流已降级为全代理模式" >&2
		iptables -t mangle -A V2RAY -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
	fi
fi

# 将 EXCLUDE 挂到 chinadns-ng 规则之后（IPv4）
# chinadns-ng 规则优先级更高，会先处理
iptables -t mangle -I PREROUTING 3 -j V2RAY_EXCLUDE

# IPv6（可选，需 ENABLE_IPV6=1 且 ip6tables 可用）
if [ "${ENABLE_IPV6:-0}" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
	# 创建链（IPv6 使用独立命名：V2RAY6 / V2RAY6_EXCLUDE / DIVERT6）
	ip6tables -t mangle -N V2RAY6 2>/dev/null || true
	ip6tables -t mangle -F V2RAY6 2>/dev/null || true
	ip6tables -t mangle -N V2RAY6_EXCLUDE 2>/dev/null || true
	ip6tables -t mangle -F V2RAY6_EXCLUDE 2>/dev/null || true
	ip6tables -t mangle -N DIVERT6 2>/dev/null || true
	ip6tables -t mangle -F DIVERT6 2>/dev/null || true
	[ -n "$MARK" ] && ip6tables -t mangle -A DIVERT6 -j MARK --set-mark "$MARK"
	ip6tables -t mangle -A DIVERT6 -j ACCEPT
	
	# 排除常见 IPv6 保留/本地段
	for subnet6 in \
		::1/128 fe80::/10 fc00::/7 ff00::/8; do
		ip6tables -t mangle -A V2RAY6_EXCLUDE -d "$subnet6" -j RETURN
	done
	[ -n "$LOCAL_SUBNET6" ] && ip6tables -t mangle -A V2RAY6_EXCLUDE -d "$LOCAL_SUBNET6" -j RETURN
	
	ip6tables -t mangle -A V2RAY6_EXCLUDE -j V2RAY6
	
	# 可选日志
	if [ -n "$LOG_PREFIX" ]; then
		ip6tables -t mangle -A V2RAY6 -m limit --limit 10/min -j LOG --log-prefix "$LOG_PREFIX " --log-level 6 2>/dev/null || true
	fi
	
	# TCP/UDP TPROXY（IPv6）
	[ -n "$TPROXY_PORT" ] && [ -n "$MARK" ] && ip6tables -t mangle -A V2RAY6 -p tcp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
	if [ "${ENABLE_UDP:-0}" = "1" ] && [ -n "$TPROXY_PORT" ] && [ -n "$MARK" ]; then
		# 先排除关键UDP端口，避免网络问题（IPv6）
		if [ -n "${UDP_EXCLUDE_PORTS:-}" ]; then
			# 使用兼容性更好的方式解析端口列表
			OLD_IFS="$IFS"
			IFS=','
			set -- $UDP_EXCLUDE_PORTS
			IFS="$OLD_IFS"
			for port in "$@"; do
				[ -n "$port" ] && ip6tables -t mangle -A V2RAY6 -p udp --dport "$port" -j RETURN
			done
		fi
		
		# UDP智能分流：国内IP直连，国外IP走代理（IPv6）
		# 改进的条件判断：先检查ipset命令，再检查集合存在性
		if command -v ipset >/dev/null 2>&1; then
			# ipset命令可用，检查集合是否存在
			if ipset list "$CHN_IPSET6" >/dev/null 2>&1; then
				# 国内IP直连（不走代理）
				ip6tables -t mangle -A V2RAY6 -p udp -m set --match-set "$CHN_IPSET6" dst -j RETURN
				# 国外IP走代理
				ip6tables -t mangle -A V2RAY6 -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
			else
				# ipset命令可用但集合不存在，降级处理
				echo "WARN: ipset 集合 $CHN_IPSET6 不存在，IPv6 UDP 智能分流已降级为全代理模式" >&2
				ip6tables -t mangle -A V2RAY6 -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
			fi
		else
			# ipset命令不可用，降级处理
			echo "WARN: ipset 命令不可用，IPv6 UDP 智能分流已降级为全代理模式" >&2
			ip6tables -t mangle -A V2RAY6 -p udp -j TPROXY --tproxy-mark "$MARK" --on-port "$TPROXY_PORT"
		fi
	fi
	
	# 挂载到 PREROUTING（IPv6，在 chinadns-ng 规则之后）
	ip6tables -t mangle -I PREROUTING 3 -j V2RAY6_EXCLUDE
fi

# 策略路由：fwmark -> table（IPv4，IPv6 路由策略需另行按需配置）
if [ -n "$MARK" ] && [ -n "$ROUTE_TABLE" ]; then
	# 防御：局域网目的走 main，避免本机输出流量误入 TPROXY 表
	[ -n "$LOCAL_SUBNET" ] && {
		ip rule del to "$LOCAL_SUBNET" lookup main 2>/dev/null
		ip rule add pref 99 to "$LOCAL_SUBNET" lookup main 2>/dev/null
	}
	ip rule del fwmark "$MARK" table "$ROUTE_TABLE" 2>/dev/null
	ip route flush table "$ROUTE_TABLE" 2>/dev/null
	ip rule add pref 100 fwmark "$MARK" lookup "$ROUTE_TABLE" 2>/dev/null
	ip route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null
fi

exit 0
EOF
	chmod 755 "$FW_INCLUDE" || true
	ok "写入 $FW_INCLUDE"
}

register_fw_include() {
	# 避免重复添加 include
	if uci show firewall 2>/dev/null | grep -q "firewall\.@include\[[0-9]\+\]\.path='/etc/firewall.v2ray'"; then
		ok "Firewall include 已存在"
	else
		say "注册 firewall include..."
		uci add firewall include >/dev/null
		uci set firewall.@include[-1].type='script'
		uci set firewall.@include[-1].path='/etc/firewall.v2ray'
		uci set firewall.@include[-1].reload='1'
		uci set firewall.@include[-1].enabled='1'
		uci commit firewall
		ok "已注册 firewall include"
	fi

	# 重新加载防火墙
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
	ok "Firewall 已重载"
}

cleanup_old_service() {
	# 停用并移除旧的 init 方式（如果存在）
	if [ -x /etc/init.d/v2ray-tproxy ]; then
		/etc/init.d/v2ray-tproxy stop >/dev/null 2>&1 || true
		/etc/init.d/v2ray-tproxy disable >/dev/null 2>&1 || true
		ok "已停用旧 init 服务 v2ray-tproxy"
	fi
}

verify() {
	# 加载配置以便显示更准确的信息
	[ -f "$CONFIG_DST" ] && . "$CONFIG_DST"
	say "${BLUE}[VERIFY] 规则与路由状态...${NC}"
	
	# 检查 chinadns-ng ipset 集合
	say "[VERIFY] chinadns-ng ipset 集合状态:"
	if command -v ipset >/dev/null 2>&1; then
		# 从配置文件读取集合名称，兼容默认值
		CHN_IPSET4="${CHN_IPSET4:-chnip}"
		CHN_IPSET6="${CHN_IPSET6:-chnip6}"
		GFW_IPSET4="${GFW_IPSET4:-gfwip}"
		GFW_IPSET6="${GFW_IPSET6:-gfwip6}"
		
		for set in "$CHN_IPSET4" "$CHN_IPSET6" "$GFW_IPSET4" "$GFW_IPSET6"; do
			if ipset list "$set" >/dev/null 2>&1; then
				count=$(ipset list "$set" | grep -c "^[0-9]" || echo "0")
				say "  $set: 存在 ($count 个IP)"
			else
				say "  $set: 不存在"
			fi
		done
	else
		say "  ipset 命令不可用"
	fi
	
	# 检查 chinadns-ng iptables 规则
	say "[VERIFY] chinadns-ng iptables 规则:"
	iptables -t mangle -L PREROUTING -n --line-numbers | grep -E 'CHINADNS|chinadns' | head -10 | sed 's/^/[chinadns] /' || say "  未找到 chinadns-ng 规则"
	
	say "[VERIFY] v2ray-tproxy iptables 规则:"
	iptables-save 2>/dev/null | grep -E 'mangle|V2RAY|DIVERT' | sed 's/^/[iptables] /' | head -n 100 || true
	say "[VERIFY] iptables -t mangle -S (完整顺序)"
	iptables -t mangle -S 2>/dev/null | sed 's/^/[mangle-S] /' | head -n 120 || true
	say "[VERIFY] mangle/V2RAY (简表)"
	iptables -t mangle -L V2RAY -v -n 2>/dev/null | sed 's/^/[mangle] /' | head -n 50 || true
	if [ "${ENABLE_IPV6:-0}" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
		say "[VERIFY] ip6tables-save (grep V2RAY6|DIVERT6)"
		ip6tables-save 2>/dev/null | grep -E 'mangle|V2RAY6|DIVERT6' | sed 's/^/[ip6tables] /' | head -n 100 || true
		say "[VERIFY] ip6tables -t mangle -S (完整顺序)"
		ip6tables -t mangle -S 2>/dev/null | sed 's/^/[mangle6-S] /' | head -n 120 || true
	fi
	say "[VERIFY] ip rules"
	ip rule show | sed 's/^/[rule] /'
	if [ -n "$ROUTE_TABLE" ]; then
		say "[VERIFY] ip route table $ROUTE_TABLE"
		ip route show table "$ROUTE_TABLE" | sed 's/^/[route] /'
	fi
	[ -n "$TPROXY_PORT" ] && ss -ulntp 2>/dev/null | grep -w ":${TPROXY_PORT}\b" | sed 's/^/[listen] /' || true
	ok "验证输出完成（请检查上述输出）"
}

main() {
	require_root
	install_config
	precheck
	check_after_config
	write_fw_include
	register_fw_include
	cleanup_old_service
	verify
	say "${GREEN}[SUCCESS] 安装完成。${NC}"
	say "可通过编辑 $CONFIG_DST 后执行：/etc/init.d/firewall reload 使配置生效。"
	say "注意：请确保 chinadns-ng 已启动并创建了相应的 ipset 集合。"
	say "建议：在 chinadns-ng 启动后，运行 /etc/chinadns-ng/ipset/ipset-persist.sh save 保存配置。"
}

main "$@" 