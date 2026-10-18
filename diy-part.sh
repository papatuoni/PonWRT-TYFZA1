#!/usr/bin/env bash
#
# ============================================================================
#  PonWRT-TYFZA1 · diy-part.sh
#  天翼 TYFZA1 / Realtek RTL9617CVW —— 自定义编译步骤
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
#    DIY_ARGON=0     可选主题（官方 luci feed 里没有 argon，需要第三方源码）
#    DIY_LAN_IP=192.168.2.1
# ============================================================================
set -eu

DIY_LAN_IP="${DIY_LAN_IP:-192.168.2.1}"
DIY_TURBOACC="${DIY_TURBOACC:-1}"
DIY_OPENCLASH="${DIY_OPENCLASH:-1}"
DIY_SMARTDNS="${DIY_SMARTDNS:-1}"
DIY_ARGON="${DIY_ARGON:-0}"
DIY_DDNS="${DIY_DDNS:-0}"
# smartdns Web 仪表盘（Rust 插件 smartdns_ui.so + 前端 wwwroot）。
# 编译成本高（Rust 依赖多），默认关；确认基线没问题后再开。
DIY_SMARTDNS_UI="${DIY_SMARTDNS_UI:-0}"

# 你的 smartdns 分支：改这里就能换源码，不用动 workflow
SMARTDNS_REPO="${SMARTDNS_REPO:-papatuoni/smartdns}"
SMARTDNS_REF="${SMARTDNS_REF:-custom-48.4}"

# ImmortalWrt 源（ddns-go / luci-app-ddns-go 从这里取）
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

# ---- 2a. dnsmasq-full（OpenClash 硬依赖，nftset 走 nftables 那条路）----------
# dnsmasq 与 dnsmasq-full 互斥，只留 full；nftset 会把 nftables-json 带进来。
disable_pkg dnsmasq
force_pkg dnsmasq-full dnsmasq_full_nftset dnsmasq_full_dnssec
info "DNS：dnsmasq -> dnsmasq-full（nftset + dnssec 打开）"

# ---- 2b. 代理相关的内核模块 ------------------------------------------------
# xg-040g-md.config 里那段注释说得对，这里照搬并写死：kmod 带内核 vermagic 哈希，
# 刷完机再 apk add 是装不上的（官方源那份对不上自建固件），必须编进镜像。
# 整组加起来约 40 KB，但少了它们 sing-box / clash 的 tun、tproxy、ss 全废。
# OpenWrt 的 package-metadata.pl 会把这些包的 KCONFIG 写进 kernel .config，
# 不需要自己去改 config-6.18。
force_pkg \
    kmod-nft-core kmod-nft-nat kmod-nf-flow kmod-nft-offload kmod-nfnetlink \
    kmod-nft-tproxy kmod-nft-socket kmod-nf-socket \
    kmod-tun kmod-inet-diag kmod-netlink-diag kmod-br-netfilter
info "已强制保留代理相关内核模块（tproxy / nft-socket / tun / inet-diag / netlink-diag）"

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
    if [ "$DIY_SMARTDNS_UI" = 1 ]; then
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

        force_pkg smartdns-ui
        info "smartdns-ui（Web 仪表盘）已启用：前端 npm 构建 + Rust 后端"
        warn "这一步很慢：要编 node/host、rust/host、bindgen，再 npm build + cargo build"
        warn "可能额外 30~60 分钟；失败就把 V=s 的报错发我"
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

# ------------------------------------------------------- 6. 可选：argon 主题
# 官方 luci feed 没有 argon。jerrykuku 那两份用的是 include ../../luci.mk，
# 直接丢在 package/ 下会解析到不存在的路径，所以顺手改成绝对路径。
if [ "$DIY_ARGON" = 1 ]; then
    for r in luci-theme-argon luci-app-argon-config; do
        rm -rf "package/$r"
        git clone --depth 1 "https://github.com/jerrykuku/${r}.git" "package/$r"
        sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' "package/$r/Makefile"
    done
    force_pkg luci-theme-argon luci-app-argon-config
    info "argon 主题已装载"
fi

# ---------------------------------------------- 7. 可选：动态域名（ddns-go）
# 用 ImmortalWrt 的 ddns-go + luci-app-ddns-go，不再用 ddns-scripts。
#
# 换回来的原因：v0.8.0 改了存储布局（RELEASE_NOTES: "修复可写空间固定为 16 MiB…
# 实机确认可写空间扩大"）。刷机日志里能看到 ubi_apps 卷有 793 LEBs ≈ 94 MiB
# （ubi0:10 挂载成功），不再是之前那个 32 MiB rootfs / 11 MiB 可用的窘境。
# 所以之前"为了省空间只能用 ddns-scripts"的理由已经不成立。
# ddns-go 是 Go 写的，自带 Web 配置界面，支持 Cloudflare / 阿里云 / Dnspod /
# 华为云 / Callback 等十余家，比 ddns-scripts 好用得多。
#
# 包名与依赖（ImmortalWrt，均已核实）：
#   ddns-go          6.17.6  DEPENDS: $(GO_ARCH_DEPENDS) +ca-bundle
#                            PKG_BUILD_DEPENDS: golang/host   ← 关键，见下
#   luci-app-ddns-go         LUCI_DEPENDS: +ddns-go
if [ "$DIY_DDNS" = 1 ]; then
    # ===== 关键：golang 宿主工具链必须显式装进源码树 =====
    # ddns-go 的 Makefile 有 PKG_BUILD_DEPENDS:=golang/host。
    # 但 prepare_luci_feeds.sh 只装 .config 里 CONFIG_PACKAGE_*=[ym] 列出的包，
    # golang 不在其中，于是会留下一条不致命的 WARNING：
    #   WARNING: Makefile 'package/ddns-go/Makefile' has a build dependency
    #            on 'golang/host', which does not exist
    # make 会照常往下跑，直到 go 命令找不到才失败（PATH 里有
    # staging_dir/hostpkg/lib/go-1.27/bin，但那个目录压根没生成）。
    # 依赖链三层，缺一不可（scripts/feeds install 不处理 HOST_BUILD_DEPENDS）：
    #   golang/host     → golang1.27/host → golang-bootstrap/host
    ./scripts/feeds install golang golang1.27 golang-bootstrap
    for p in golang golang1.27 golang-bootstrap; do
        [ -e "package/feeds/packages/lang/golang/$p" ] ||
            warn "feeds install 后仍找不到 lang/golang/$p，golang/host 可能装不全"
    done

    # --- 本体（ImmortalWrt packages）---
    rm -rf package/ddns-go /tmp/imm-ddnsgo
    mkdir -p /tmp/imm-ddnsgo
    curl -fsSL --retry 2 --max-time 180 \
        "https://codeload.github.com/${IMM_PKGS_REPO}/tar.gz/${IMM_PKGS_REF}" \
        | tar -xz -C /tmp/imm-ddnsgo --strip-components=1 \
              --wildcards "*/net/ddns-go/*" 2>/dev/null
    if [ -f /tmp/imm-ddnsgo/net/ddns-go/Makefile ]; then
        cp -r /tmp/imm-ddnsgo/net/ddns-go package/ddns-go
    else
        die "从 ImmortalWrt 取 net/ddns-go 失败"
    fi

    # --- LuCI 界面（ImmortalWrt luci）---
    rm -rf package/luci-app-ddns-go /tmp/imm-luci-dg
    mkdir -p /tmp/imm-luci-dg
    curl -fsSL --retry 2 --max-time 300 \
        "https://codeload.github.com/${IMM_LUCI_REPO}/tar.gz/${IMM_LUCI_REF}" \
        | tar -xz -C /tmp/imm-luci-dg --strip-components=1 \
              --wildcards "*/applications/luci-app-ddns-go/*" 2>/dev/null
    if [ -f /tmp/imm-luci-dg/applications/luci-app-ddns-go/Makefile ]; then
        cp -r /tmp/imm-luci-dg/applications/luci-app-ddns-go package/luci-app-ddns-go
    else
        die "从 ImmortalWrt 取 applications/luci-app-ddns-go 失败"
    fi
    rm -rf /tmp/imm-ddnsgo /tmp/imm-luci-dg

    # 两份 Makefile 都写的是相对路径，放 package/ 下够不着，必须改成绝对路径
    sed -i 's|include ../../lang/golang/golang-package.mk|include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk|' \
        package/ddns-go/Makefile
    sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
        package/luci-app-ddns-go/Makefile

    force_pkg ddns-go luci-app-ddns-go luci-i18n-ddns-go-zh-cn ca-bundle
    info "ddns-go $(sed -n 's/^PKG_VERSION:=//p' package/ddns-go/Makefile) + luci-app-ddns-go 已就位"
    warn "ddns-go 需要编 Go 宿主工具链（golang/host），这一步很慢，可能多花 20~40 分钟"
fi

# ------------------------------------------------------------------ 8. 收尾
info "diy-part.sh 完成。接下来 build.sh 会执行 prepare_luci_feeds -> make defconfig"
cat <<'EOF'

提醒：
  1) 源码树里不存在的包，make defconfig 会静默丢行、不报错。
     编完去 artifacts/build.log / bin/packages 核对 luci-app-openclash、
     luci-app-smartdns、luci-app-turboacc 是否真的编出来了。
  2) rootfs.squashfs 仍有硬上限 33648640 字节（约 32.09 MiB，原厂 rootfs 卷大小），
     超了会在打包镜像那一步失败（port/overlay/.../image/Makefile）。
     OpenClash 带的 ruby 是体积大头，超了先砍它，再砍 fullcone。
  3) 但【可写空间】已不再是 11 MiB：v0.8.0 改了存储布局，刷机日志里
     ubi_apps 卷有 793 LEBs ≈ 94 MiB（ubi0:10）。所以 ddns-go（Go，8~12 MB）
     这类体积不再是不可接受的——这也是本版把 ddns-scripts 换回 ddns-go 的原因。
EOF
