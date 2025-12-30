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

WRTPATH="$(pwd)"
echo "[INFO] WRT_PATH=$WRTPATH"

##############################################################################
# 1) 删除源码包中的 ca-certificates
##############################################################################
echo "[STEP1] 删除 package/system/ca-certificates ..."
rm -rf $WRTPATH/package/system/ca-certificates 2>/dev/null || true
rm -rf $WRTPATH/feeds/*/ca-certificates 2>/dev/null || true

##############################################################################
# 2) 将依赖全部替换为 ca-bundle
##############################################################################
echo "[STEP2] 统一依赖为 ca-bundle ..."
grep -rl "ca-certificates" "$WRTPATH/package" "$WRTPATH/feeds" 2>/dev/null | while read F; do
    sed -i 's/ca-certificates/ca-bundle/g' "$F"
done

##############################################################################
# 3) 强制启用 ca-bundle
##############################################################################
echo "[STEP3] 启用 ca-bundle ..."
sed -i '/CONFIG_PACKAGE_ca-bundle/d' "$WRTPATH/.config" 2>/dev/null || true
echo "CONFIG_PACKAGE_ca-bundle=y" >> "$WRTPATH/.config"

##############################################################################
# 4) rootfs 证书路径处理 (target install 阶段执行即可)
#    目标: 生成镜像时，TLS 统一 → ca-bundle
##############################################################################
ROOTFS_TARGET="$WRTPATH/build_dir/target-*/root-*/etc/ssl/certs"

echo "[STEP4] rootfs TLS 软链修复 (不会触碰宿主系统)"
mkdir -p $ROOTFS_TARGET

(
    cd $ROOTFS_TARGET
    # 删除固件中的重复证书文件
    rm -f ca-certificates.crt ca-bundle.crt 2>/dev/null || true

    # 创建统一软链：两者都指向 same source
    ln -sf /etc/ssl/certs/ca-bundle.crt           ca-certificates.crt
    ln -sf /etc/ssl/certs/ca-certificates.crt     ca-bundle.crt
)

echo
echo "==================== 补丁完成 ===================="
echo "✔ 保留 ca-bundle"
echo "✘ 删除 ca-certificates"
echo "✔ TLS 软链在 rootfs 中统一 (不会触碰宿主系统)"
echo
echo "执行构建：make defconfig && make"
echo "================================================="
