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
DIY_DDNSGO="${DIY_DDNSGO:-0}"

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

    # 改成 git 协议直接拉分支，不再走 codeload tarball。
    # 理由：tarball 方案要同时猜对三件事——tarball 顶层目录名、PKG_BUILD_DIR、
    # PKG_HASH，任何一个对不上都会编失败，而且报错全被 make 吞掉只剩一行
    # "failed to build"。git 协议三个问题一次全消，也是 ImmortalWrt-Airoha
    # 那边用的写法。整份 Makefile 重写，不 sed 官方那份（46.1 的结构与 48.x 不同）。

    # DEPENDS 需要显式带上 +zlib。
    # src/Makefile 的 WITH_ZLIB 默认是 auto：探测到 host 有 zlib 就加 -DWITH_ZLIB
    # 并链接 -lz。于是二进制 NEEDED 里有 libz.so.1，而官方 46.1 那份 Makefile 的
    # DEPENDS 只有 libpthread/libopenssl，打包 apk 时 OpenWrt 找不到 libz.so.1
    # 的提供者，直接报：
    #   Package smartdns is missing dependencies for the following libraries: libz.so.1
    # 注意失败发生在"打 apk"这一步，不是编译——所以 src/smartdns 其实已经编出来了，
    # 日志里能看到 install 到 ipkg 的全过程，很容易被误导成编译问题。
    #
    # 另外别加 +libatomic：src/Makefile 里的 -latomic 只在 USE_ATOMIC 探测失败时才加，
    # 而 aarch64 上 __atomic_* 是编译器内联的，探测必然通过；凭空加一个树里可能
    # 不存在的 DEPENDS，反而会让 defconfig 把 smartdns 整包静默丢掉。
    cat > "$SD_MK" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=smartdns
PKG_VERSION:=48.4
PKG_RELEASE:=1

# git 协议：直接跟分支，永远拿到分支 HEAD，不受 tag/tarball 命名影响
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/${SMARTDNS_REPO}.git
PKG_SOURCE_VERSION:=${SMARTDNS_REF}
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=Nick Peng <pymumu@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_PARALLEL:=1

include \$(INCLUDE_DIR)/package.mk

MAKE_VARS += VER=\$(PKG_VERSION)
MAKE_PATH:=src

define Package/smartdns
  SECTION:=net
  CATEGORY:=Network
  TITLE:=smartdns server
  SUBMENU:=IP Addresses and Names
  DEPENDS:=+libpthread +libopenssl +zlib
  URL:=https://www.github.com/pymumu/smartdns/
endef

define Package/smartdns/description
SmartDNS is a local DNS server which accepts DNS query requests from local network clients,
gets DNS query results from multiple upstream DNS servers concurrently, and returns the fastest IP to clients.
endef

define Package/smartdns/conffiles
/etc/config/smartdns
/etc/smartdns/address.conf
/etc/smartdns/blacklist-ip.conf
/etc/smartdns/custom.conf
/etc/smartdns/domain-block.list
/etc/smartdns/domain-forwarding.list
endef

define Package/smartdns/install
	\$(INSTALL_DIR) \$(1)/usr/sbin \$(1)/etc/config \$(1)/etc/init.d
	\$(INSTALL_DIR) \$(1)/etc/smartdns \$(1)/etc/smartdns/domain-set \$(1)/etc/smartdns/conf.d/
	\$(INSTALL_DIR) \$(1)/etc/smartdns/ip-set \$(1)/etc/smartdns/download
	\$(INSTALL_BIN) \$(PKG_BUILD_DIR)/src/smartdns \$(1)/usr/sbin/smartdns
	\$(INSTALL_BIN) \$(PKG_BUILD_DIR)/package/openwrt/files/etc/init.d/smartdns \$(1)/etc/init.d/smartdns
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/address.conf \$(1)/etc/smartdns/address.conf
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/blacklist-ip.conf \$(1)/etc/smartdns/blacklist-ip.conf
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/custom.conf \$(1)/etc/smartdns/custom.conf
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/domain-block.list \$(1)/etc/smartdns/domain-block.list
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/domain-forwarding.list \$(1)/etc/smartdns/domain-forwarding.list
	\$(INSTALL_CONF) \$(PKG_BUILD_DIR)/package/openwrt/files/etc/config/smartdns \$(1)/etc/config/smartdns
endef

\$(eval \$(call BuildPackage,smartdns))
EOF

    info "smartdns 源码 -> ${SMARTDNS_REPO}@${SMARTDNS_REF}（git 协议）"
    grep -E '^(PKG_SOURCE_PROTO|PKG_SOURCE_URL|PKG_SOURCE_VERSION|PKG_MIRROR_HASH):=' "$SD_MK" | sed 's/^/    /'
    force_pkg smartdns luci-app-smartdns zlib
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

# ---------------------------------------------- 7. 可选：ddns-go（动态域名）
# 官方两个 feed 里都没有它：packages 只有 ddns-scripts（那个是配 luci-app-ddns 用的），
# luci feed 里也只有 luci-app-ddns。所以要么从 ImmortalWrt 搬两份，要么用 sirpdboy
# 这个仓库 —— 后者更好：一个 clone 就同时拿到本体和界面，而且两份 Makefile 都已经
# 写成绝对路径（$(TOPDIR)/feeds/...），开箱即用，不用像 ImmortalWrt 那样改 include。
#
#   sirpdboy/luci-app-ddns-go
#     ├── ddns-go/           Go 守护进程本体（上游 jeessy2/ddns-go，6.17.1）
#     └── luci-app-ddns-go/  LuCI 界面（JS 版，兼容 24.10，自带 po/zh_Hans）
#
# 唯一要注意的：它依赖 feeds/packages/lang/golang/golang-package.mk 提供
# GoBinPackage / GO_ARCH_DEPENDS。官方 packages feed 里确实有（golang 1.27），
# 但 golang 属于 host 工具链，feeds 得先 update 过。
if [ "$DIY_DDNSGO" = 1 ]; then
    DDNSGO_SRC="${DDNSGO_SRC:-https://github.com/sirpdboy/luci-app-ddns-go.git}"
    rm -rf /tmp/sirpdboy-ddnsgo
    git clone --depth 1 "$DDNSGO_SRC" /tmp/sirpdboy-ddnsgo >/dev/null 2>&1 ||
        die "克隆 $DDNSGO_SRC 失败"

    # --- 本体 ---
    rm -rf package/ddns-go
    [ -f /tmp/sirpdboy-ddnsgo/ddns-go/Makefile ] ||
        die "仓库里找不到 ddns-go/Makefile，上游目录结构变了"
    cp -r /tmp/sirpdboy-ddnsgo/ddns-go package/ddns-go

    # --- LuCI 界面 ---
    rm -rf package/luci-app-ddns-go
    [ -f /tmp/sirpdboy-ddnsgo/luci-app-ddns-go/Makefile ] ||
        die "仓库里找不到 luci-app-ddns-go/Makefile，上游目录结构变了"
    cp -r /tmp/sirpdboy-ddnsgo/luci-app-ddns-go package/luci-app-ddns-go

    # 保险：sirpdboy 现在写的是绝对路径，万一哪天改回相对路径，这里兜住
    sed -i 's|include ../../lang/golang/golang-package.mk|include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk|' \
        package/ddns-go/Makefile
    sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' \
        package/luci-app-ddns-go/Makefile

    # ===== 关键：必须把 golang 宿主工具链装进源码树 =====
    # ddns-go 的 Makefile 有 PKG_BUILD_DEPENDS:=golang/host。
    # 但 build.sh 里的 prepare_luci_feeds.sh 只装 .config 里 CONFIG_PACKAGE_*=[ym]
    # 列出的包（外加 cgi-io/luasrcdiet/luci），golang 不在其中，于是：
    #   WARNING: Makefile 'package/ddns-go/Makefile' has a build dependency
    #            on 'golang/host', which does not exist
    # 这个 WARNING 不致命，make 会照常往下跑，直到 go 命令找不到才失败 ——
    # 表现就是 V=s 日志里 PATH 指向 staging_dir/hostpkg/lib/go-1.27/bin
    # 但那个目录压根没生成。
    # 依赖链必须三层都装上，缺一不可：
    #   golang/host        → HOST_BUILD_DEPENDS:=golang1.27/host
    #   golang1.27/host    → HOST_BUILD_DEPENDS:=golang-bootstrap/host
    # （GO_BOOTSTRAP_VERSION:=bootstrap，由 golang1.27/Makefile 第 13 行定义）
    ./scripts/feeds install golang golang1.27 golang-bootstrap
    for p in golang golang1.27 golang-bootstrap; do
        [ -e "package/feeds/packages/lang/golang/$p" ] ||
            warn "feeds install 后仍找不到 lang/golang/$p，golang/host 可能装不全"
    done

    rm -rf /tmp/sirpdboy-ddnsgo
    # rpcd-mod-ucode 必须显式勾上：这个 LuCI 界面是 JS/ucode 版，
    # 它把 ubus 后端实现放在 root/usr/share/rpcd/ucode/luci.ddns-go（ucode 脚本）。
    # 该目录只有装了 rpcd-mod-ucode 才会被 rpcd 加载；sirpdboy 的 Makefile 里
    # LUCI_DEPENDS 只写了 +ddns-go，不会自动带上它。缺了这个包，界面能打开但
    # 所有 ubus 调用失败 —— 读不到配置、也启停不了服务。包很小，几十 KB。
    force_pkg ddns-go luci-app-ddns-go luci-i18n-ddns-go-zh-cn ca-bundle rpcd-mod-ucode
    info "ddns-go $(sed -n 's/^PKG_VERSION:=//p' package/ddns-go/Makefile) + " \
         "luci-app-ddns-go $(sed -n 's/^PKG_VERSION:=//p' package/luci-app-ddns-go/Makefile) 已就位"
    warn "ddns-go 需要编 Go 宿主工具链（golang/host），这一步很慢，可能要多花 20~40 分钟"
    warn "Go 程序体积不小（约 8~12 MB）；rootfs 上限 32.09 MiB，当前已用约 19 MB，超了先砍 ruby"
fi

# ------------------------------------------------------------------ 8. 收尾
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
