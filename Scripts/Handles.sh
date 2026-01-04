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

##############################################################################
# ImmortalWRT / OpenWrt (APK mode)
# Final CA unification script
# Goal:
#   - ONLY use ca-bundle
#   - Completely eliminate ca-certificates / ca-certs virtual conflicts
##############################################################################

WRTPATH="$(pwd)"

echo "===================================================="
echo "[INFO] OpenWrt path = $WRTPATH"
echo "[INFO] APK TLS unify: ca-bundle ONLY"
echo "===================================================="

##############################################################################
# STEP 1: 移除 package/ 中的 ca-certificates（防止被优先选中）
##############################################################################
echo "[STEP1] Removing package/system/ca-certificates (if exists)..."

if [ -d "$WRTPATH/package/system/ca-certificates" ]; then
    rm -rf "$WRTPATH/package/system/ca-certificates"
    echo "  → removed package/system/ca-certificates"
else
    echo "  → not present, skip"
fi

##############################################################################
# STEP 2: 全局替换依赖 ca-certificates / ca-certs → ca-bundle
##############################################################################
echo "[STEP2] Replacing ca-certificates / ca-certs → ca-bundle in feeds & packages..."

find "$WRTPATH" \
    -type f \
    -name "Makefile" \
    -o -name "*.mk" \
| while read F; do
    sed -i \
        -e 's/+ca-certificates/+ca-bundle/g' \
        -e 's/ca-certificates/ca-bundle/g' \
        -e 's/+ca-certs/+ca-bundle/g' \
        -e 's/ca-certs/ca-bundle/g' \
        "$F"
done

##############################################################################
# STEP 3: ★核心修复★ dockerd 禁用 ca-certs 虚拟依赖
# 这是 APK 冲突的真正根因
##############################################################################
echo "[STEP3] Forcing dockerd to depend on ca-bundle (NO ca-certs)..."

find "$WRTPATH/feeds" -path "*/dockerd/Makefile" -type f | while read F; do
    echo "  → patch $F"

    # 清理旧依赖
    sed -i \
        -e 's/+ca-certificates//g' \
        -e 's/+ca-certs//g' \
        "$F"

    # 强制加入实体包 ca-bundle
    if ! grep -q '+ca-bundle' "$F"; then
        sed -i 's/DEPENDS:=/DEPENDS:=+ca-bundle /' "$F"
    fi
done

##############################################################################
# STEP 4: world 级别只允许 ca-bundle
##############################################################################
echo "[STEP4] Enforcing CONFIG_PACKAGE_ca-bundle=y"

sed -i \
    -e '/CONFIG_PACKAGE_ca-certificates/d' \
    -e '/CONFIG_PACKAGE_ca-certs/d' \
    "$WRTPATH/.config" 2>/dev/null || true

grep -q 'CONFIG_PACKAGE_ca-bundle=y' "$WRTPATH/.config" 2>/dev/null || \
    echo 'CONFIG_PACKAGE_ca-bundle=y' >> "$WRTPATH/.config"

##############################################################################
# STEP 5: TLS 证书路径统一（仅在 rootfs 阶段生效，不触碰宿主机）
##############################################################################
echo "[STEP5] Normalizing TLS cert paths (runtime-safe)..."

mkdir -p "$WRTPATH/files/etc/ssl/certs"

cat > "$WRTPATH/files/etc/ssl/certs/README.ca-bundle" <<'EOF'
Unified TLS CA path:
  /etc/ssl/certs/ca-certificates.crt
Provided by ca-bundle
EOF

##############################################################################
# DONE
##############################################################################
echo "===================================================="
echo "[DONE] CA unification complete"
echo " - ca-certificates: REMOVED"
echo " - ca-certs (virtual): ELIMINATED"
echo " - ca-bundle: ONLY trusted provider"
echo "===================================================="
