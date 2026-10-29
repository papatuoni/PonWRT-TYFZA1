#!/usr/bin/env bash
#
# ============================================================================
#  PonWRT-TYFZA1 · diy-part.sh
#  天翼 TYFZA1 / Realtek RTL9617CVW —— 自定义编译步骤
#
#  适配基准：上游 v0.8.2-beta（VERSION 文件）
#    · v0.8.1 -> v0.8.2 主要变化：新增 port/packages/tyfza1-storage 包、
#      factory-v1 存储迁移（可写空间 16 MiB -> 约 191 MiB）、
#      port/openwrt-patches 补丁机制、99-tyfza1-platform-packages 版本固定。
#    · 仍然需要的两个补丁：LEDS_TRIGGER_TYFZA1_USB（第 2-1 步，上游仍漏配）、
#      关无线时放宽 99-tyfza1-platform-packages（第 2-2 步）。
#
#  执行时机（见 .github/workflows/build-release.yml）：
#      cd sources/openwrt && ../../diy-part.sh
#  所以本脚本运行时：
#      当前目录 = sources/openwrt（OpenWrt 源码树根）
#      仓库根   = ../..
#
#  ⚠ 必须排在 "feeds update -a && feeds install -a" 之后执行
#    第 4 步换 smartdns 源码，改的是 feeds/packages/net/smartdns/Makefile，
#    feeds 没装就找不到这个文件。这也是对原 workflow 唯一需要的改动。
#
#  开关（在 workflow 里用 env 覆盖，或本地 export）：
#    DIY_TURBOACC=1  装载 chenmozhijin/turboacc（会替换 firewall4/nftables/libnftnl）
#    DIY_OPENCLASH=1 装载 vernesong/OpenClash
#    DIY_SMARTDNS=1  把 smartdns 源码换成 papatuoni/smartdns 的 custom-48.4
#    DIY_DDNS=1      装载 ddns-scripts + luci-app-ddns（官方 feeds）
#    DIY_WIRELESS=1  保留无线（默认开，见第 2-2 步说明）
#    DIY_LAN_IP=192.168.2.1
# ============================================================================
set -eu

DIY_LAN_IP="${DIY_LAN_IP:-192.168.2.1}"
DIY_TURBOACC="${DIY_TURBOACC:-1}"
DIY_OPENCLASH="${DIY_OPENCLASH:-1}"
DIY_SMARTDNS="${DIY_SMARTDNS:-1}"
DIY_DDNS="${DIY_DDNS:-1}"
# 无线。1=保留（默认）；0=从设备的 DEVICE_PACKAGES 里摘掉整个无线栈。
#
# ⚠ 关掉之后【无法事后装回来】，只能重编固件。原因见第 2-2 步：
#   kmod-rtl-ax-ap 打包的是 cfg80211.ko + mac80211.ko + rtl_ax_ap.ko 三个内核模块，
#   其中 rtl_ax_ap 是上游私有驱动（62 个源文件，只在 port/overlay 里），
#   官方源和 ImmortalWrt 都没有；而且驱动编译时要把 build.sh 动态生成的
#   pe-tx-code.h（PE 硬件加速固件）注入进去。内核模块 vermagic 也对不上任何源。
#
# 默认改成 1 的原因：v0.8.2 的可写空间已从 16 MiB 涨到约 191 MiB，
# 当初"省 2~3 MB"的理由不成立，关掉反而等于永久失去 Wi-Fi。
# 真不想用 Wi-Fi，刷完在 LuCI 里把 radio 禁用即可（软件开关，随时能开回来）。
DIY_WIRELESS="${DIY_WIRELESS:-1}"
# smartdns Web 仪表盘（Rust 插件 smartdns_ui.so + 前端 wwwroot）三态：
#   0（默认）= 完全不构建。最快。node/host、rust/host、bindgen、npm、cargo 全跳过。
#   m        = 构建出 apk，但不打进固件。产物在 bin/packages/，可下载后 apk add 装。
#   1        = 构建并打进固件。
#
# ★ 重要：m 和 1 的编译耗时【完全一样】。看 ImmortalWrt 的 Makefile：
#     PKG_BUILD_DEPENDS:=PACKAGE_smartdns-ui:node/host PACKAGE_smartdns-ui:rust-bindgen/host
#     ifneq ($(CONFIG_PACKAGE_smartdns-ui),)   ← "m" 也是非空
#   =m 只是不进 rootfs，npm install/build 和 cargo build 一步不少。
#   想省时间只能是 0；想拿 apk 则必须跑一次 m（或 1），把 apk 存下来复用。
DIY_SMARTDNS_UI="${DIY_SMARTDNS_UI:-0}"

# 你的 smartdns 分支：改这里就能换源码，不用动 workflow
SMARTDNS_REPO="${SMARTDNS_REPO:-papatuoni/smartdns}"
SMARTDNS_REF="${SMARTDNS_REF:-custom-48.4}"

# ImmortalWrt 源（smartdns 的 Makefile / LuCI 界面从这里取）
# smartdns 本体用的是官方 feeds 的目录，但 Makefile 换成 ImmortalWrt 那份
# （它把 Web 仪表盘做成了独立子包 smartdns-ui），界面也用它那版。
IMM_PKGS_REPO="${IMM_PKGS_REPO:-immortalwrt/packages}"
IMM_PKGS_REF="${IMM_PKGS_REF:-master}"     # 建议改成固定 commit，避免漂移
IMM_LUCI_REPO="${IMM_LUCI_REPO:-immortalwrt/luci}"
IMM_LUCI_REF="${IMM_LUCI_REF:-master}"     # 同上

# smartdns 官方 Web 前端静态资源（不含在 smartdns 源码树里，单独发布）
SMARTDNS_WEBUI_REPO="${SMARTDNS_WEBUI_REPO:-pymumu/smartdns-webui}"
SMARTDNS_WEBUI_TAG="${SMARTDNS_WEBUI_TAG:-v1.0.0}"
SMARTDNS_WEBUI_URL="${SMARTDNS_WEBUI_URL:-https://github.com/pymumu/smartdns-webui/releases/download/v1.0.0/smartdns-ui-v1.0.0.tar.gz}"
# ↑ 仅作备用参考：ImmortalWrt 的方案是 git clone smartdns-webui 源码后
#   本地 npm install && npm run build，不走 release 直链（直链经常 403）。

# 仓库里维护的 .config（相对仓库根）。留空则不覆盖，沿用树里已有的 .config
DIY_CONFIG="${DIY_CONFIG:-configs/tyfza1-diy.config}"

TREE="$(pwd)"
REPO_ROOT="$(cd "$TREE/../.." && pwd)"

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境自检
[ -f include/version.mk ] && [ -d package ] ||
    die "当前目录不是 OpenWrt 源码树（$(pwd)）。本脚本要由 workflow 在 sources/openwrt 下执行"
info "源码树 $TREE"
info "仓库根 $REPO_ROOT"

# ---------------------------------------------------------- 1. 改默认 LAN IP
# 该机型的 board.d/02_network 只 ucidef_set_interfaces_lan_wan，不写 IP，
# 所以 192.168.1.1 来自 config_generate，改这一个文件就够。
CFG_GEN=package/base-files/files/bin/config_generate
if [ -f "$CFG_GEN" ]; then
    before="$(grep -c '192\.168\.1\.1' "$CFG_GEN" || true)"
    sed -i "s/192\.168\.1\.1/${DIY_LAN_IP}/g" "$CFG_GEN"
    info "默认 LAN IP：192.168.1.1 -> ${DIY_LAN_IP}（config_generate 命中 ${before} 处）"
else
    warn "没找到 $CFG_GEN，跳过改 IP（OpenWrt 目录结构变了？）"
fi

# ------------------------------------------------------------- 2. 写入 .config
# sync-overlay.sh 的逻辑：填了 config_file 就用它；没填且树里 .config 非空
# 就保留。所以这里写好 .config 后，workflow 的 config_file 留空即可。
if [ -n "$DIY_CONFIG" ]; then
    [ -f "$REPO_ROOT/$DIY_CONFIG" ] || die "找不到配置 $REPO_ROOT/$DIY_CONFIG"
    cp "$REPO_ROOT/$DIY_CONFIG" "$TREE/.config"
    info "已写入配置 $DIY_CONFIG"
fi
[ -s "$TREE/.config" ] || die ".config 为空，无法继续"

# ---- 2-0. 强制锁定 target 与设备 ----------------------------------------
# 这三行只要丢一条，defconfig 就选不到设备，target/linux install 会什么都不做、
# 也不报错，一路走到打包那步才以 "cp: cannot stat ...-kernel.itb" 的形式爆出来。
# 所以先删后写，确保唯一且存在。
sed -i -e '/^CONFIG_TARGET_rtl9617c=/d' \
       -e '/^CONFIG_TARGET_rtl9617c_generic=/d' \
       -e '/^#\? *CONFIG_TARGET_rtl9617c_generic_DEVICE_/d' "$TREE/.config"
printf '%s\n' \
    'CONFIG_TARGET_rtl9617c=y' \
    'CONFIG_TARGET_rtl9617c_generic=y' \
    'CONFIG_TARGET_rtl9617c_generic_DEVICE_tianyi_tyfza1=y' >> "$TREE/.config"
# 版本号绝不能进文件名。scripts/package_release.sh 把镜像名写死成
#   openwrt--rtl9617c-generic-tianyi_tyfza1-kernel.itb
# （注意 openwrt 后那道双横线：VERNUM 和 VERCODE 都为空，只剩 EXTRA 的那一道）。
# 而这两个符号在 VERSIONOPT=y 时默认是 y，于是名字里被塞进一段版本号：
#   CONFIG_VERSION_FILENAMES=y       -> openwrt-0.4.1-alpha--rtl9617c-generic-...
#   CONFIG_VERSION_CODE_FILENAMES=y  -> openwrt-r0-79bc56c-rtl9617c-generic-...
# 结果打包时 cp: cannot stat ...-kernel.itb —— 实际上镜像早就编好了，
# 只是名字对不上。两个都必须显式关掉。
for sym in CONFIG_VERSION_FILENAMES CONFIG_VERSION_CODE_FILENAMES; do
    sed -i -e "/^${sym}=/d" -e "/^# ${sym} is not set$/d" "$TREE/.config"
    printf '# %s is not set\n' "$sym" >> "$TREE/.config"
done
info "已锁定 target/设备，并关闭版本号进文件名（VERNUM + VERCODE）"

# ---- 2-1. 补齐上游漏掉的内核符号 ----------------------------------------
# 上游 v0.8.0 新增了补丁 port/overlay/.../patches-6.18/209-native-leds.patch，
# 引入了一个 tristate 符号：
#     config LEDS_TRIGGER_TYFZA1_USB
#         tristate "TYFZA1 USB presence and activity LED"
#         depends on ARCH_RTL9617C && USB && LEDS_TRIGGERS
# 但同一个提交没有把它写进 target/linux/rtl9617c/config-6.18
# （那份配置里只有 CONFIG_LEDS_TYFZA1=y，没有 USB 这个）。
# 于是内核 kconfig 认为这是一个 NEW 且可见的符号，需要交互确认；CI 里没有
# 终端，syncconfig 直接失败：
#     TYFZA1 USB presence and activity LED (LEDS_TRIGGER_TYFZA1_USB) [N/m/?] (NEW)
#     make[7]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
#     ERROR: target/linux failed to build.
# 这发生在编内核的第一步，后面什么都没开始，所以日志里看不到任何 gcc 输出。
#
# 填 n 是安全的：Kconfig 里它的默认值就是 N，且 port/configs/tyfza1-compat.config
# 并不要求 kmod-tyfza1-usb-led，所以没有任何包依赖它为 y/m。
#
# ⚠⚠ 关键：必须改【仓库根的 overlay 源】，不能只改源码树里的副本！
#    build.sh 会在 DIY 之后执行 sync-overlay.sh，里面是：
#       rsync -a --delete port/overlay/target/linux/rtl9617c/ $TREE/target/linux/rtl9617c/
#    --delete 会把我们写进源码树的那一行当成多余内容删掉，还原成 overlay 原版，
#    于是补丁"执行了但没生效"，内核照样崩在同一个地方。
#    改 overlay 源之后 rsync 会把它带进源码树，才真正生效。
add_kconfig_n() {  # $1=文件
    [ -f "$1" ] || return 1
    grep -q 'CONFIG_LEDS_TRIGGER_TYFZA1_USB' "$1" && return 0
    printf '# CONFIG_LEDS_TRIGGER_TYFZA1_USB is not set\n' >> "$1"
    info "  已补齐 $1"
}

KC_REL=target/linux/rtl9617c/config-6.18
KC_OVERLAY="$REPO_ROOT/port/overlay/$KC_REL"     # 决定性的一处
KC_TREE="$TREE/$KC_REL"                          # 顺带也写，便于本地直接编
add_kconfig_n "$KC_OVERLAY" || warn "没找到 $KC_OVERLAY，overlay 结构可能变了"
add_kconfig_n "$KC_TREE" || true
if grep -q 'CONFIG_LEDS_TRIGGER_TYFZA1_USB' "$KC_OVERLAY" 2>/dev/null; then
    info "补齐内核符号：CONFIG_LEDS_TRIGGER_TYFZA1_USB=n（上游 v0.8.0 漏配）"
else
    warn "内核符号补齐未生效——sync-overlay 后仍会 Report LEDS_TRIGGER_TYFZA1_USB (NEW)"
fi

# 强制写进 .config：先删旧行再追加，避免出现两条互相矛盾的记录
force_pkg() {
    local sym
    for sym in "$@"; do
        sed -i -e "/^CONFIG_PACKAGE_${sym}=/d" \
               -e "/^# CONFIG_PACKAGE_${sym} is not set$/d" "$TREE/.config"
        printf 'CONFIG_PACKAGE_%s=y\n' "$sym" >> "$TREE/.config"
    done
}
disable_pkg() {
    local sym
    for sym in "$@"; do
        sed -i -e "/^CONFIG_PACKAGE_${sym}=/d" \
               -e "/^# CONFIG_PACKAGE_${sym} is not set$/d" "$TREE/.config"
        printf '# CONFIG_PACKAGE_%s is not set\n' "$sym" >> "$TREE/.config"
    done
}
# 写成 =m：包会被编译出 apk/ipk 放在 bin/packages/，但不打进 rootfs 镜像。
# 用于「编译一次产出 apk，之后刷机按需 apk add」。
force_pkg_m() {
    local sym
    for sym in "$@"; do
        sed -i -e "/^CONFIG_PACKAGE_${sym}=/d" \
               -e "/^# CONFIG_PACKAGE_${sym} is not set$/d" "$TREE/.config"
        printf 'CONFIG_PACKAGE_%s=m\n' "$sym" >> "$TREE/.config"
    done
}

# ---- 2a. dnsmasq-full（OpenClash 硬依赖，nftset 走 nftables 那条路）----------
# dnsmasq 与 dnsmasq-full 互斥，只留 full；nftset 会把 nftables-json 带进来。
disable_pkg dnsmasq
force_pkg dnsmasq-full dnsmasq_full_nftset dnsmasq_full_dnssec
info "DNS：dnsmasq -> dnsmasq-full（nftset + dnssec 打开）"

# ---- 2b. 代理相关的内核模块 ------------------------------------------------
# 只写【最小显式集】，其余靠依赖链自动带出，避免和上游强制项重复：
#   kmod-nft-offload → +kmod-nf-flow +kmod-nft-nat → +kmod-nft-core → +kmod-nfnetlink
#   kmod-nft-socket  → +kmod-nf-socket   （这两条 + kmod-nft-tproxy + kmod-tun +
#                                          kmod-inet-diag 已被 tyfza1-compat.config
#                                          强制 =y，sync-overlay 一定会写回来）
#   kmod-br-netfilter → +kmod-ipt-core
# 所以这里只需：kmod-nft-offload（含 flow/nat/core/netlink）、
#              kmod-netlink-diag（ss 用，compat 里没有）、kmod-br-netfilter。
force_pkg kmod-nft-offload kmod-netlink-diag kmod-br-netfilter
info "已强制保留代理相关内核模块（offload 依赖链 + netlink-diag + br-netfilter）"

# ---- 2-2. 关闭无线（可选，默认不关）----------------------------------------
# 【关掉后无法事后装回，只能重编】驱动是设备私有的：
#   modules.mk 里
#     define KernelPackage/rtl-ax-ap
#       KCONFIG:=CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_RTL_AX_AP
#       FILES:= cfg80211.ko mac80211.ko rtl_ax_ap.ko
#   rtl_ax_ap 的 62 个源文件只在 port/overlay/.../files-6.18/drivers/net/wireless/
#     realtek/rtl_ax_ap/ 下，官方 feeds 和 ImmortalWrt 都没有这个包；
#   而且 build.sh 会先把动态生成的 pe-tx-code.h（PE 加速固件）拷进该目录再编译，
#   事后拿任何源都装不出等价的 .ko（vermagic / 符号表 / PE 固件三者都对不上）。
#
# 无线包有两处来源，只改 .config 不够：
#   port/overlay/target/linux/rtl9617c/image/Makefile 的
#     DEVICE_PACKAGES := kmod-rtl-ax-ap tyfza1-pon-control luci-app-tyfza1-pon \
#       ubi-utils nand-utils uboot-envtools iw wpad-mbedtls wifi-scripts wireless-regdb \
#       ...
#   设备默认就带，光在 .config 里不写照样被拉进来。
# 而 build.sh → sync-overlay.sh 是：
#     rsync -a --delete port/overlay/target/linux/rtl9617c/ $TREE/target/linux/rtl9617c/
# 所以必须改【仓库根的 overlay 源】，改源码树副本会被 --delete 冲掉（和 2-1 那个
# LEDS_TRIGGER_TYFZA1_USB 是同一个坑）。
if [ "$DIY_WIRELESS" != 1 ]; then
    DEV_MK="$REPO_ROOT/port/overlay/target/linux/rtl9617c/image/Makefile"
    if [ -f "$DEV_MK" ]; then
        python3 - "$DEV_MK" <<'PYEOF'
import re, sys
path = sys.argv[1]
drop = {'kmod-rtl-ax-ap', 'iw', 'wpad-mbedtls', 'wifi-scripts', 'wireless-regdb'}
lines = open(path, encoding='utf-8').read().splitlines()

# 找到 DEVICE_PACKAGES := 起始行，连同后续以 \ 结尾的续行一起取出
start = next((i for i, l in enumerate(lines)
              if re.match(r'^\s*DEVICE_PACKAGES\s*:=\s*', l)), None)
if start is None:
    print('NODEVICE'); sys.exit(0)
end = start
while lines[end].rstrip().endswith('\\'):
    end += 1

indent = re.match(r'^(\s*)', lines[start]).group(1)
tokens = []
for l in lines[start:end + 1]:
    body = re.sub(r'^\s*DEVICE_PACKAGES\s*:=\s*', '', l)
    body = body.rstrip().rstrip('\\')
    tokens += body.split()

kept = [t for t in tokens if t not in drop]
# 合并成单行赋值，避免续行符残留导致语法错误
lines[start:end + 1] = [indent + 'DEVICE_PACKAGES := ' + ' '.join(kept)]
open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('REMOVED' if len(kept) != len(tokens) else 'NOCHANGE')
PYEOF
        if grep -qE 'kmod-rtl-ax-ap|wpad-mbedtls|wifi-scripts|wireless-regdb' "$DEV_MK"; then
            warn "无线包仍在 DEVICE_PACKAGES 里，摘除未生效（结构变了？）"
        else
            info "已关闭无线：从 overlay 的 DEVICE_PACKAGES 摘掉 kmod-rtl-ax-ap / iw / wpad-mbedtls / wifi-scripts / wireless-regdb"
        fi
    else
        warn "没找到 $DEV_MK，跳过关无线"
    fi

    # ---- 顺带：99-tyfza1-platform-packages 会校验 wifi-scripts 存在 ----
    # v0.8.2 新增的 uci-defaults，用途是"固定平台定制软件包版本，避免升级覆盖
    # LuCI、无线和功率适配"。它从 /rom/lib/apk/db/installed 里取 4 个包的哈希：
    #     luci-mod-status / luci-mod-network / libiwinfo20230701 / wifi-scripts
    # 然后 [ "$#" -eq 4 ] || { echo "Missing ..."; exit 1; }
    # 摘掉 wifi-scripts 后这里必然 exit 1：脚本不会被 uci-defaults 删除，
    # 每次开机都重试并往日志里刷一行错误，版本固定功能也失效。
    # 关无线后只保留 LuCI 那两个（一定存在），把要求数量从 4 降到 2。
    # 同样改 overlay 源，否则会被 sync-overlay 的 rsync --delete 冲掉。
    PIN_SH="$REPO_ROOT/port/overlay/target/linux/rtl9617c/base-files/etc/uci-defaults/99-tyfza1-platform-packages"
    if [ -f "$PIN_SH" ]; then
        python3 - "$PIN_SH" <<'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
before = s
s = s.replace(' || name == "wifi-scripts"', '')
s = s.replace('name == "libiwinfo20230701" ||\n\t    ', 'name == "libiwinfo20230701"')
s = s.replace('name == "libiwinfo20230701" || name == "wifi-scripts"',
              'name == "libiwinfo20230701"')
s = s.replace('$#" -eq 4', '$#" -eq 2')
if s != before:
    open(path, 'w', encoding='utf-8').write(s)
    print('PATCHED')
else:
    print('NOCHANGE')
PYEOF
        if grep -q 'wifi-scripts' "$PIN_SH"; then
            warn "99-tyfza1-platform-packages 仍要求 wifi-scripts，开机可能刷错误日志"
        else
            info "已放宽 99-tyfza1-platform-packages：不再要求 wifi-scripts（只 pin LuCI 两个模块）"
        fi
    fi
fi

# ------------------------------------------------- 3. smartdns 换成你的源码
if [ "$DIY_SMARTDNS" = 1 ]; then
    SD_MK=feeds/packages/net/smartdns/Makefile
    [ -f "$SD_MK" ] || die "找不到 $SD_MK —— 请把本脚本放到 feeds update/install 之后执行"

    # ===== 用 ImmortalWrt 的 net/smartdns/Makefile 作为基础 =====
    # 它比 feeds 官方那份（46.1）和之前手写版都完善，关键是把 Web 仪表盘做成了
    # 独立子包 smartdns-ui：
    #   - 不开启时完全不占空间（DEPENDS: +smartdns，独立 ipk）
    #   - 前端从 pymumu/smartdns-webui.git 拉源码，本地 npm install && npm run build，
    #     产物 out/ 装到 /usr/share/smartdns/wwwroot
    #     （比直接下载 release 的 tar.gz 稳——release 直链经常 403）
    #   - Rust 后端走标准 rust-package.mk，BINDGEN_EXTRA_CLANG_ARGS 已用
    #     --sysroot=$(TOOLCHAIN_ROOT_DIR) 处理好，不用自己猜
    #   - MAKE_VARS 带 WITH_ZLIB=0，规避之前踩过的 "missing libz.so.1" 打包失败
    rm -rf /tmp/imm-sd && mkdir -p /tmp/imm-sd
    curl -fsSL --retry 2 --max-time 180 \
        "https://codeload.github.com/${IMM_PKGS_REPO}/tar.gz/${IMM_PKGS_REF}" \
        | tar -xz -C /tmp/imm-sd --strip-components=1 \
              --wildcards "*/net/smartdns/*" 2>/dev/null
    if [ ! -f /tmp/imm-sd/net/smartdns/Makefile ]; then
        die "从 ImmortalWrt 取 net/smartdns 失败"
    fi
    cp /tmp/imm-sd/net/smartdns/Makefile "$SD_MK"
    rm -rf /tmp/imm-sd

    # --- 改造 1：源码改成你的分支（git 协议）---
    # 原本是 codeload tarball + PKG_HASH，要同时猜对顶层目录名 / PKG_BUILD_DIR /
    # PKG_HASH，任一不对就编失败、且报错被 make 吞掉只剩一行。git 协议三个问题全消。
    sed -i \
        -e '/^PKG_SOURCE:=/d' \
        -e '/^PKG_SOURCE_URL:=/d' \
        -e '/^PKG_HASH:=/d' \
        -e '/^PKG_BUILD_DIR:=/d' \
        "$SD_MK"

    # --- 改造 2：include 路径改绝对路径 ---
    # 放 feeds/packages 下时，相对路径 ../../lang/rust/... 够不着
    sed -i 's|include ../../lang/rust/rust-package.mk|include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk|' "$SD_MK"
    sed -i 's|include ../../lang/rust/rust-host-build.mk|include $(TOPDIR)/feeds/packages/lang/rust/rust-host-build.mk|' "$SD_MK"

    # PKG_LICENSE_FILES 之后插入 git 协议四行
    awk -v repo="$SMARTDNS_REPO" -v ref="$SMARTDNS_REF" '
      { print }
      /^PKG_LICENSE_FILES:=/ && !done {
        print ""
        print "# git 协议：直接跟分支，永远拿到分支 HEAD，不受 tag/tarball 命名影响"
        print "PKG_SOURCE_PROTO:=git"
        print "PKG_SOURCE_URL:=https://github.com/" repo ".git"
        print "PKG_SOURCE_VERSION:=" ref
        print "PKG_MIRROR_HASH:=skip"
        done=1
      }' "$SD_MK" > "$SD_MK.new" && mv "$SD_MK.new" "$SD_MK"

    # --- 改造 3：aarch64 不需要 i386 的 libatomic，去掉避免误加依赖 ---
    sed -i 's|^  DEPENDS:=+i386:libatomic +libopenssl|  DEPENDS:=+libopenssl|' "$SD_MK"

    info "smartdns 源码 -> ${SMARTDNS_REPO}@${SMARTDNS_REF}（git 协议，基于 ImmortalWrt Makefile）"
    grep -E '^(PKG_SOURCE_PROTO|PKG_SOURCE_URL|PKG_SOURCE_VERSION|PKG_MIRROR_HASH):=' "$SD_MK" | sed 's/^/    /'
    force_pkg smartdns luci-app-smartdns

    # ===== 可选：Web 仪表盘（独立包 smartdns-ui）=====
    # 后端 .so 是 Rust 的（plugin/smartdns-ui），前端是 npm 构建的静态页面。
    # 官方配置：plugin smartdns_ui.so + smartdns-ui.www-root /usr/share/smartdns/wwwroot
    # 默认账号密码 admin/password，监听 6080。
    if [ "$DIY_SMARTDNS_UI" = 1 ] || [ "$DIY_SMARTDNS_UI" = m ]; then
        # rust-bindgen 不在本项目锁定的 feeds 里（只有 lang/rust、lang/node），
        # 而 ImmortalWrt 的 Makefile 声明了 PACKAGE_smartdns-ui:rust-bindgen/host。
        # 不装的话只留一条不致命 WARNING，然后 cargo build 时 bindgen 找不到才真失败。
        rm -rf /tmp/imm-bg && mkdir -p /tmp/imm-bg
        curl -fsSL --retry 2 --max-time 180 \
            "https://codeload.github.com/${IMM_PKGS_REPO}/tar.gz/${IMM_PKGS_REF}" \
            | tar -xz -C /tmp/imm-bg --strip-components=1 \
                  --wildcards "*/devel/rust-bindgen/*" 2>/dev/null
        if [ -f /tmp/imm-bg/devel/rust-bindgen/Makefile ]; then
            mkdir -p package/tyfza1-extra/devel
            rm -rf package/tyfza1-extra/devel/rust-bindgen
            cp -r /tmp/imm-bg/devel/rust-bindgen package/tyfza1-extra/devel/
            sed -i 's|include ../../lang/rust/rust-host-build.mk|include $(TOPDIR)/feeds/packages/lang/rust/rust-host-build.mk|' \
                package/tyfza1-extra/devel/rust-bindgen/Makefile
            info "已补 rust-bindgen（feeds 里没有，从 ImmortalWrt 取）"
        else
            warn "取 rust-bindgen 失败，smartdns-ui 可能因缺 bindgen 编不过"
        fi
        rm -rf /tmp/imm-bg

        # node/host、rust/host 也要显式装进源码树（prepare_luci_feeds.sh 不会装）
        ./scripts/feeds install node rust 2>/dev/null || true
        for p in node rust; do
            [ -e "package/feeds/packages/lang/$p" ] ||
                warn "feeds install 后仍找不到 lang/$p，node/host 或 rust/host 可能缺失"
        done

        if [ "$DIY_SMARTDNS_UI" = m ]; then
            force_pkg_m smartdns-ui
            info "smartdns-ui：=m（编译出 apk，不打进固件）"
            info "产物在 sources/openwrt/bin/packages/<arch>/<feed>/smartdns-ui-*.apk"
            info "会随 build artifact 保留 14 天；也会随 Release 上传（见 workflow）"
        else
            force_pkg smartdns-ui
            info "smartdns-ui（Web 仪表盘）已启用：前端 npm 构建 + Rust 后端，打进固件"
        fi
        warn "这一步很慢：要编 node/host、rust/host、bindgen，再 npm build + cargo build"
        warn "可能额外 30~60 分钟；失败就把 V=s 的报错发我"
    else
        # 明确不设置，而不是留空让 defconfig 自己猜。
        # 注意：Makefile 用 ifneq ($(CONFIG_PACKAGE_smartdns-ui),) 判断，
        # 所以只要符号存在（哪怕是 =m）就会编 webui；彻底关闭必须是 not set。
        disable_pkg smartdns-ui
        info "smartdns-ui：不构建（0）。省掉 node/host、rust/host、bindgen、npm、cargo"
        info "需要 Web 仪表盘时：跑一次 diy_smartdns_ui=m 拿 apk，或 =1 直接进固件"
    fi

    # ===== 关键：必须用 ImmortalWrt 那份界面，否则"故障转移/备用服务器"出不来 =====
    # 三个来源实测对比（行数 / fallback 开关）：
    #   feeds/luci 的 luci-app-smartdns  1.2023.42   1177 行   0 处   ← 2023 年，太老
    #   你的分支 package/luci             48.4        1685 行   0 处   ← 官方同步版，也没有
    #   ImmortalWrt 的 luci-app-smartdns  1.2025.47.2 1785 行   3 处   ← 只有这个有！
    #
    # 这就是 xg-040g-md（ImmortalWrt）界面上有"备用服务器"而你的没有的原因：
    # ImmortalWrt 那边的界面比 pymumu 官方仓库自带的还新一版，多了
    #   s.taboption("advanced", form.Flag, "fallback", _("Fallback"), ...)
    # 且中文 po 把 Fallback 译作「备用服务器」——正是你在找的那个词。
    #
    # 后端不需要换：你的 48.4 init.d 第 236 行就读 uci 的 "fallback"，
    # src/dns_client.c 也有 fallback group 的切换逻辑，只差界面上的一个开关。
    # 所以只替换 JS + po，包本体仍用 feeds 的。
    LUCI_JS=feeds/luci/applications/luci-app-smartdns/htdocs/luci-static/resources/view/smartdns/smartdns.js
    if [ ! -f "$LUCI_JS" ]; then
        warn "找不到 $LUCI_JS，跳过界面同步（luci-app-smartdns 可能没装）"
    else
        # 走 raw.githubusercontent 直取两个文件，不用克隆整个 immortalwrt/luci
        # （那个 tarball 近 30 MB）。commit 固定，避免 master 变动导致构建漂移。
        IMM_LUCI_REF="${IMM_LUCI_REF:-17f97c0bec190e18d4884ab8204f63c64981edd7}"
        IMM_BASE="https://raw.githubusercontent.com/immortalwrt/luci/${IMM_LUCI_REF}/applications/luci-app-smartdns"
        rm -rf /tmp/imm-smartdns-luci && mkdir -p /tmp/imm-smartdns-luci
        curl -fsSL --retry 2 --max-time 120 -o /tmp/imm-smartdns-luci/smartdns.js \
            "${IMM_BASE}/htdocs/luci-static/resources/view/smartdns/smartdns.js"
        curl -fsSL --retry 2 --max-time 120 -o /tmp/imm-smartdns-luci/smartdns.po \
            "${IMM_BASE}/po/zh_Hans/smartdns.po"

        NEW_JS=/tmp/imm-smartdns-luci/smartdns.js
        if [ -s "$NEW_JS" ]; then
            cp "$NEW_JS" "$LUCI_JS"
            info "LuCI 界面已同步为 ImmortalWrt 1.2025.47.2（$(wc -l < "$LUCI_JS") 行，含 fallback 开关）"
        else
            warn "下载 ImmortalWrt 界面失败，沿用 feeds 老界面（会缺「备用服务器」）"
        fi
        # 中文翻译同样用 ImmortalWrt 那份（296 条，含 Fallback → 备用服务器）。
        # 你分支自带的是 274 条，没有 Fallback 这个词条，会显示成英文。
        NEW_PO=/tmp/imm-smartdns-luci/smartdns.po
        PO_DIR=feeds/luci/applications/luci-app-smartdns/po
        if [ -s "$NEW_PO" ] && [ -d "$PO_DIR/zh_Hans" ]; then
            cp "$NEW_PO" "$PO_DIR/zh_Hans/smartdns.po"
            info "已同步中文翻译（$(grep -c msgid "$NEW_PO") 条，含「备用服务器」）"
        fi
        rm -rf /tmp/imm-smartdns-luci
    fi
fi

# ------------------------------------------------------------ 4. OpenClash
if [ "$DIY_OPENCLASH" = 1 ]; then
    rm -rf package/OpenClash
    git clone --depth 1 https://github.com/vernesong/OpenClash.git package/OpenClash
    test -f package/OpenClash/luci-app-openclash/Makefile ||
        die "OpenClash 目录结构变了，找不到 luci-app-openclash/Makefile"
    # DEPENDS: +dnsmasq-full +bash +curl +ca-bundle +ip-full +ruby +ruby-yaml +kmod-tun +unzip
    # luci-compat 在官方 luci feed 的 modules/ 下还留着，turboacc 也硬依赖它，
    # 一并显式勾上，省得 defconfig 静默丢包。
    force_pkg luci-app-openclash ruby ruby-yaml bash curl unzip ip-full luci-compat
    info "OpenClash $(sed -n 's/^PKG_VERSION:=//p' package/OpenClash/luci-app-openclash/Makefile) 已就位"
fi

# ------------------------------------------------------------ 5. TurboACC
# 注意这个脚本会做三件有副作用的事：
#   1) 删除并用 chenmozhijin 的版本替换 package/network/config/firewall4、
#      package/network/utils/nftables、package/libs/libnftnl（fullcone 需要补丁版）；
#   2) 给 target/linux/generic 打 952/953/613 三个内核补丁；
#   3) 往 target/linux/generic/config-6.18 追加 NF_CONNTRACK_CHAIN_EVENTS。
# --no-sfe 跳过 shortcut-fe（953 补丁）：本机已经有原生 flowtable 硬件加速
# （port/overlay 里的 190-native-flowtable.patch / 205-flowtable-pppoe-session.patch），
# 再叠一层 SFE 是抢同一条路径，编不编得过、编出来稳不稳都不划算。
if [ "$DIY_TURBOACC" = 1 ]; then
    rm -rf package/turboacc
    curl -fsSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh \
        -o /tmp/add_turboacc.sh
    bash /tmp/add_turboacc.sh --no-sfe
    rm -f /tmp/add_turboacc.sh
    test -d package/turboacc || die "turboacc 装载失败（package/turboacc 不存在）"
    # 符号名与 ImmortalWrt 的 CONFIG_PACKAGE_TURBOACC_INCLUDE_* 不同，
    # 这里是 chenmozhijin 的 luci-app-turboacc_INCLUDE_*，别照抄 xg 那份配置。
    force_pkg luci-app-turboacc
    printf '%s\n' \
        'CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_BBR_CCA=y' \
        'CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING=y' \
        'CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_NFT_FULLCONE=y' \
        '# CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_SHORTCUT_FE is not set' \
        '# CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_SHORTCUT_FE_CM is not set' \
        '# CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_SHORTCUT_FE_DRV is not set' \
        >> "$TREE/.config"
    info "turboacc 已装载（BBR + flow offload + fullcone，不带 SFE）"
fi

# ------------------------------------------------------- 6. argon 主题：不要自己装
# 上游 v0.8.0-beta 起，argon 由 scripts/prepare_luci_feeds.sh 统一处理：
#   - 从 port/sources.lock.json 里锁定的 jerrykuku/luci-theme-argon commit
#     checkout 到 feeds/luci-theme-argon，再软链到 package/luci-theme-argon；
#   - 该仓库的 compat/ 目录自带 luci-app-argon-config，所以
#     luci-i18n-argon-config-zh-cn 也一并有了；
#   - 最后强制往 .config 追加
#       CONFIG_PACKAGE_luci-theme-argon=y
#       CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y
#       CONFIG_LUCI_LANG_zh_Hans=y
# 而 build.sh 会校验这三个（+ luci-app-tyfza1-pon）在 defconfig 后仍为 y，缺一个就
# exit 1："Required firmware package missing after defconfig: ..."
#
# ⚠ 所以这里千万别再 git clone argon：
#   prepare_luci_feeds.sh 里有
#     if [ -e package/luci-theme-argon ] && [ ! -L package/luci-theme-argon ]; then
#         echo "package/luci-theme-argon already exists and is not a managed symlink" >&2
#         exit 1
#     fi
#   我们自己 clone 出来的是真实目录（不是软链接），会直接把构建打断。
# 结论：argon 归上游，本脚本什么都不做。

# ------------------------------------------ 7. 可选：动态域名（ddns-scripts）
# 用官方 feeds 的 ddns-scripts + luci-app-ddns。
#
# 为什么不用 ddns-go（2026-10-19 实测后改回）：
#   读 port/overlay/.../base-files/lib/upgrade/tyfza1-storage.sh 的分配算法：
#     TYFZA1_DATA_BYTES = (free + root_ebs + data_ebs) * leb - TYFZA1_ROOT_BYTES
#   即可写空间 = 总池子 - rootfs.squashfs（对齐到 LEB）；root 越大可写越少，
#   同一个池子里此消彼长。而脚本开头明确写着：
#     "Only the selected OpenWrt root and rootfs_data participate in allocation.
#      Keep every OEM volume ... at its original size."
#   所以刷机日志里那个 94 MiB 的 ubi_apps（ubi0:10）是 OEM 卷、被原样保留用于
#   回退，OpenWrt 装包根本用不到它。官方 RELEASE_NOTES 的"约 34.6 MiB"是
#   在官方那份精简 rootfs 下测的。
#   实测：rootfs 19.56 MiB + rootfs_data 14.9 MiB ≈ 34.5 MiB 总池子；
#   再塞 ddns-go（Go 二进制 8~12 MB）就把可写空间压到只剩 16 MiB。
#   ddns-scripts 全套几百 KB，Cloudflare + IPv6 需要的功能都有（见下）。
#
# 功能上完全够用（逐条对过源码）：
#   - 10 分钟轮询 + hotplug 网口事件即时触发（ifup/ifdown/ifupdate）
#   - IP 未变不发请求（Cloudflare 脚本逐位比对后跳过）
#   - 失败按 60 秒重试，而不是傻等 10 分钟
#   - use_ipv6=1 自动走 AAAA，curl 强制 -6
#   - 更新后用 resolveip 反查域名做 DNS 验证，确认真的生效
#
# 包名与依赖（官方 feeds，均已核实）：
#   ddns-scripts            2.8.4  DEPENDS: +ddns-scripts-services +resolveip +ip
#   ddns-scripts-cloudflare        DEPENDS: ddns-scripts +curl
#   luci-app-ddns                  LUCI_DEPENDS: +luci-base +ddns-scripts
#                                                +ucode-mod-math
if [ "$DIY_DDNS" = 1 ]; then
    # Cloudflare 扩展和 LuCI 界面都在 feeds 里，但要确保它们进了源码树：
    # prepare_luci_feeds.sh 只装 .config 里 CONFIG_PACKAGE_*=[ym] 列出的包，
    # 而这里的开关是在 defconfig 之后才写入 .config 的，所以得手动 install。
    ./scripts/feeds install ddns-scripts ddns-scripts-cloudflare \
        luci-app-ddns ucode-mod-math

    # 依赖说明：
    #   ddns-scripts-services / resolveip / ip  → 主包 DEPENDS 自动带，不用写
    #   curl                                   → ddns-scripts-cloudflare 自动带
    #   ca-bundle                              → tyfza1-compat.config 已强制 =y
    force_pkg ddns-scripts ddns-scripts-cloudflare luci-app-ddns \
              luci-i18n-ddns-zh-cn curl resolveip ucode-mod-math
    info "DDNS（ddns-scripts 2.8.4 + luci-app-ddns + cloudflare 扩展）已就位"
    echo "  刷完机后：服务 → 动态 DNS，按你的 WAN/LAN 接口配 use_ipv6=1"
    echo "  ⚠ PPPoE 场景下公网 IPv6 通常在 LAN 口，ip_network 可能要填 br-lan"
fi

# ------------------------------------------------------------------ 8. 收尾
info "diy-part.sh 完成。接下来 build.sh 会执行 prepare_luci_feeds -> make defconfig"
cat <<'EOF'

提醒：
  1) 源码树里不存在的包，make defconfig 会静默丢行、不报错。
     编完去 artifacts/build.log / bin/packages 核对 luci-app-openclash、
     luci-app-smartdns、luci-app-turboacc、ddns-scripts 是否真的编出来了。
  2) rootfs.squashfs 仍有硬上限 33648640 字节（约 32.09 MiB，原厂 rootfs 卷大小），
     超了会在打包镜像那一步失败（port/overlay/.../image/Makefile）。
     OpenClash 带的 ruby 是体积大头，超了先砍它，再砍 fullcone。
  3) port/configs/tyfza1-compat.config 里的 CONFIG_PACKAGE_*=y 是【强制项】：
     sync-overlay.sh 先删后写强制 =y，build.sh 再校验必须存在。想瘦身去改那份
     文件（同步改，两边读的是同一个），别在 .config 里挣扎。
  4) luci-theme-argon / luci-i18n-argon-config-zh-cn 由 prepare_luci_feeds.sh
     强制追加，本脚本不碰（碰了会让构建直接退出，见第 6 步注释）。
  5) 无线默认【保留】（DIY_WIRELESS=1）。关掉（=0）改的是 overlay 源的
     DEVICE_PACKAGES，且无法事后装回——kmod-rtl-ax-ap 里的 rtl_ax_ap.ko 是
     上游私有驱动，官方源 / ImmortalWrt 都没有，PE 固件也是编译时注入的。
     只是暂时不想用 Wi-Fi 的话，别关包，刷完在 LuCI 里禁用 radio 即可。
  6) 【可写空间】v0.8.2 起由 tyfza1-storage 的 factory-v1 迁移决定：首次启动时
     tyfza1-migrate-storage 删掉 ubi_Config / ubi_apps / ubi_fpga / 非活动槽
     kernel+rootfs / framework 卷，把空间全部给 rootfs_data，再把原厂配置和
     应用数据压成两份副本存进 ubi 卷 12/13。
     RELEASE_NOTES 给的模拟值：全千兆版约 189.6 MiB、2.5G 版约 191.1 MiB
     （v0.8.0 时只有 16 MiB）。所以现在塞插件基本不用再斤斤计较。
     注意：迁移是一次性的、且不可逆（原厂系统卷被移除，回退靠 12/13 两份副本）。
EOF
