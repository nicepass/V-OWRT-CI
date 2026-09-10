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
# 3. 主题与 UI 界面定制
# =================================================================
# 修改 argon 主题字体和颜色
ARGON_CONF="$(find "$PKG_PATH" -type f -path "*/luci-app-argon-config/root/etc/config/argon" -print -quit 2>/dev/null)"
if [ -f "$ARGON_CONF" ]; then
	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" "$ARGON_CONF" && \
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
    procd_set_param command $PROGD \
        --port "$port" \
        --state "$config_path/tailscaled.state" \
        --socket /var/run/tailscale/tailscaled.sock
    
    procd_set_param env TS_DEBUG_FIREWALL_MODE="$fw_mode"
    procd_set_param env TS_NO_LOGS_NO_SUPPORT=true
    
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
for TS_FILE in $(find "$PKG_PATH" "$FEEDS_DIR" -type f -path "*/tailscale/Makefile" 2>/dev/null); do
	if [ -f "$TS_FILE" ]; then
		sed -i '/\/files/d' "$TS_FILE"
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

# 向 golang-build.sh 注入通用编译前置拦截钩子
for GBS in $(find "$WRT_DIR" -type f -name "golang-build.sh" 2>/dev/null); do
	echo "Injecting universal source patch hook into: $GBS"
	TMP_GBS="${GBS}.tmp"
	head -n 1 "$GBS" > "$TMP_GBS"
	cat << 'EOF' >> "$TMP_GBS"
if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
	find "$BUILD_DIR" -type f -name "*.go" -exec sed -i '/go:linkname.*connPool/d' {} + 2>/dev/null || true
	find "$BUILD_DIR" -type f -name "*.go" -exec sed -i '/func ResetTransport/,/^}/c\func ResetTransport(t *http2.Transport) {}' {} + 2>/dev/null || true
	[ -f "$BUILD_DIR/go.mod" ] && sed -i -e 's/go 1.2[0-9].*/go 1.25/g' -e '/toolchain/d' "$BUILD_DIR/go.mod" 2>/dev/null || true
fi
EOF
	tail -n +2 "$GBS" >> "$TMP_GBS"
	mv -f "$TMP_GBS" "$GBS"
	chmod +x "$GBS"
done

# 删除冲突的 ovpn-dco 包
rm -rf "$FEEDS_DIR/packages/kernel/ovpn-dco"

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
# 针对 DAED 的 12M 内核分区和 BRBE 调整
if [[ "${WRT_CONFIG^^}" == *"DAED"* ]]; then
	echo "Triggering DAED hardware modifications..."
	DAED_DEVICES=("jdcloud_re-cs-07" "jdcloud_re-ss-01" "link_nn6000-v1")
	for DEV in "${DAED_DEVICES[@]}"; do
		[ -f "$TARGET_DIR/linux/qualcommax/image/ipq60xx.mk" ] && \
			sed -i "/define Device\/$DEV/,/endef/ s/KERNEL_SIZE := .*/KERNEL_SIZE := 12288k/" "$TARGET_DIR/linux/qualcommax/image/ipq60xx.mk"
	done

	if [ -f "$TARGET_DIR/linux/qualcommax/config-6.18" ]; then
		echo "# CONFIG_ARM64_BRBE is not set" >> "$TARGET_DIR/linux/qualcommax/config-6.18"
	fi
	echo "DAED 12M kernel size & BRBE patch applied successfully!"
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
