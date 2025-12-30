#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#修复第三方包（sing-box、tailscale、momo、nikki...）依赖
echo "::group::[CA-FIX] Fixing ca-bundle / ca-certificates conflicts..."

PATCH_COUNT=0
SEARCH_DIRS=("$PKG_PATH" "$ROOT_DIR/feeds")

for DIR in "${SEARCH_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        FILES=$(grep -rl "+ca-bundle" "$DIR" 2>/dev/null || true)
        for f in $FILES; do
            echo "[PATCH] $f"
            sed -i 's/+ca-bundle/+ca-certificates/g' "$f"
            PATCH_COUNT=$((PATCH_COUNT+1))
        done
    fi
done

if [ "$PATCH_COUNT" -gt 0 ]; then
    echo "[OK] Patched $PATCH_COUNT occurrences of +ca-bundle → +ca-certificates"
else
    echo "[OK] No ca-bundle dependencies found — nothing to fix"
fi
