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
HP_DIR="$(find "$PKG_PATH" -maxdepth 2 -type d -name '*homeproxy*' -print -quit 2>/dev/null)"
if [ -n "$HP_DIR" ]; then
	echo " "
	echo "Processing HomeProxy resource presets..."

	HP_RESOURCES="$HP_DIR/root/etc/homeproxy/resources"
	HP_DASHBOARD="$HP_DIR/root/etc/homeproxy/dashboard"
	HP_IP_SOURCE="https://cdn.jsdelivr.net/gh/Loyalsoldier/surge-rules@release/cncidr.txt"
	HP_GEOSITE_SOURCE="https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs"
	HP_IP_VERSION_URL="https://github.com/Loyalsoldier/surge-rules/releases/latest"
	HP_GEOSITE_VERSION_URL="https://github.com/SagerNet/sing-geosite/releases/latest"
	HP_DASHBOARD_SOURCE="https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages"
	HP_DASHBOARD_VERSION_URL="https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom"
	HP_USER_AGENT="HomeProxy resource preset"

	HP_PREREQUISITES_MISSING=0
	for HP_COMMAND in curl awk; do
		command -v "$HP_COMMAND" > /dev/null 2>&1 || {
			echo "homeproxy resource preset requires $HP_COMMAND!"
			HP_PREREQUISITES_MISSING=1
		}
	done
	HP_PRESET_FAILED=0
	if [ "${HP_PREREQUISITES_MISSING:-0}" -eq 1 ]; then
		HP_PRESET_FAILED=1
	else
		HP_TMP="$(mktemp -d)"
		if [ -z "$HP_TMP" ]; then
			echo "failed to prepare homeproxy resource preset directory!"
			HP_PRESET_FAILED=1
		fi
	fi
	HP_DASHBOARD_STAGE="${HP_DASHBOARD}.new.$$"
	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		trap 'rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"' EXIT INT TERM
	fi

	hp_fetch_release_version() {
		local effective_url version
		effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 -A "$HP_USER_AGENT" \
			-o /dev/null -w '%{url_effective}' "$1")" || return 1
		version="${effective_url##*/}"
		case "$version" in
		''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	hp_download() {
		curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
			--connect-timeout 10 --max-time 60 -A "$HP_USER_AGENT" -o "$2" "$1" && [ -s "$2" ]
	}

	hp_fetch_dashboard_version() {
		local feed version
		feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$HP_USER_AGENT" "$HP_DASHBOARD_VERSION_URL")" || return 1
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

	hp_replace_file() {
		local source_file="$1" target_file="$2" temporary_file
		temporary_file="${target_file}.tmp.$$"
		cp "$source_file" "$temporary_file" || return 1
		chmod 0644 "$temporary_file" || return 1
		mv -f "$temporary_file" "$target_file"
	}

	hp_update_ip() {
		local version file
		version="$(hp_fetch_release_version "$HP_IP_VERSION_URL")" || return 1
		hp_download "$HP_IP_SOURCE?v=$version" "$HP_TMP/cncidr.txt" || return 1
		awk -F, -v ipv4="$HP_TMP/china_ip4.txt" -v ipv6="$HP_TMP/china_ip6.txt" '
			$1 == "IP-CIDR" { print $2 > ipv4 }
			$1 == "IP-CIDR6" { print $2 > ipv6 }
		' "$HP_TMP/cncidr.txt" || return 1
		[ -s "$HP_TMP/china_ip4.txt" ] && [ -s "$HP_TMP/china_ip6.txt" ] || return 1
		awk '
			BEGIN {
				print "{\"version\":5,\"rules\":[{\"ip_cidr\":["
				first = 1
			}
			NF {
				printf "%s\"%s\"", first ? "" : ",", $0
				first = 0
			}
			END { print "]}]}" }
		' "$HP_TMP/china_ip4.txt" "$HP_TMP/china_ip6.txt" > "$HP_TMP/geoip_cn.json" || return 1
		[ -s "$HP_TMP/geoip_cn.json" ] || return 1
		printf '%s\n' "$version" > "$HP_TMP/china_ip4.ver"
		printf '%s\n' "$version" > "$HP_TMP/china_ip6.ver"
		for file in china_ip4.txt china_ip4.ver china_ip6.txt china_ip6.ver geoip_cn.json; do
			hp_replace_file "$HP_TMP/$file" "$HP_RESOURCES/$file" || return 1
		done
		echo "homeproxy resources: china_ip $version"
	}

	hp_update_geosite() {
		local version
		version="$(hp_fetch_release_version "$HP_GEOSITE_VERSION_URL")" || return 1
		hp_download "$HP_GEOSITE_SOURCE?v=$version" "$HP_TMP/geosite_cn.srs" || return 1
		printf '%s\n' "$version" > "$HP_TMP/geosite_cn.ver"
		hp_replace_file "$HP_TMP/geosite_cn.srs" "$HP_RESOURCES/geosite_cn.srs" || return 1
		hp_replace_file "$HP_TMP/geosite_cn.ver" "$HP_RESOURCES/geosite_cn.ver" || return 1
		echo "homeproxy resources: geosite_cn $version"
	}

	hp_update_dashboard() {
		local version source_dir old_dir
		command -v unzip > /dev/null 2>&1 || return 1
		command -v find > /dev/null 2>&1 || return 1
		version="$(hp_fetch_dashboard_version)" || return 1
		hp_download "$HP_DASHBOARD_SOURCE?v=$version" "$HP_TMP/dashboard.zip" || return 1
		unzip -q "$HP_TMP/dashboard.zip" -d "$HP_TMP/dashboard" || return 1
		source_dir="$(find "$HP_TMP/dashboard" -mindepth 1 -maxdepth 1 -type d -print -quit)"
		[ -n "$source_dir" ] && [ -f "$source_dir/index.html" ] || return 1

		rm -rf "$HP_DASHBOARD_STAGE"
		mkdir -p "$HP_DASHBOARD_STAGE" &&
			cp -a "$source_dir/." "$HP_DASHBOARD_STAGE/" &&
			printf '%s\n' "$version" > "$HP_DASHBOARD_STAGE/dashboard.ver" || return 1
		rm -f "$HP_DASHBOARD_STAGE/.etag"
		chmod -R a+rX "$HP_DASHBOARD_STAGE" || return 1

		old_dir="${HP_DASHBOARD}.old.$$"
		rm -rf "$old_dir"
		{ [ ! -d "$HP_DASHBOARD" ] || mv "$HP_DASHBOARD" "$old_dir"; } || return 1
		if mv "$HP_DASHBOARD_STAGE" "$HP_DASHBOARD"; then
			rm -rf "$old_dir"
			echo "homeproxy dashboard: $version"
			return 0
		fi
		rm -rf "$HP_DASHBOARD"
		[ ! -d "$old_dir" ] || mv "$old_dir" "$HP_DASHBOARD"
		return 1
	}

	if [ "$HP_PRESET_FAILED" -eq 0 ] && ! mkdir -p "$HP_RESOURCES" "$HP_DASHBOARD"; then
		echo "failed to prepare homeproxy resource directories!"
		HP_PRESET_FAILED=1
	fi

	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		hp_update_ip || echo "failed to update homeproxy IP resources; continuing!"
		hp_update_geosite || echo "failed to update homeproxy geosite; continuing!"
		hp_update_dashboard || echo "failed to update homeproxy dashboard; continuing!"
		rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"
		trap - EXIT INT TERM
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
# 4. Tailscale & sing-box 编译与启动兼容修复
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
TS_FILES="$(find "$PKG_PATH" "$FEEDS_DIR" -maxdepth 4 -type f -wholename "*/tailscale/Makefile" 2>/dev/null)"
for TS_FILE in $TS_FILES; do
	if [ -f "$TS_FILE" ]; then
		sed -i '/\/files/d' "$TS_FILE"
		sed -i '/Build\/Prepare\/Default/a\\tsed -i -e "s/go 1.2[0-9].*/go 1.25/g" -e "/toolchain/d" $(PKG_BUILD_DIR)/go.mod' "$TS_FILE"
	fi
done

# 修复 sing-box 在 Go 1.27 下对 http2.connPool 废弃私有符号链接失败的问题
SB_FILES="$(find "$PKG_PATH" "$FEEDS_DIR" -maxdepth 4 -type f -wholename "*/sing-box/Makefile" 2>/dev/null)"
for SB_FILE in $SB_FILES; do
	if [ -f "$SB_FILE" ]; then
		echo "Patching sing-box Makefile for Go 1.27 linkname compatibility ($SB_FILE)..."
		sed -i '/Build\/Prepare\/Default/a\\tfind $(PKG_BUILD_DIR) -type f -name "*.go" -exec sed -i '\''/\\/\\/go:linkname.*connPool/d'\'' {} + 2>/dev/null || true' "$SB_FILE"
		sed -i '/Build\/Prepare\/Default/a\\tfind $(PKG_BUILD_DIR) -type f -path "*\/v2rayhttp\/*" -name "*.go" -exec sed -i '\''/func ResetTransport/,/^}/c\\func ResetTransport(t *http2.Transport) {}'\'' {} + 2>/dev/null || true' "$SB_FILE"
	fi
done

# =================================================================
# 5. 语言与编译器修复 (Rust & Upstream Golang)
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

	# 解除 GOTOOLCHAIN=local 锁定，允许自动匹配工具链
	find "$FEEDS_DIR/packages/lang/golang" -type f -exec sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} + 2>/dev/null || true

	if [ -x "$WRT_DIR/scripts/feeds" ]; then
		"$WRT_DIR/scripts/feeds" install -a golang
	fi
fi

# 删除冲突的 ovpn-dco 包
rm -rf "$FEEDS_DIR/packages/kernel/ovpn-dco"

# =================================================================
# 6. 无线与 5G 模组驱动内核兼容修复 (MT76 / QMI WWAN / Qualcomm NSS)
# =================================================================
# A. 修复 MT76 无线驱动适配 Linux 6.18+ mac80211 API (X86 / MT7981 / MT7986)
if [ -d "package/kernel/mt76" ]; then
	echo "Injecting mac80211 FILS discovery patch for package/kernel/mt76..."
	mkdir -p package/kernel/mt76/patches
	cat << 'EOF' > package/kernel/mt76/patches/999-fix-mac80211-fils-discovery-api.patch
--- a/mt7915/mcu.c
+++ b/mt7915/mcu.c
@@ -2003,11 +2003,11 @@ int mt7915_mcu_add_inband_discov(struct
 	int ret = 0;

 	if (vif->fils_discovery.tmpl_len) {
-		skb = ieee80211_get_fils_discovery_tmpl(hw, vif);
+		skb = ieee80211_get_fils_discovery_tmpl(hw, vif, 0);
 		if (skb)
 			ret = mt7915_mcu_add_inband_tmpl(dev, vif, skb, true);
 	} else if (vif->unsol_bcast_probe_resp.tmpl_len) {
-		skb = ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif);
+		skb = ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif, 0);
 		if (skb)
 			ret = mt7915_mcu_add_inband_tmpl(dev, vif, skb, false);
 	}
EOF
fi

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
