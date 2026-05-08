#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#预置HomeProxy数据
if [ -d *"homeproxy"* ]; then
	echo " "

	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" ./$HP_RULE/
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd $PKG_PATH && echo "homeproxy date has been updated!"
fi

#修改argon主题字体和颜色
if [ -d *"luci-theme-argon"* ]; then
	echo " " && cd ./luci-theme-argon/

	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon

	cd $PKG_PATH && echo "theme-argon has been fixed!"
fi

#修改aurora菜单式样
if [ -d *"luci-app-aurora-config"* ]; then
	echo " " && cd ./luci-app-aurora-config/

	sed -i "s/nav_submenu_type '.*'/nav_submenu_type 'boxed-dropdown'/g" $(find ./root/usr/share/aurora/ -type f -name "*.template")

	cd $PKG_PATH && echo "theme-aurora has been fixed!"
fi

#修改mini-diskmanager菜单位置
if [ -d *"luci-app-mini-diskmanager"* ]; then
	echo " " && cd ./luci-app-mini-diskmanager/

	sed -i "s/services/system/g" ./luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json

	cd $PKG_PATH && echo "mini-diskmanager has been fixed!"
fi

#修改qca-nss-drv启动顺序
NSS_DRV="../feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
if [ -f "$NSS_DRV" ]; then
	echo " "

	sed -i 's/START=.*/START=85/g' $NSS_DRV

	cd $PKG_PATH && echo "qca-nss-drv has been fixed!"
fi

#修改qca-nss-pbuf启动顺序
NSS_PBUF="./kernel/mac80211/files/qca-nss-pbuf.init"
if [ -f "$NSS_PBUF" ]; then
	echo " "

	sed -i 's/START=.*/START=86/g' $NSS_PBUF

	cd $PKG_PATH && echo "qca-nss-pbuf has been fixed!"
fi

# 彻底修复 Tailscale：强制首刷自启 & nftables 兼容
echo "Applying Tailscale FORCE-START fix..."

# 1. 创建所有必备目录
mkdir -p ../files/etc/config
mkdir -p ../files/etc/init.d
mkdir -p ../files/etc/rc.d
mkdir -p ../files/etc/uci-defaults

# 2. 注入 UCI 配置文件 (强制全部设为 1，即默认开启)
cat > ../files/etc/config/tailscale << 'EOF'
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

# 3. 注入强力启动脚本 (解决 sock 丢失和 nftables 报错)
cat > ../files/etc/init.d/tailscale << 'EOF'
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1
PROGD=/usr/sbin/tailscaled

start_service() {
    config_load tailscale
    local enabled fw_mode port config_path
    
    # 获取配置，即使获取失败也默认给 1 (开启)
    config_get_bool enabled 'main' enabled 1
    config_get fw_mode 'main' fw_mode 'nftables'
    config_get port 'main' port '41641'
    config_get config_path 'main' config_path '/etc/tailscale'

    [ "$enabled" -eq 0 ] && return 0

    # 核心防爆：确保运行时目录绝对存在
    mkdir -p /var/run/tailscale
    mkdir -p "$config_path"

    $PROGD --cleanup
    procd_open_instance
    procd_set_param command $PROGD \
        --port "$port" \
        --state "$config_path/tailscaled.state" \
        --socket /var/run/tailscale/tailscaled.sock
    
    # 强制注入 nftables 环境，彻底解决报错
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
chmod +x ../files/etc/init.d/tailscale

# 4. 第一道保险：创建常规自启软链接
ln -sf ../init.d/tailscale ../files/etc/rc.d/S95tailscale

# 5. 第二道保险：首次开机强制执行脚本
# 该脚本只在刚刷完固件第一次开机时运行一次，运行后系统会自动将其删除
cat > ../files/etc/uci-defaults/99-force-tailscale << 'EOF'
#!/bin/sh
# 强制激活服务并立即启动
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
exit 0
EOF
chmod +x ../files/etc/uci-defaults/99-force-tailscale

# 6. 解决核心包 Makefile 冲突 (清空原生启动脚本，防止覆盖我们的补丁)
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	sed -i '/\/files/d' $TS_FILE
fi

echo "Tailscale FORCE-START fix applied successfully!"

#修复Rust编译失败
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE

	cd $PKG_PATH && echo "rust has been fixed!"
fi

# =================================================================
# 独立编译流程：针对 DAED 专属环境的隔离注入
# 逻辑：检测环境变量 WRT_CONFIG 是否包含 DAED，自动进行软硬隔离
# =================================================================
if [[ "${WRT_CONFIG^^}" == *"DAED"* ]]; then
	echo " "
	echo "Triggering independent DAED compilation flow..."

	# 1. 内核版本强制降级至 6.6 LTS
	sed -i 's/KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=6.6/g' ../target/linux/qualcommax/Makefile

	# 2. 批量调整指定设备的内核分区大小至 12M
	DAED_DEVICES=("jdcloud_re-cs-07" "jdcloud_re-cs-01" "link_nn6000-v1")
	for DEV in "${DAED_DEVICES[@]}"; do
		sed -i "/define Device\/$DEV/,/endef/ s/KERNEL_SIZE := .*/KERNEL_SIZE := 12288k/" ../target/linux/qualcommax/image/ipq60xx.mk
	done

	# 3. 解决 DAED 核心依赖及非交互式编译报错
	echo "CONFIG_KERNEL_BPF_JIT=y" >> ../.config
	echo "CONFIG_KERNEL_MEMCG=y" >> ../.config
	echo "CONFIG_KERNEL_MEMCG_SWAP=y" >> ../.config
	echo "CONFIG_KERNEL_SKB_EXTENSIONS=y" >> ../.config
	echo "CONFIG_KERNEL_ARM64_4K_PAGES=y" >> ../.config

	# 4. 根据 WIFI 状态自动分流处理
	if [[ "${WRT_CONFIG^^}" == *"WIFI-NO"* ]]; then
		echo "Detected WIFI-NO config. Applying aggressive hostapd eradication..."
		
		# [物理清除第一层]：从 OpenWrt 全局/平台/设备的默认构建清单中彻底抹除 wpad 相关包
		# 这样 make defconfig 就再也找不到强行恢复它的理由了
		sed -i -E 's/wpad-(basic|full|mini)-[a-z]+//g' ../include/target.mk
		sed -i -E 's/wpad-(basic|full|mini)-[a-z]+//g' ../target/linux/qualcommax/Makefile
		sed -i -E 's/wpad-(basic|full|mini)-[a-z]+//g' ../target/linux/qualcommax/image/*.mk
		
		# [物理清除第二层]：写入 Kconfig 封杀令
		echo "# CONFIG_PACKAGE_wpad-basic-mbedtls is not set" >> ../.config
		echo "# CONFIG_PACKAGE_wpad-basic-openssl is not set" >> ../.config
		echo "# CONFIG_PACKAGE_wpad-full-openssl is not set" >> ../.config
		echo "# CONFIG_PACKAGE_hostapd is not set" >> ../.config
		echo "# CONFIG_PACKAGE_hostapd-common is not set" >> ../.config

		# [物理清除第三层] (终极绝杀)：直接修改 ImmortalWrt 的补丁文件，把引发报错的 Bug 行注释掉
		# 即使某种黑魔法强行拉起了 hostapd 编译，C 编译器看到的也是注释，直接无视报错！
		find ../package/network/services/hostapd/patches/ -type f -name "*.patch" -exec sed -i 's/^[+-].*he_mu_edca\.he_qos_info.*/+ \/\/ bypassed he_mu_edca bug/g' {} +

	elif [[ "${WRT_CONFIG^^}" == *"WIFI-YES"* ]]; then
		echo "Detected WIFI-YES config. Retaining Wi-Fi components..."
		# 对于保留 WIFI 的配置，强制保活 mac80211 核心支持，防止依赖断链
		echo "CONFIG_PACKAGE_kmod-mac80211=y" >> ../.config
	fi

	cd $PKG_PATH && echo "DAED independent flow (Kernel 6.6) has been successfully injected!"
fi
