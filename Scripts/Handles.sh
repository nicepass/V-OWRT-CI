#!/bin/bash

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
	echo " "

	cd ./luci-theme-argon/

	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon

	cd $PKG_PATH && echo "theme-argon has been fixed!"
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

#修复TailScale配置文件冲突
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	echo " "

	sed -i '/\/files/d' $TS_FILE

	cd $PKG_PATH && echo "tailscale has been fixed!"
fi

#修复Rust编译失败
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE

	cd $PKG_PATH && echo "rust has been fixed!"
fi

#修复DiskMan编译失败
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	echo " "

	sed -i 's/fs-ntfs/fs-ntfs3/g' $DM_FILE
	sed -i '/ntfs-3g-utils /d' $DM_FILE

	cd $PKG_PATH && echo "diskman has been fixed!"
fi

#修复luci-app-netspeedtest相关问题
if [ -d *"luci-app-netspeedtest"* ]; then
	echo " "

	cd ./luci-app-netspeedtest/

	sed -i '$a\exit 0' ./netspeedtest/files/99_netspeedtest.defaults
	sed -i 's/ca-certificates/ca-bundle/g' ./speedtest-cli/Makefile

	cd $PKG_PATH && echo "netspeedtest has been fixed!"
fi

#修复ca
set -e

# 路径识别（覆盖多种构建入口）
ROOT="$(pwd)"
if [ -d "$ROOT/package" ] && [ -d "$ROOT/scripts" ]; then
    WRTPATH="$ROOT"
elif [ -d "$ROOT/feeds" ]; then
    WRTPATH="$(dirname "$ROOT")"
else
    echo "[ERROR] 未识别当前路径，请在 OpenWrt/ImmortalWRT 根目录执行此脚本"
    exit 1
fi

echo "[INFO] OpenWrt path = $WRTPATH"

################################################################################
# 1) 全局删除 ca-certificates 包
################################################################################
echo "[STEP1] 删除 package 中的 ca-certificates ..."
find "$WRTPATH/feeds" "$WRTPATH/package" -maxdepth 4 -type d -name "ca-certificates" -print -exec rm -rf {} +

################################################################################
# 2) patch: 将所有依赖改为 ca-bundle
################################################################################
echo "[STEP2] 统一依赖为 ca-bundle（替换 ca-certificates）..."
grep -rl "ca-certificates" "$WRTPATH" | while read F; do
    sed -i 's/ca-certificates/ca-bundle/g' "$F"
done

################################################################################
# 3) 确保 ca-bundle 自动安装
################################################################################
echo "[STEP3] 强制启用 CONFIG_PACKAGE_ca-bundle..."
sed -i \
    -e '/CONFIG_PACKAGE_ca-bundle/d' \
    "$WRTPATH/.config" 2>/dev/null || true

echo "CONFIG_PACKAGE_ca-bundle=y" >> "$WRTPATH/.config"

################################################################################
# 4) TLS & cert 兼容符号链接，确保 curl / sing-box / momo / nikki / tailscale 正常
################################################################################
echo "[STEP4] 修正证书路径软链接 ..."

CERTTARGET="/etc/ssl"
CACERT="$CERTTARGET/certs/ca-certificates.crt"
CABUNDLE="$CERTTARGET/certs/ca-bundle.crt"

mkdir -p "$(dirname "$CACERT")"

# 删除旧文件
rm -f "$CACERT" "$CABUNDLE"

# 软链统一来源
ln -s /etc/ssl/certs/ca-certificates.crt "$CABUNDLE" 2>/dev/null || true
ln -s /etc/ssl/certs/ca-bundle.crt        "$CACERT"   2>/dev/null || true

################################################################################
# 5) print summary
################################################################################
echo
echo "==================== 补丁完成 ===================="
echo "保持了 ca-bundle，移除了 ca-certificates"
echo "TLS 证书路径统一 -> 解决 libcurl / sing-box / momo / nikki / tailscale 冲突"
echo
echo "你现在可以执行:"
echo "    make defconfig && make"
echo "================================================="
