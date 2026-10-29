#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -euo pipefail

GO_ROOT=$(go env GOROOT)
test -x "$GO_ROOT/bin/go"

# Use the runner's Go to bootstrap the feed's pinned host compiler.
sed -i '/^CONFIG_GOLANG_BUILD_BOOTSTRAP=/d; /^# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set$/d; /^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=/d' .config
printf '# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set\nCONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_ROOT" >> .config

# PGO is unnecessary for the build host; keep target Python flags intact.
PYTHON_MAKEFILE=feeds/packages/lang/python/python3/Makefile
if [ -f "$PYTHON_MAKEFILE" ]; then
	sed -i '/^HOST_CONFIGURE_ARGS[[:space:]]*+=/,/^$/s/--enable-optimizations/--disable-optimizations/' "$PYTHON_MAKEFILE"
	HOST_PYTHON_ARGS=$(make --no-print-directory -s \
		-C feeds/packages/lang/python/python3 -f Makefile -f - TOPDIR="$PWD" ci-host-python-args <<'MAKE'
.PHONY: ci-host-python-args
ci-host-python-args:
	@printf '%s\n' '$(HOST_CONFIGURE_ARGS)'
MAKE
)
	case " $HOST_PYTHON_ARGS " in
		*" --enable-optimizations "*)
			echo "failed to disable host Python PGO" >&2
			exit 1
			;;
		*" --disable-optimizations "*) ;;
		*)
			echo "host Python configure arguments do not expose an optimization setting" >&2
			exit 1
			;;
	esac
fi

# 定位 host LLVM。runner 镜像自带的 clang 不一定附带无版本号的 llvm-config
# （Ubuntu 的 llvm-<N> 包只提供 llvm-config-<N>，而 GitHub runner 镜像的
#  Clang 20/21/22 来自单独安装），因此这里做三级回退而不是直接 llvm-config。
LLVM_ROOT=""
if command -v llvm-config >/dev/null 2>&1; then
	LLVM_ROOT=$(llvm-config --prefix)
else
	# 回退 1：找任意 llvm-config-<N>，取版本号最高者
	for c in $(ls /usr/bin/llvm-config-* 2>/dev/null | sort -V -r); do
		if [ -x "$c" ]; then
			LLVM_ROOT=$("$c" --prefix) && break
		fi
	done
fi
if [ -z "$LLVM_ROOT" ] || [ ! -d "$LLVM_ROOT" ]; then
	# 回退 2：从 clang 的真实路径反推（runner 的 clang 常在 /usr/lib/llvm-<N>/bin）
	CLANG_BIN=$(command -v clang || true)
	if [ -n "$CLANG_BIN" ]; then
		CLANG_REAL=$(readlink -f "$CLANG_BIN" 2>/dev/null || true)
		# readlink -f 在符号链接断链时返回空，dirname "" 会得到 "."，
		# 而 [ -d "." ] 恒为真 —— 必须显式拒绝空值与相对路径，
		# 否则错误会延后到 smoke 编译阶段才暴露，且报错信息误导。
		case "$CLANG_REAL" in
			/*) LLVM_ROOT=$(dirname "$(dirname "$CLANG_REAL")") ;;
			*)  LLVM_ROOT="" ;;
		esac
	fi
fi
# 最终校验：必须是绝对路径且真实存在的目录，并且其 bin/ 下有 clang
if [ -z "$LLVM_ROOT" ] || [ "${LLVM_ROOT#/}" = "$LLVM_ROOT" ] || [ ! -d "$LLVM_ROOT" ] || [ ! -x "$LLVM_ROOT/bin/clang" ]; then
	echo "unable to locate a usable LLVM installation" >&2
	echo "  tried: llvm-config, llvm-config-*, and reverse-resolving clang" >&2
	echo "  llvm-config: $(command -v llvm-config || echo 'not found')" >&2
	echo "  clang:       $(command -v clang || echo 'not found')" >&2
	ls -d /usr/lib/llvm-* 2>/dev/null >&2 || true
	exit 1
fi
echo "BPF: using LLVM root $LLVM_ROOT ($("$LLVM_ROOT/bin/clang" --version | head -1))"

for tool in clang llc opt llvm-dis llvm-strip; do
	if [ ! -x "$LLVM_ROOT/bin/$tool" ]; then
		echo "missing LLVM tool: $LLVM_ROOT/bin/$tool" >&2
		exit 1
	fi
done
LLVM_SMOKE="${RUNNER_TEMP:-/tmp}/wrt-bpf-smoke"
mkdir -p "$LLVM_SMOKE"
printf 'int wrt_bpf_smoke(void) { return 0; }\n' > "$LLVM_SMOKE/smoke.c"
"$LLVM_ROOT/bin/clang" --target=bpfel -O2 -emit-llvm -c \
	"$LLVM_SMOKE/smoke.c" -o "$LLVM_SMOKE/smoke.bc"
"$LLVM_ROOT/bin/opt" -O2 -mtriple=bpfel \
	< "$LLVM_SMOKE/smoke.bc" > "$LLVM_SMOKE/smoke.opt"
"$LLVM_ROOT/bin/llvm-dis" \
	< "$LLVM_SMOKE/smoke.opt" > "$LLVM_SMOKE/smoke.S"
"$LLVM_ROOT/bin/llc" -march=bpfel -mcpu=v3 -filetype=obj \
	-o "$LLVM_SMOKE/smoke.o" < "$LLVM_SMOKE/smoke.S"
"$LLVM_ROOT/bin/llvm-strip" --strip-debug "$LLVM_SMOKE/smoke.o"

# Use one host LLVM installation for every BPF build tool on all targets.
sed -i '/^CONFIG_BPF_TOOLCHAIN_/d; /^# CONFIG_BPF_TOOLCHAIN_.* is not set$/d' .config
printf 'CONFIG_BPF_TOOLCHAIN_HOST=y\nCONFIG_BPF_TOOLCHAIN_HOST_PATH="%s"\n' "$LLVM_ROOT" >> .config

REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"
{
	"$GO_ROOT/bin/go" version
	printf 'Go bootstrap root: %s\n' "$GO_ROOT"
	if [ -n "${HOST_PYTHON_ARGS:-}" ]; then
		printf 'Host Python PGO: disabled\n'
	else
		printf 'Host Python PGO: not applicable\n'
	fi
	printf 'BPF LLVM prefix: %s\n' "$LLVM_ROOT"
	"$LLVM_ROOT/bin/clang" --version
} | tee "$REPORT_DIR/host-toolchains.txt"
