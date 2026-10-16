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

# 你的 smartdns 分支：改这里就能换源码，不用动 workflow
SMARTDNS_REPO="${SMARTDNS_REPO:-papatuoni/smartdns}"
SMARTDNS_REF="${SMARTDNS_REF:-custom-48.4}"

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
# 上游 boot.config 显式关掉了版本号进文件名。漏掉这行会 default y（因为
# VERSIONOPT=y），镜像名变成 openwrt-0.3.1-alpha--rtl9617c-generic-...，
# 中间那道多余的横线就是 IMG_PREFIX_EXTRA 在 EXTRA_IMAGE_NAME 为空时留下的。
grep -q '^# CONFIG_VERSION_FILENAMES is not set$' "$TREE/.config" ||
    printf '# CONFIG_VERSION_FILENAMES is not set\n' >> "$TREE/.config"
info "已锁定 target/设备，并关闭 VERSION_FILENAMES"

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

    # 官方 feed 这份 Makefile 是 46.1（tarball + PKG_HASH），
    # 你的 custom-48.4 里那份用的是 git 协议 + rust，两者结构不同。
    # 这里沿用官方 feed 的 Makefile（不碰 rust/webui 那一堆），
    # 只把源码来源指向你的仓库，等价于 ImmortalWrt-Airoha 里的做法。
    sed -i \
        -e 's|^PKG_SOURCE:=.*|PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)-custom.tar.gz|' \
        -e "s|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://codeload.github.com/${SMARTDNS_REPO}/tar.gz/${SMARTDNS_REF}?|" \
        -e "s|^PKG_BUILD_DIR:=.*|PKG_BUILD_DIR:=\$(BUILD_DIR)/\$(PKG_NAME)-${SMARTDNS_REF}|" \
        -e 's|^PKG_HASH:=.*|PKG_HASH:=skip|' \
        -e 's|^PKG_MIRROR_HASH:=.*|PKG_MIRROR_HASH:=skip|' \
        "$SD_MK"

    # 48.x 的 DEPENDS 带 libatomic，官方 46.1 那行没有，补上免得运行时缺符号
    grep -q '+libatomic' "$SD_MK" ||
        sed -i 's|^  DEPENDS:=+libpthread +libopenssl|& +libatomic|' "$SD_MK"

    # 版本号仍是 feed 里的 46.1（只影响 smartdns -v 显示）；想跟着你的分支走，
    # 在上面再加一行：sed -i 's|^PKG_VERSION:=.*|PKG_VERSION:=1.2025.46.2|' "$SD_MK"
    info "smartdns 源码 -> ${SMARTDNS_REPO}@${SMARTDNS_REF}"
    grep -E '^(PKG_SOURCE|PKG_SOURCE_URL|PKG_BUILD_DIR|PKG_HASH):=' "$SD_MK" | sed 's/^/    /'
    force_pkg smartdns luci-app-smartdns
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

# ------------------------------------------------------------------ 7. 收尾
info "diy-part.sh 完成。接下来 build.sh 会执行 prepare_luci_feeds -> make defconfig"
cat <<'EOF'

提醒：
  1) 源码树里不存在的包，make defconfig 会静默丢行、不报错。
     编完去 artifacts/build.log / bin/packages 核对 luci-app-openclash、
     luci-app-smartdns、luci-app-turboacc 是否真的编出来了。
  2) rootfs.squashfs 硬上限 33648640 字节（约 32.09 MiB，原厂 UBI 卷大小），
     超了会在打包镜像那一步直接失败（port/overlay/.../image/Makefile）。
     OpenClash 带的 ruby 是体积大头，超了先砍它，再砍 fullcone。
EOF
