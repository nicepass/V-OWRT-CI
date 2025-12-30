#!/bin/bash
# fix-certificates.sh
# 统一 TLS 证书链处理：保留 ca-bundle、禁用 ca-certificates、全平台软链兼容
# 适用于所有 ImmortalWRT / OpenWrt 平台

set -e
echo "[Fix] Start unified TLS certificate patch (no platform separation)"


# -------------------------
# Stage 1: remove ca-certificates from feeds
# -------------------------
echo "[Fix] Removing ca-certificates ..."
find feeds -type d -name 'ca-certificates' | xargs rm -rf || true
sed -i '/ca-certificates/d' include/target.mk || true


# -------------------------
# Stage 2: enforce .config behavior
# -------------------------
grep -q 'CONFIG_PACKAGE_ca-bundle=y' .config || echo 'CONFIG_PACKAGE_ca-bundle=y' >> .config

sed -i '/CONFIG_PACKAGE_ca-certificates/d' .config
echo '# CONFIG_PACKAGE_ca-certificates is not set' >> .config

echo "[Patch] ca-bundle enabled / ca-certificates disabled"


# -------------------------
# Stage 3: patch openssl to use unified CA
# -------------------------
echo "[Fix] Patching OpenSSL ..."
for mf in package/libs/openssl/Makefile feeds/*/openssl/Makefile; do
    [ -f "$mf" ] && \
    grep -q "with-ca-bundle" "$mf" || \
    sed -i '/CONFIGURE_ARGS/a\ \ \ \ --with-ca-bundle=\/etc\/ssl\/certs\/ca-bundle.crt --with-ca-path=\/etc\/ssl\/certs' \
        "$mf"
done


# -------------------------
# Stage 4: libcurl compatibility
# -------------------------
sed -i '/CONFIG_LIBCURL_NO_DEFAULT_CA_BUNDLE/d' .config
echo 'CONFIG_LIBCURL_NO_DEFAULT_CA_BUNDLE=y' >> .config
echo "[Patch] libcurl unified CA behavior enabled"


# -------------------------
# Stage 5: always create compatibility symlink
# -------------------------
echo "[Fix] Installing universal compatibility symlink ..."
mkdir -p staging_dir/target-*/root-*/etc/ssl/certs/
ln -sf /etc/ssl/certs/ca-bundle.crt \
       staging_dir/target-*/root-*/etc/ssl/certs/ca-certificates.crt

echo "[Patch] symlink installed: ca-certificates.crt -> ca-bundle.crt"


# -------------------------
# Summary
# -------------------------
echo "----- TLS CERT PATCH SUMMARY -----"
grep -q 'CONFIG_PACKAGE_ca-bundle=y' .config && echo "ca-bundle: ENABLED"
grep -q 'CONFIG_PACKAGE_ca-certificates' .config || echo "ca-certificates: DISABLED"
[ -f staging_dir/target-*/root-*/etc/ssl/certs/ca-certificates.crt ] \
    && echo "symlink: PRESENT" || echo "symlink: ABSENT"
echo "----------------------------------"
echo "[Fix] Done!"


exit 0
