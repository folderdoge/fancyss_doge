#!/usr/bin/env bash
# 精简构建脚本：只为 hnd_v8 平台产出 full release 包，跳过 prepare_geodata_assets。
# 复用 build.sh 内的函数定义，通过环境变量 SKIP_GEODATA=1 让 papare 跳过该步。

set -e
cd "$(dirname "$0")"
REAL_REPO="$(pwd)"

# 直接 source 完整 build.sh 会触发底部的 make() 调用。
# 所以提取函数：用 sed 截掉最后的 make() 调用，再 source。
# 同时剥掉 CR：Windows git autocrlf=true 会把 build.sh 签出成 CRLF，bash 会 choke on '\r'。
TMP_BUILD="$(mktemp /tmp/fss_build_funcs.XXXXXX.sh)"
trap "rm -f $TMP_BUILD" EXIT
sed -e 's/\r$//' -e '/^make$/d' build.sh > "$TMP_BUILD"

# 重新定义 papare 让它跳过 prepare_geodata_assets
source "$TMP_BUILD"

# 重置 CURR_PATH（被 source 时的 BASH_SOURCE 错指到 /tmp）
CURR_PATH="$REAL_REPO"

papare(){
    # 只清掉旧的发布产物，保留 router_*/router_orig 这些备份子目录
    rm -f ${CURR_PATH}/packages/*.tar.gz ${CURR_PATH}/packages/*.json.js 2>/dev/null
    cp_rules
    # SKIP: prepare_geodata_assets  -- 复用仓库内已有 rules_ng2/dat/*.dat
    cp_rules_ng2
    # SKIP: sync_binary + verify_zig_tool_binaries
    # 复用 fancyss/bin-hnd_v8/ 已经预置的二进制，避免依赖 zig/go 工具链
    cat >${CURR_PATH}/packages/version_tmp.json.js <<-EOF
	{
	"name":"fancyss"
	,"version":"${VERSION}"
	EOF
}

mkdir -p packages

# 跳过 do_backup（它要写到外部 ../fancyss_history_package/ 目录）
do_backup(){ :; }

# Windows git autocrlf=true 会把 fancyss/**/*.sh 签出成 CRLF。
# tar 进 tarball 后路由器（busybox start-stop-daemon）读 shebang `#!/bin/sh\r`
# 找不到 `/bin/sh\r` 就报 "No such file or directory"。在 pack 之前把 .sh 全部剥 CR。
# 注意：webs/Module_shadowsocks.asp 必须保持 BOM+CRLF（CLAUDE.md 硬规则 #2），不动它。
echo "=== 规整 fancyss/**/*.sh 行尾为 LF ==="
find "${CURR_PATH}/fancyss" -type f -name '*.sh' -print0 | xargs -0 sed -i 's/\r$//'

papare
pack hnd_v8 full release
pack hnd    full release
finish

# 改名 + md5 旁路文件，方便辨识
cd packages
for plat in hnd_v8 hnd; do
    PKG="fancyss_${plat}_full.tar.gz"
    NEW="fancyss_${plat}_full_chain.tar.gz"
    [ -f "$PKG" ] && cp -f "$PKG" "$NEW"
done
md5sum fancyss_*.tar.gz > MD5SUMS.txt 2>/dev/null
cd ..

echo
echo "=== 产出 ==="
ls -la packages/*.tar.gz packages/*.json.js packages/MD5SUMS.txt 2>/dev/null
