#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY & nicepass

# =================================================================
# 1. 源码路径自动识别与定位（兼容本地、Actions 及多架构目录结构）
# =================================================================
WRT_DIR=""
if [ -n "$GITHUB_WORKSPACE" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	WRT_DIR="$GITHUB_WORKSPACE/wrt"
elif [ -d "/mnt/build_wrt/package" ]; then
	WRT_DIR="/mnt/build_wrt"
elif [ -d "package" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "openwrt/package" ]; then
	WRT_DIR="$(pwd)/openwrt"
elif [ -d "../package" ]; then
	WRT_DIR="$(cd .. && pwd)"
fi

if [ -n "$WRT_DIR" ]; then
	echo "========================================="
	echo "Located OpenWrt Source Root at: $WRT_DIR"
	echo "========================================="
	cd "$WRT_DIR" || exit 1
else
	echo "Warning: Could not locate OpenWrt source root directory!"
fi

PKG_PATH="$WRT_DIR/package"
FEEDS_DIR="$WRT_DIR/feeds"
FILES_DIR="$WRT_DIR/files"
TARGET_DIR="$WRT_DIR/target"

# =================================================================
# 2. 预置 HomeProxy 规则与 Dashboard 数据
# =================================================================
hp_preset_resources() (
	local HP_DIR="$1"
	RESOURCES_DIR="$HP_DIR/root/etc/homeproxy/resources"
	DASHBOARD_DIR="$HP_DIR/root/etc/homeproxy/dashboard"

	GEOIP_SOURCE="${GEOIP_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs}"
	GEOIP_VERSION_URL="${GEOIP_VERSION_URL:-https://github.com/SagerNet/sing-geoip/releases/latest}"
	GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs}"
	GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/SagerNet/sing-geosite/releases/latest}"
	DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
	DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
	USER_AGENT="${USER_AGENT:-HomeProxy resource preset}"

	TMP_DIR="$(mktemp -d)" || {
		echo "Failed to prepare temporary resource directory." >&2
		return 1
	}
	DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
	trap 'rm -rf -- "$TMP_DIR" "$DASHBOARD_STAGE" "$RESOURCES_DIR/.update.$$.tmp"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	warn() {
		echo "WARNING: $*" >&2
	}

	fetch_release_version() {
		local effective_url version
		effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" -o /dev/null -w '%{url_effective}' "$1")" || return 1
		version="${effective_url##*/}"
		case "$version" in
			''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	fetch_dashboard_version() {
		local feed version
		feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" "$DASHBOARD_VERSION_URL")" || return 1
		version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
			/<updated>/ {
				version = $3
				gsub(/[-:TZ]/, "", version)
				print version
				exit
			}
		')"
		case "$version" in
			??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
			*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	download() {
		curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
			--connect-timeout 10 --max-time 60 -A "$USER_AGENT" -o "$2" "$1" &&
			test -s "$2"
	}

	validate_rule_set() {
		# Download checks cover transfer errors; only check the SRS envelope here.
		[[ "$(head -c 3 "$1" 2>/dev/null)" == SRS && $(wc -c < "$1") -gt 4 ]]
	}

	versioned_url() {
		case "$1" in
		http://*|https://*) printf '%s?v=%s' "$1" "$2" ;;
		*) printf '%s' "$1" ;;
		esac
	}

	install_rule_set() {
		local source_file="$1" version="$2" resource="$3"
		local stage_dir="$RESOURCES_DIR/.update.$$.tmp"

		mkdir -p "$stage_dir" &&
			cp "$source_file" "$stage_dir/$resource.srs" &&
			printf '%s\n' "$version" > "$stage_dir/$resource.ver" &&
			chmod 0644 "$stage_dir/$resource.srs" "$stage_dir/$resource.ver" &&
			mv -f "$stage_dir/$resource.srs" "$RESOURCES_DIR/$resource.srs" &&
			mv -f "$stage_dir/$resource.ver" "$RESOURCES_DIR/$resource.ver"
	}

	update_rule_set() {
		local resource="$1" source_url="$2" version_url="$3"
		local version old_version

		version="$(fetch_release_version "$version_url")" || return 1
		old_version="$(cat "$RESOURCES_DIR/$resource.ver" 2>/dev/null)"
		if [ "$old_version" = "$version" ] && validate_rule_set "$RESOURCES_DIR/$resource.srs"; then
			echo "HomeProxy resources: $resource $version (current)"
			return 0
		fi
		download "$(versioned_url "$source_url" "$version")" "$TMP_DIR/$resource.srs" &&
			validate_rule_set "$TMP_DIR/$resource.srs" &&
			install_rule_set "$TMP_DIR/$resource.srs" "$version" "$resource" || return 1
		echo "HomeProxy resources: $resource $version"
	}

	update_dashboard() {
		local version old_version index source_dir=""
		local backup_dir="${DASHBOARD_DIR}.old.$$"

		version="$(fetch_dashboard_version)" || return 1
		old_version="$(cat "$DASHBOARD_DIR/dashboard.ver" 2>/dev/null)"
		if [ "$old_version" = "$version" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
			echo "HomeProxy dashboard: $version (current)"
			return 0
		fi
		download "$(versioned_url "$DASHBOARD_SOURCE" "$version")" "$TMP_DIR/dashboard.zip" &&
			unzip -q "$TMP_DIR/dashboard.zip" -d "$TMP_DIR/dashboard" || return 1
		for index in "$TMP_DIR/dashboard/index.html" "$TMP_DIR"/dashboard/*/index.html; do
			if [ -s "$index" ]; then
				source_dir="${index%/index.html}"
				break
			fi
		done
		[ -n "$source_dir" ] || return 1
		mkdir -p "$DASHBOARD_STAGE" &&
			cp -a "$source_dir/." "$DASHBOARD_STAGE/" &&
			rm -f "$DASHBOARD_STAGE/.etag" &&
			printf '%s\n' "$version" > "$DASHBOARD_STAGE/dashboard.ver" &&
			chmod -R a+rX "$DASHBOARD_STAGE" || return 1
		mv "$DASHBOARD_DIR" "$backup_dir" || return 1
		if ! mv "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
			mv "$backup_dir" "$DASHBOARD_DIR" || warn "Unable to restore the dashboard; backup retained at $backup_dir."
			return 1
		fi
		rm -rf "$backup_dir"
		echo "HomeProxy dashboard: $version"
	}

	mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR" || return 1
	update_failed=0
	if ! update_rule_set geoip_cn "$GEOIP_SOURCE" "$GEOIP_VERSION_URL"; then
		warn "Failed to update HomeProxy geoip resource; continuing."
		update_failed=1
	fi
	if ! update_rule_set geosite_cn "$GEOSITE_SOURCE" "$GEOSITE_VERSION_URL"; then
		warn "Failed to update HomeProxy geosite; continuing."
		update_failed=1
	fi
	if ! update_dashboard; then
		warn "Failed to update HomeProxy dashboard; continuing."
		update_failed=1
	fi

	return "$update_failed"
)

HP_DIR="$(find "$PKG_PATH" -maxdepth 3 -type d -iname '*homeproxy*' -print -quit 2>/dev/null)"
if [ -n "$HP_DIR" ]; then
	echo " "
	if hp_preset_resources "$HP_DIR"; then
		echo "homeproxy data has been updated!"
	else
		echo "homeproxy resource preset completed with errors; continuing!"
	fi
fi

# =================================================================
# 2b. 预置 ndisc6 源码（上游 remlab.net 已全部 410 Gone）
# =================================================================
# 背景：QModem 的 application/ndisc6 用 PKG_VERSION=1.0.2、
# PKG_SOURCE_URL=http://www.remlab.net/files/ndisc6，且**没有 PKG_HASH**。
# 该站点现在对 1.0.2 / 1.0.3 / 1.0.4 一律返回 410 Gone，OpenWrt 与
# ImmortalWrt 的 sources 镜像也都没有这个文件（实测全部 404 / 403），
# 于是 make download 把所有镜像遍历一遍后失败，CPE 目标在编译阶段挂掉：
#   make[3]: *** [Makefile:96: .../dl/ndisc6-1.0.2.tar.bz2] Error 2
#   ERROR: package/feeds/qmodem/ndisc6 failed to build.
#
# 不能简单把 QModem 的 ndisc6 choice 关掉：modem_dial.sh 在 IPv4v6 双栈
# 拨号时会调用 `rdisc6 $origin_device &` / `ndisc6 fe80::1 $origin_device &`
# 主动触发 IPv6 路由/邻居发现。
#
# 方案：用 web.archive.org 的原始文件快照预置到 dl/，让 make download 直接命中。
#   注意 URL 必须带 id_ 后缀，否则返回的是带工具栏的 HTML 页面，tar 解不开。
# 只在装了 qmodem feed 的目标（CPE）执行，其他目标完全不受影响。
if [ -d "$FEEDS_DIR/qmodem" ]; then
	NDISC6_VER="1.0.2"
	NDISC6_DL="$WRT_DIR/dl/ndisc6-${NDISC6_VER}.tar.bz2"
	NDISC6_URL="https://web.archive.org/web/2020id_/https://www.remlab.net/files/ndisc6/ndisc6-${NDISC6_VER}.tar.bz2"
	# 实测下载验证过的 SHA256（239249 字节，bzip2 tar，顶层目录 ndisc6-1.0.2/，102 个条目）
	NDISC6_SHA="6acec8a0cb9efa3ac98456f46c3016aeec0598b0c7557c95242b5228ad62ca7a"
	if [ -s "$NDISC6_DL" ]; then
		echo "ndisc6 ${NDISC6_VER} already present in dl/, skip seeding."
	else
		mkdir -p "$WRT_DIR/dl"
		echo "ndisc6: upstream remlab.net is 410 Gone, seeding from web.archive.org ..."
		if curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
			-o "$NDISC6_DL" "$NDISC6_URL"; then
			GOT_SHA=$(sha256sum "$NDISC6_DL" | cut -d' ' -f1)
			if [ "$GOT_SHA" = "$NDISC6_SHA" ]; then
				echo "ndisc6: seeded OK (sha256 verified)."
			else
				echo "WARNING: ndisc6 sha256 mismatch ($GOT_SHA != $NDISC6_SHA), discarding."
				rm -f "$NDISC6_DL"
			fi
		else
			echo "WARNING: ndisc6 seeding failed; ndisc6/rdisc6 download will fail later."
		fi
	fi
fi

# =================================================================
# 2c. 预置 honk-core 预编译二进制（绕过上游的 zig 现场编译）
# =================================================================
# 背景：honk 上游从 2026.11.03 起把 honk/Makefile 的 Build/Compile 改成
#
#     "$(CURDIR)/build_honk_core.sh" --if-needed "$(ARCH)" "$(CURDIR)/files/honk-core.bin"
#     $(INSTALL_BIN) "$(CURDIR)/files/honk-core.bin" "$(PKG_INSTALL_DIR)/bin/honk-core"
#
# 该脚本用 zig 交叉编译 Rust + eBPF，要求 PATH 里有 zig / bpf-linker / cargo，
# zig 版本还需与上游 pins.env 精确相等，另加 rustup+nightly+rust-src+llvm-tools。
# GitHub runner 上这些都没有，于是每个目标都报 ERROR: zig not found in PATH。
#
# 曾经的做法是把 Packages.sh 里的 honk 固定到 honk_415.3_pre1-r1（旧版走预编译
# tarball）。但上游几小时后把该 tag 和 release 一并删除了，clone 直接报
# `Remote branch honk_415.3_pre1-r1 not found in upstream origin` —— 固定 tag
# 不可靠，上游随时会清。上游保留了每个 release 的 ipk/apk（内含预编译
# honk-core），所以改为：从最新 release 的 ipk 里取出静态二进制，放到
# files/honk-core.bin，并且【不放 .stamp】。
#
# build_honk_core.sh 的逻辑是 --if-needed 时若 bin 存在且【无 stamp】就直接
# `using prebuilt honk-core (no stamp)` 并 exit 0，随后 Makefile 把这个 bin
# 安装到 /usr/bin/honk-core —— 整条 zig/rust 链路被跳过。
#
# 另一个上游缺陷顺带修掉：该脚本的 arch 白名单只有
#   aarch64 | aarch64_generic | x86_64
# 而 ipq60xx 等目标是 aarch64_cortex-a53，且这个 case 检查排在 prebuilt 判断
# 【之前】，不先放宽的话即使预置了 bin 也会在 case 处 exit 1。
HONK_PKG_DIR="$(find "$PKG_PATH" -maxdepth 2 -type d -name honk -print -quit 2>/dev/null)"
if [ -n "$HONK_PKG_DIR" ] && [ -f "$HONK_PKG_DIR/build_honk_core.sh" ]; then
	echo "honk: upstream builds core via zig (absent on runner), seeding prebuilt binary"

	if grep -q '^  aarch64|aarch64_generic|aarch64-unknown-linux-musl)$' "$HONK_PKG_DIR/build_honk_core.sh" 2>/dev/null; then
		sed -i 's#^  aarch64|aarch64_generic|aarch64-unknown-linux-musl)$#  aarch64|aarch64_*|aarch64-unknown-linux-musl)#' \
			"$HONK_PKG_DIR/build_honk_core.sh"
		echo "honk: relaxed build_honk_core.sh arch match to accept aarch64_*"
	fi

	# 注意：上游 2026-11-08 起改了 asset 命名——arch 段从
	#   honk-<ver>-aarch64_generic-aarch64_generic-openwrt-24.10.x.ipk
	# 变成
	#   honk_<ver>_aarch64_generic-openwrt-24.10.8.ipk
	# 即重复的 arch 名塌缩成一个。用单名匹配可同时兼容新旧两种写法
	# （jq contains 是子串匹配，旧名的 -arch-arch 也包含单个 arch）。
	# 若写成 aarch64_generic-aarch64_generic 则新命名一个都匹配不上，
	# url 变 <none>，退回 zig 现场编译，最终 Compile Firmware 失败。
	case "${WRT_TARGET:-}" in
		x86) HONK_ASSET_ARCH="x86_64" ;;
		*)   HONK_ASSET_ARCH="aarch64_generic" ;;
	esac

	HONK_BIN="$HONK_PKG_DIR/files/honk-core.bin"
	rm -f "$HONK_BIN.stamp"      # 有 stamp 会强制重新编译，必须清掉

	if [ -s "$HONK_BIN" ]; then
		echo "honk: prebuilt honk-core already present, skip seeding"
	else
		# luci-app-honk 是 public 仓库，匿名读 API 即可（限额 60 次/小时，
		# 本流程只查一次）。优先匿名：Actions 的 GITHUB_TOKEN 只对当前仓库
		# 有权限，带上去查第三方仓库反而是噪音；仅在匿名失败（限流）时才
		# 用 token 兜底重试。
		HONK_API="https://api.github.com/repos/QiuSimons/luci-app-honk/releases/latest"
		HONK_JSON="$(curl -fsSL --max-time 60 \
			-H "Accept: application/vnd.github+json" "$HONK_API" 2>/dev/null)"
		if [ -z "$HONK_JSON" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
			echo "honk: anonymous API call returned nothing, retrying with token"
			HONK_JSON="$(curl -fsSL --max-time 60 \
				-H "Authorization: Bearer ${GITHUB_TOKEN}" \
				-H "Accept: application/vnd.github+json" "$HONK_API" 2>/dev/null)"
		fi
		HONK_URL="$(printf '%s' "$HONK_JSON" \
			| jq -r --arg a "$HONK_ASSET_ARCH" \
			  '.assets[]? | select(.name | test("-openwrt-[0-9.]+\\.ipk$")) | select(.name | contains($a)) | .browser_download_url' \
			2>/dev/null | head -n1)"

		HONK_TMP="$(mktemp -d)"
		if [ -n "$HONK_URL" ] && \
		   curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
		     -o "$HONK_TMP/honk.ipk" "$HONK_URL"; then
			# OpenWrt 24.10 起的 ipk 是 gzip 压缩的 tar（含 debian-binary /
			# data.tar.gz / control.tar.gz），不是老的 ar 归档，不能用 ar x。
			# 注意成员名带 './' 前缀（./debian-binary、./data.tar.gz），
			# 全量解出后按相对路径引用，避免按成员名精确匹配踩空。
			tar xzf "$HONK_TMP/honk.ipk" -C "$HONK_TMP" 2>/dev/null
			[ -f "$HONK_TMP/data.tar.gz" ] && \
				tar xzf "$HONK_TMP/data.tar.gz" -C "$HONK_TMP" ./usr/bin/honk-core 2>/dev/null
			if [ -s "$HONK_TMP/usr/bin/honk-core" ]; then
				cp -f "$HONK_TMP/usr/bin/honk-core" "$HONK_BIN"
				chmod +x "$HONK_BIN"
				echo "honk: seeded $(du -h "$HONK_BIN" | cut -f1) honk-core from $(basename "$HONK_URL")"
				echo "honk: sha256 $(sha256sum "$HONK_BIN" | cut -d' ' -f1)"
			else
				echo "WARNING: honk-core not found inside downloaded ipk"
			fi
		else
			echo "WARNING: failed to fetch honk ipk (url='${HONK_URL:-<none>}'); build will fail at the zig check"
			# 诊断增强：把上游实际提供的 asset 列出来，这样下次命名再变时
			# 能直接从 CI 日志看出该改哪个匹配串，不必再翻 API。
			echo "honk: 期望 arch='$HONK_ASSET_ARCH'，上游 release 实际提供："
			printf '%s' "$HONK_JSON" \
			  | jq -r '.assets[]?.name' 2>/dev/null | sed 's/^/  honk:   /' | head -20
		fi
		rm -rf "$HONK_TMP"
	fi
fi

# =================================================================
# 3. 主题与 UI 界面定制
# =================================================================
# 修改 argon 主题字体和颜色
ARGON_CONF="$(find "$PKG_PATH" -type f -path "*/luci-app-argon-config/root/etc/config/argon" -print -quit 2>/dev/null)"
if [ -f "$ARGON_CONF" ]; then
	sed -i "s/primary '.*'/primary '#31a1a1'/g; s/'0.2'/'0.5'/g; s/'none'/'bing'/g; s/'600'/'normal'/g" "$ARGON_CONF" && \
		echo "theme-argon has been customized!"
fi

# 修改 aurora 菜单式样
if [ -d "$PKG_PATH/luci-app-aurora-config" ]; then
	find "$PKG_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} + 2>/dev/null && \
		echo "theme-aurora has been customized!"
fi

# 修改 mini-diskmanager 菜单位置
DISKMAN_JSON="$(find "$PKG_PATH" -type f -name "luci-app-mini-diskmanager.json" -print -quit 2>/dev/null)"
if [ -f "$DISKMAN_JSON" ]; then
	sed -i "s/services/system/g" "$DISKMAN_JSON" && echo "mini-diskmanager has been moved to System menu!"
fi

# =================================================================
# 4. Tailscale & sing-box 启动脚本与 Makefile 兼容配置
# =================================================================
echo "Applying Tailscale & sing-box compatibility fixes..."
mkdir -p "$FILES_DIR/etc/config" "$FILES_DIR/etc/init.d" "$FILES_DIR/etc/rc.d" "$FILES_DIR/etc/uci-defaults"

# =================================================================
# BBR 官方推荐组合: fq 队列调度 + bbr 拥塞控制
# =================================================================
# bbr 部分由 kmod-tcp-bbr 包自动完成（自带 /etc/sysctl.d/12-tcp-bbr.conf
# 且 AUTOLOAD 自动加载 tcp_bbr 模块），此处仅补 fq 队列调度。
# fq 由 kmod-sched 包提供的 sch_fq.ko 实现，需在 GENERAL.txt 中启用
# CONFIG_PACKAGE_kmod-sched=y。
# 文件名用 99- 前缀，确保在 sysctl.d 中按字典序最后加载，避免被覆盖。
mkdir -p "$FILES_DIR/etc/sysctl.d"
echo "net.core.default_qdisc=fq" > "$FILES_DIR/etc/sysctl.d/99-default-qdisc.conf"
echo "fq qdisc (BBR recommended) preset applied!"

cat > "$FILES_DIR/etc/config/tailscale" << 'EOF'
config tailscale 'main'
	option enabled '1'
	option port '41641'
	option fw_mode 'nftables'
	option config_path '/etc/tailscale'

config settings
	option service_enabled '1'
	option log_stdout '1'
	option log_stderr '1'
EOF

cat > "$FILES_DIR/etc/init.d/tailscale" << 'EOF'
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1
PROGD=/usr/sbin/tailscaled

start_service() {
    config_load tailscale
    local enabled fw_mode port config_path
    
    config_get_bool enabled 'main' enabled 1
    config_get fw_mode 'main' fw_mode 'nftables'
    config_get port 'main' port '41641'
    config_get config_path 'main' config_path '/etc/tailscale'

    [ "$enabled" -eq 0 ] && return 0

    mkdir -p /var/run/tailscale
    mkdir -p "$config_path"

    $PROGD --cleanup
    procd_open_instance
    # 【关键 1】用 `env` 命令在命令行前缀注入环境变量，而不是依赖 procd 的 env。
    # 原因：procd 的 `procd_set_param env` 是「设置整个 env 列表」而非追加
    # （procd.sh 的 _procd_add_table 每次都 json_add_object 一个同名 object，
    #  procd 解析时后者覆盖前者）。曾在同一 instance 内连续调用两次：
    #     procd_set_param env TS_DEBUG_FIREWALL_MODE="$fw_mode"
    #     procd_set_param env TS_NO_LOGS_NO_SUPPORT=true
    # 结果前者被后者整个覆盖，TS_DEBUG_FIREWALL_MODE 丢失。
    # 后果取决于 tailscale 版本：
    #   - 1.80.3（如 24.10 feed）：回落到默认 iptables 模式，而本固件只有
    #     nftables、没有 iptables 命令 → 启动即崩（procd crash loop）：
    #       wgengine.NewUserspaceEngine(tun "tailscale0") error:
    #         router.Up: setting netfilter mode:
    #         exec: "iptables": executable file not found in $PATH
    #   - 1.102.3（如 25.12 feed）：新版能自行检测并降级到 nftables，暂不显形，
    #     但我们仍丧失了对防火墙模式的显式控制。
    # 命令行 env 前缀不受 procd 行为影响，故作为首选方式。
    procd_set_param command /usr/bin/env \
        TS_DEBUG_FIREWALL_MODE="$fw_mode" \
        TS_NO_LOGS_NO_SUPPORT=true \
        $PROGD \
        --port "$port" \
        --state "$config_path/tailscaled.state" \
        --socket /var/run/tailscale/tailscaled.sock

    # 【关键 2】procd 的 env 也一并设置（双重保险），但必须一次调用传全部变量，
    # 绝不可拆成多次 procd_set_param env（会互相覆盖，见上）。
    procd_set_param env \
        TS_DEBUG_FIREWALL_MODE="$fw_mode" \
        TS_NO_LOGS_NO_SUPPORT=true

    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    $PROGD --cleanup
    rm -rf /var/run/tailscale
}
EOF
chmod +x "$FILES_DIR/etc/init.d/tailscale"

ln -sf ../init.d/tailscale "$FILES_DIR/etc/rc.d/S95tailscale"

cat > "$FILES_DIR/etc/uci-defaults/99-force-tailscale" << 'EOF'
#!/bin/sh
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
exit 0
EOF
chmod +x "$FILES_DIR/etc/uci-defaults/99-force-tailscale"

# 修复 Tailscale Makefile
# 上游 install 段会装 ./files//tailscale.init 与 ./files//tailscale.conf
# （注意双斜杠），而本脚本下方已自行生成 /etc/init.d/tailscale 与
# /etc/config/tailscale，两者会冲突。此处删除上游那两行，让自定义版本生效。
# 日志会打印实际命中与否，避免静默空转：
#   "patched"    = 找到并删除了上游行
#   "already ok" = 上游已无该行（幂等，可能上游已改）
for TS_FILE in $(find "$PKG_PATH" "$FEEDS_DIR" -type f -path "*/tailscale/Makefile" 2>/dev/null); do
	[ -f "$TS_FILE" ] || continue
	if grep -q '/files' "$TS_FILE"; then
		sed -i '/\/files/d' "$TS_FILE"
		echo "tailscale Makefile patched (removed upstream ./files install lines): $TS_FILE"
	else
		echo "tailscale Makefile already ok (no ./files lines): $TS_FILE"
	fi
done

# 修复 luci-app-tailscale-community 的未声明变量
# 上游 748a6af 重构设备表格时误删了两个声明，导致前端抛 ReferenceError：
#   - lastDevicesStatus: 过滤框输入时触发
#   - peerTableHeaders:  渲染设备表格表头时触发
for TS_VIEW in $(find "$PKG_PATH" "$FEEDS_DIR" -type f -path "*/resources/view/tailscale.js" 2>/dev/null); do
	[ -f "$TS_VIEW" ] || continue

	# 1) lastDevicesStatus：在 "let map;" 后注入声明
	# 上游 d9a3954 已补回该声明，正常情况下此处为幂等跳过；
	# 跳过时也打印日志，以免与"从未执行"混淆。
	if ! grep -q 'let lastDevicesStatus' "$TS_VIEW"; then
		if grep -q '^let map;' "$TS_VIEW"; then
			sed -i 's/^let map;/let map;\nlet lastDevicesStatus = null;/' "$TS_VIEW" && \
				echo "tailscale.js: lastDevicesStatus declaration injected! ($TS_VIEW)"
		else
			echo "warning: tailscale.js: lastDevicesStatus injection point not found; skipping ($TS_VIEW)"
		fi
	else
		echo "tailscale.js: lastDevicesStatus already present, skip (upstream ok): $TS_VIEW"
	fi

	# 2) peerTableHeaders：在 "let map;" 后注入完整表头定义（8 列，与 renderPeerRows 对齐）
	if ! grep -q 'const peerTableHeaders' "$TS_VIEW"; then
		if grep -q '^let map;' "$TS_VIEW"; then
			sed -i '/^let map;/a\
const peerTableHeaders = [\
	{ text: _('"'"'Status'"'"'), style: '"'"'width: 80px;'"'"' },\
	{ text: _('"'"'Hostname'"'"') },\
	{ text: _('"'"'Tailscale IP'"'"') },\
	{ text: _('"'"'OS'"'"') },\
	{ text: _('"'"'Connection Info'"'"') },\
	{ text: _('"'"'RX'"'"') },\
	{ text: _('"'"'TX'"'"') },\
	{ text: _('"'"'Last Seen'"'"') }\
];' "$TS_VIEW" && \
				echo "tailscale.js: peerTableHeaders declaration injected! ($TS_VIEW)"
		else
			echo "warning: tailscale.js: peerTableHeaders injection point not found; skipping ($TS_VIEW)"
		fi
	else
		echo "tailscale.js: peerTableHeaders already present, skip (upstream ok): $TS_VIEW"
	fi
done

# 修复 sing-box Makefile，注入 Build/Prepare 钩子
for SB_FILE in $(find "$PKG_PATH" "$FEEDS_DIR" -type f -path "*/sing-box/Makefile" 2>/dev/null); do
	if [ -f "$SB_FILE" ]; then
		echo "Injecting Build/Prepare hook into sing-box Makefile: $SB_FILE"
		sed -i '/define Build\/Prepare/,/endef/d' "$SB_FILE"
		cat << 'EOF' >> "$SB_FILE"

define Build/Prepare
	$(call Build/Prepare/Default)
	find $(PKG_BUILD_DIR) -type f -name "*.go" -exec sed -i '/go:linkname.*connPool/d' {} + 2>/dev/null || true
	find $(PKG_BUILD_DIR) -type f -name "*.go" -exec sed -i '/func ResetTransport/,/^}/c\func ResetTransport(t *http2.Transport) {}' {} + 2>/dev/null || true
endef
EOF
	fi
done

# =================================================================
# 5. 语言与编译器修复 (Rust & Golang 工具链钩子)
# =================================================================
# 修复 Rust 编译
RUST_FILE="$(find "$FEEDS_DIR/packages" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE" 2>/dev/null && echo "rust has been fixed!"
fi

# 从官方 master 提取最新 Golang 并解除本地锁死 (GOTOOLCHAIN=auto)
if [ -d "$FEEDS_DIR/packages/lang" ]; then
	echo "Fetching latest Golang from openwrt/packages master branch..."
	rm -rf "$FEEDS_DIR/packages/lang/golang"
	rm -rf "$WRT_DIR/tmp/openwrt-packages-go"

	git clone --depth=1 https://github.com/openwrt/packages.git "$WRT_DIR/tmp/openwrt-packages-go"
	if [ -d "$WRT_DIR/tmp/openwrt-packages-go/lang/golang" ]; then
		mv "$WRT_DIR/tmp/openwrt-packages-go/lang/golang" "$FEEDS_DIR/packages/lang/golang"
		echo "Golang source code replaced successfully."
	fi
	rm -rf "$WRT_DIR/tmp/openwrt-packages-go"

	find "$FEEDS_DIR/packages/lang/golang" -type f -exec sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} + 2>/dev/null || true

	if [ -x "$WRT_DIR/scripts/feeds" ]; then
		"$WRT_DIR/scripts/feeds" install -a golang
	fi
fi

# golang-build.sh 通用编译前置钩子 —— 已禁用
#
# 历史：该钩子向 golang-build.sh 注入两行 sed，用于旧版 sing-box 的 workaround
#   a) 删除含 go:linkname.*connPool 的行
#   b) 把 func ResetTransport 的函数体替换为空实现
# 以及一行破坏性的 go.mod 改写（已在 880583a 移除）。
#
# 为何禁用（实测证据链）：
#   - 该钩子长期从未执行：CI 中 $GITHUB_WORKSPACE/wrt 是指向 /mnt/build_wrt 的
#     符号链接，GNU find 默认不递归进入符号链接起始路径，故 find 返回空。
#   - aecc371 为修此问题加了 find -L，钩子首次真正生效。随即连续两轮全量编译失败：
#       b5dde04: go.mod 被强行写成 go 1.25 + 删除 toolchain 行
#                -> "go: updates to go.mod needed" / "no Go files in .../.go_work/build"
#       880583a: 移除 go.mod 改写后，剩余 ResetTransport 补丁再次破坏源码
#                -> transport/v2rayhttp/force_close_legacy.go:30:6: missing function body
#                （sing-box 1.15.0-alpha.12 以 http2legacy tag 编译该文件，
#                 新版把 ResetTransport 拆分到独立文件，旧的 sed 区间匹配错位，
#                 留下签名删掉函数体）
#   - 反过来看：钩子不生效的那些周里 sing-box 一直编译正常，说明当前版本
#     不需要这些 workaround，上游早已自行处理。
#
# 结论：整体禁用注入。保留 find -L 与循环骨架，便于日后确需时按新版本重写。
for GBS in $(find -L "$WRT_DIR" -type f -name "golang-build.sh" 2>/dev/null); do
	echo "golang-build.sh hook disabled, skipping (upstream workarounds obsolete): $GBS"
	continue
done

# 删除冲突的 ovpn-dco 包
# 注：此处删除已移至 WRT-CORE.yml 的 Update Feeds 步骤（feeds update 之后、
# feeds install 之前）并在删除后重建索引。原因：feeds update 会立即生成
# feeds/packages.index，而 feeds install / defconfig 读的是索引文件；
# 在 Handles.sh（Custom Packages 步骤，晚于 feeds update）里 rm 目录，
# 索引里仍保留 ovpn-dco 条目，故 defconfig 依旧报
# "WARNING: Not overriding core package 'ovpn-dco'; use -f to force"（实测 4 次）。
if [ -d "$FEEDS_DIR/packages/kernel/ovpn-dco" ]; then
	echo "warning: ovpn-dco still present in feed; removal should happen in Update Feeds step"
fi

# =================================================================
# 6. 无线与 5G 模组驱动内核兼容修复 (MT76 / QMI WWAN / Qualcomm NSS)
# =================================================================
# A. 动态修复 MT76 无线驱动适配 Linux 6.18+ mac80211 API (解决静态补丁 Hunk Failed 冲突)
for MT76_MK in $(find "$PKG_PATH" "$FEEDS_DIR" -type f -path "*/kernel/mt76/Makefile" 2>/dev/null); do
	if [ -f "$MT76_MK" ]; then
		echo "Injecting dynamic Prepare hook into mt76 Makefile: $MT76_MK"
		rm -f "$(dirname "$MT76_MK")/patches/999-fix-mac80211-fils-discovery-api.patch"
		sed -i '/define Build\/Prepare/,/endef/d' "$MT76_MK"
		cat << 'EOF' >> "$MT76_MK"

define Build/Prepare
	$(call Build/Prepare/Default)
	find $(PKG_BUILD_DIR) -type f -name "*.c" -exec sed -i 's/ieee80211_get_fils_discovery_tmpl(hw, vif)/ieee80211_get_fils_discovery_tmpl(hw, vif, 0)/g' {} + 2>/dev/null || true
	find $(PKG_BUILD_DIR) -type f -name "*.c" -exec sed -i 's/ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif)/ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif, 0)/g' {} + 2>/dev/null || true
endef
EOF
	fi
done

# B. 批量修复 5G 模块驱动 (Fibocom / Quectel / SIMCom) 适配 Linux 6.6+ u64_stats API
if [ -d "package" ]; then
	echo "Patching all QMI WWAN drivers (qmi_wwan*.c) for Linux 6.6+..."
	find package/ -type f -name "qmi_wwan*.c" -exec sed -i 's/u64_stats_fetch_begin_irq/u64_stats_fetch_begin/g' {} + 2>/dev/null || true
	find package/ -type f -name "qmi_wwan*.c" -exec sed -i 's/u64_stats_fetch_retry_irq/u64_stats_fetch_retry/g' {} + 2>/dev/null || true
fi

# C. 修复高通 IPQ60XX 平台下 NSS ECM 与 QModem RawIP 符号冲突
if [ -d "package/qca-nss/qca-nss-ecm" ]; then
	echo "Patching IPQ60XX qca-nss-ecm for QModem RawIP compatibility..."
	sed -i 's/ECM_INTERFACE_RAWIP_ENABLE=y/ECM_INTERFACE_RAWIP_ENABLE=n/g' package/qca-nss/qca-nss-ecm/Makefile 2>/dev/null || true
	find package/qca-nss/qca-nss-ecm/ -type f -name "Makefile" -exec sed -i 's/ECM_DRIVER_RMNET_ENABLE=y/ECM_DRIVER_RMNET_ENABLE=n/g' {} + 2>/dev/null || true
fi

# =================================================================
# 7. 目标架构级硬件与 DTS 补丁 (DAED / Qualcommax)
# =================================================================
# 针对启用 BTF 的目标自动扩大内核分区，并调整 BRBE
#
# 判定方式改为直接检测目标 Config 是否启用 CONFIG_KERNEL_DEBUG_INFO_BTF=y，
# 而不是靠 target 名字匹配（旧写法 *DAED* 曾漏掉 IPQ60XX-WIFI-NO-DAE 与
# IPQ60XX-WIFI-NO-HONK，因为它们的名字里不含 "DAED"）。这样今后任何新增的
# 启用 BTF 的 target 都会自动扩容，无需再改这里。
#
# 为何需要：开启 CO-RE BTF 后内核镜像实测达 7701276 字节，而设备默认
# KERNEL_SIZE 为 6144k(6291456)，打包阶段直接报：
#   WARNING: Image file .../jdcloud_re-cs-07-uImage.itb is too big: 7701276 > 6291456
#   WARNING: Image file .../jdcloud_re-ss-01-uImage.itb is too big: 7701028 > 6291456
#   ERROR: target/linux failed to build.
# 注意这类超限报错后还会派生 "No such package: ath11k-firmware-*" 等看似无关的
# 错误（打包中断导致后续 step 拿不到产物），排查时应看第一个 WARNING。
#
# re-cs-07 与 re-ss-01 的 flash 布局均留有 12M 内核分区空间，扩到 12288k 安全。
#
# 为何列的是父定义而不是具体设备：link_nn6000-v1 / link_nn6000-v2 都只是
# "$(Device/link_nn6000-common)" 的变体，自身没有 KERNEL_SIZE 行，
# 所以 sed 匹配 "define Device/link_nn6000-v1" 段落时找不到可替换内容、静默无效，
# 导致 v2 仍用父定义的 6144k，打包报：
#   WARNING: Image file .../link_nn6000-v2-uImage.itb is too big: 7758892 > 6291456
#   make[5]: *** [...link_nn6000-v2-squashfs-sysupgrade.bin] Error 1
# 改为 sed 父定义 link_nn6000-common，v1/v2 及今后新增变体一并覆盖。
# link_nn6000-common 走 Device/EmmcImage（eMMC 介质，DTS 无固定分区表），
# KERNEL_SIZE 仅作为 factory.bin 的 pad-to 值，扩到 12M 不动硬件分区，安全。
TARGET_CONFIG_FILE="${GITHUB_WORKSPACE:-}/Config/${WRT_CONFIG}.txt"
if [ -f "$TARGET_CONFIG_FILE" ] && grep -q '^CONFIG_KERNEL_DEBUG_INFO_BTF=y' "$TARGET_CONFIG_FILE" 2>/dev/null; then
	echo "BTF enabled in $WRT_CONFIG, applying 12M kernel partition patch..."
	DAE_DEVICES=("jdcloud_re-cs-07" "jdcloud_re-ss-01" "link_nn6000-common")
	for DEV in "${DAE_DEVICES[@]}"; do
		for MK in ipq60xx.mk ipq807x.mk; do
			[ -f "$TARGET_DIR/linux/qualcommax/image/$MK" ] || continue
			grep -q "define Device/$DEV" "$TARGET_DIR/linux/qualcommax/image/$MK" || continue
			sed -i "/define Device\/$DEV/,/endef/ s/KERNEL_SIZE := .*/KERNEL_SIZE := 12288k/" \
				"$TARGET_DIR/linux/qualcommax/image/$MK"
			echo "  KERNEL_SIZE -> 12288k: $DEV (in $MK)"
		done
	done
	# 校验：确认父定义的 KERNEL_SIZE 确实改到了（sed 静默失效时给出可诊断的告警）
	_found=0; _ok=0
	for MK in ipq60xx.mk ipq807x.mk; do
		MKF="$TARGET_DIR/linux/qualcommax/image/$MK"
		[ -f "$MKF" ] || continue
		grep -q "define Device/link_nn6000-common" "$MKF" || continue
		_found=1
		if grep -A12 "define Device/link_nn6000-common" "$MKF" | grep -q "KERNEL_SIZE := 12288k"; then
			_ok=1
			echo "  VERIFIED: link_nn6000-common KERNEL_SIZE = 12288k (in $MK)"
		fi
	done
	if [ "$_found" -eq 0 ]; then
		echo "  NOTE: link_nn6000-common not in this source tree, skipped."
	elif [ "$_ok" -eq 0 ]; then
		echo "  WARNING: link_nn6000-common KERNEL_SIZE patch did NOT take effect!"
	fi

	if [ -f "$TARGET_DIR/linux/qualcommax/config-6.18" ]; then
		echo "# CONFIG_ARM64_BRBE is not set" >> "$TARGET_DIR/linux/qualcommax/config-6.18"
	fi
	echo "BTF target 12M kernel size & BRBE patch applied successfully!"
else
	echo "BTF not enabled for $WRT_CONFIG (or Config not found), skipping kernel size patch."
fi

# 修复 Linux 6.18 下 qualcommax 全局 DTB 编译报错
if [ -d "$TARGET_DIR/linux/qualcommax" ]; then
	find "$TARGET_DIR/linux/qualcommax/" -type f \( -name "*.dts" -o -name "*.dtsi" -o -name "*.patch" \) | xargs sed -i \
		-e 's/macaddr_lanlan_mac/lan_mac/g' \
		-e 's/macaddr_wanwan_mac/wan_mac/g' \
		-e 's/&macaddr_lan_mac/&lan_mac/g' \
		-e 's/&macaddr_wan_mac/&wan_mac/g' 2>/dev/null || true

	find "$TARGET_DIR/linux/qualcommax/" -type f \( -name "*.dtsi" -o -name "*.dts" \) | xargs sed -i \
		-e '/nvmem-cells = <&macaddr_wan/d' \
		-e '/nvmem-cells = <&macaddr_lan/d' 2>/dev/null || true
	echo "Qualcommax DTS has been fixed!"
fi

# 修复 qualcommax 设备定义引用了已被上游移除的 ath11k 固件包
# 上游 package/firmware/ath11k-firmware/Makefile 现只提供带 -ddwrt 后缀的固件包
# （以及 ipq5018-qcn6122），已移除无后缀的 ath11k-firmware-ipq6018 与
# ath11k-firmware-qcn9074。但 target/linux/qualcommax/image/ipq60xx.mk 中
# jdcloud_re-cs-07 的 DEVICE_PACKAGES 仍在用 "-pkg" 语法排除这两个已不存在的包，
# 导致固件打包阶段报：
#   ERROR: No such package: ath11k-firmware-ipq6018
#   ERROR: No such package: ath11k-firmware-qcn9074
#   make[5]: *** [...-squashfs-sysupgrade.bin] Error 1
#   ERROR: target/linux failed to build.
# 注意：只删除「后面紧跟空格或行尾」的裸包名项，-ddwrt 版本必须保留
# （模式用前瞻断言，避免把 -ath11k-firmware-ipq6018-ddwrt 误伤）。
for IPQ_MK in "$TARGET_DIR/linux/qualcommax/image/ipq60xx.mk" \
               "$TARGET_DIR/linux/qualcommax/image/ipq807x.mk"; do
	[ -f "$IPQ_MK" ] || continue
	if grep -qE '(^|[[:space:]])-ath11k-firmware-(ipq6018|qcn9074)([[:space:]]|$)' "$IPQ_MK"; then
		sed -i -E 's/(^|[[:space:]])-ath11k-firmware-ipq6018([[:space:]]|$)/\1\2/g; s/(^|[[:space:]])-ath11k-firmware-qcn9074([[:space:]]|$)/\1\2/g' "$IPQ_MK"
		echo "ath11k firmware ghost deps removed from $(basename "$IPQ_MK")"
	fi
done
