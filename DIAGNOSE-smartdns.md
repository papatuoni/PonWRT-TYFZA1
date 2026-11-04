# smartdns 卡顿诊断：把 addr2line 和全部核对搬进 GitHub Actions

## 为什么必须放进 Actions

你原来那条命令在本地跑不出结果，三个原因都和"本地"有关：

```sh
LIBC=$(find ~/PonWRT-TYFZA1/sources/openwrt -name 'libc.so*' -path '*toolchain*' | head -1)
aarch64-openwrt-linux-musl-addr2line -Cfipe "$LIBC" 0x62a98
```

1. **路径不对**：CI 里工作目录是 `/home/runner/work/PonWRT-TYFZA1/PonWRT-TYFZA1`，不是 `~/PonWRT-TYFZA1`；应该用 `$GITHUB_WORKSPACE/sources/openwrt`。
2. **没有工具链**：`aarch64-openwrt-linux-musl-addr2line` 只在 `make toolchain/compile` 之后才出现在 `staging_dir/toolchain-*/bin/`，本地/路由器上都没有。
3. **找到的可能是 strip 过的 libc**：设备上 `/lib/libc.so` 没有 `.symtab`，`addr2line` 只会回 `?? ??:0`。要用构建树里的未 strip 版本（`build_dir/toolchain-*/musl-*/libc.so` 或 `staging_dir/toolchain-*/lib/libc.so`），strip 只删符号、不改 `.text` 布局，用它解析是合法的。

所以这次交付的是 **CI 侧一整套流程**，不改 smartdns 源码、不出新补丁、不刷机。

---

## 四个文件放进仓库的位置

| 本包文件 | 放到仓库 | 作用 |
|---|---|---|
| `DIAGNOSE-smartdns.md` | `DIAGNOSE-smartdns.md`（根目录） | 本说明 |
| `smartdns-diagnose.yml` | `.github/workflows/smartdns-diagnose.yml` | 独立诊断工作流 |
| `diagnose_smartdns.sh` | `scripts/diagnose_smartdns.sh` | 核心诊断脚本，两个工作流共用 |
| `build-release-diagnose.patch` | 对 `.github/workflows/build-release.yml` 打 | 编译完成后自动跑诊断（零额外编译） |

```sh
cd PonWRT-TYFZA1
cp <下载目录>/smartdns-diagnose.yml .github/workflows/
cp <下载目录>/diagnose_smartdns.sh   scripts/
cp <下载目录>/DIAGNOSE-smartdns.md   .
git apply <下载目录>/build-release-diagnose.patch
git add .github/workflows/smartdns-diagnose.yml scripts/diagnose_smartdns.sh \
        DIAGNOSE-smartdns.md .github/workflows/build-release.yml
git commit -m "ci: smartdns stall diagnosis (addr2line + source audit)"
git push
```

`build-release-diagnose.patch` 已用 `patch -p1 --dry-run --fuzz=0` 验证过；打完后的 YAML 也过了解析校验。

---

## 用法 A：挂到现有固件构建（推荐，零额外编译）

`Build TYFZA1 firmware` 跑完后，`make world` 已经生成了：

```
sources/openwrt/staging_dir/toolchain-*/bin/aarch64-openwrt-linux-musl-addr2line
sources/openwrt/build_dir/toolchain-*/musl-*/libc.so        （未 strip）
sources/openwrt/build_dir/target-*/smartdns-48.4/src/        （真实源码）
sources/openwrt/build_dir/target-*/smartdns-48.4/src/smartdns （带符号二进制）
```

补丁在"校验关键包确实编入"之后插入一个 `if: always()` 的步骤，直接调 `scripts/diagnose_smartdns.sh`。**编译成功、失败都会出报告**；脚本自身不 `make`、不掩盖原失败（退出码恒 0）。

结果在两个地方：

- Actions 页的 **Step Summary**（`smartdns 卡顿诊断` 这一步）
- artifact `smartdns-diagnose-report`（保留 14 天）

`workflow_dispatch` 新增 4 个可选输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `diag_libc_offsets` | `0x62a98 0x61dbc 0x3b2a8` | 设备上三个 pc 的段内偏移 |
| `diag_smartdns_offsets` | 空 | `stack-scan.sh` 拿到的业务帧返回地址 |
| `diag_device_libc_sha256` | 空 | 设备上 `sha256sum /lib/libc.so` |
| `diag_device_smartdns_md5` | 空 | 设备上 `md5sum /usr/sbin/smartdns` |

后两个填了才会做"设备↔构建"一致性校验，**强烈建议填**：偏移只有在同一版 libc 下才有效。

## 用法 B：只跑诊断，不编整套固件

Actions → **Diagnose smartdns stall** → Run workflow。

它复用 `prepare.sh` / `diy-part.sh` / `sync-overlay.sh` / `prepare_luci_feeds.sh`，与真实固件**同一份 .config、同一个 toolchain**，但把 `make world` 换成：

```
make defconfig
make toolchain/compile -j$(nproc) V=s
make package/feeds/packages/smartdns/compile V=s -j1
```

省掉内核、rootfs、PE 固件和打包，只为了拿到带符号 libc + 带符号 smartdns。输入项比用法 A 多三个：

| 输入 | 默认 | 说明 |
|---|---|---|
| `smartdns_ref` | `custom-48.4-dulwandiy` | 传给 `diy-part.sh`，解析成 40 位 SHA |
| `cache_toolchain` | `1` | 缓存 `build_dir/toolchain-*` 加速；结果诡异时设 `0` 清缓存重跑 |
| 其余 5 个 | 同用法 A | 偏移、设备校验值、是否缓存 |

> 两个工作流都**不会**重新下载 runtime-inputs / FIT 签名材料，也不跑 `port/scripts/build.sh`，所以不需要 `TYFZA1_FIT_SIGNING_KEY`，也不会踩 `gh release download v0.1.0-alpha` 那个需要登录的坑。

---

## "都编写进去"了什么（`scripts/diagnose_smartdns.sh` 八节）

| 节 | 内容 |
|---|---|
| **0** | 定位 OpenWrt 工具链 `addr2line/nm/readelf`；LLVM-18 的 `llvm-addr2line` / `llvm-symbolizer` / `llvm-nm` / `llvm-readelf` 作为交叉验证与兜底 |
| **1** | 遍历所有 `libc.so*`，用 `.symtab` 挑出未 strip 的符号版；另挑 rootfs 版（strip 后）用于设备 sha256 比对；打印 **Build ID** 与 **LOAD 段 offset**（确认设备 `fileoff=0` 的偏移可直接当文件偏移用） |
| **2 ★** | 三个偏移跑 `addr2line -Cfipe` + `llvm-addr2line` + `llvm-symbolizer` + `nm` 最近符号，自动判定 `pthread_join` / `pthread_cond_wait` / `mutex` / `pthread_once` / `sem_wait` |
| **3** | smartdns 带符号二进制：`nm` 导出 `route_cache_*`、`_dns_server_process_neighbor_cache_event`、`netlink_neighbor_lock`、`has_unprivileged_ping4/6`、`fast_ping_bind_apply`、`prefetch` 符号表；业务帧偏移 addr2line；设备 md5 比对 |
| **4** | `PKG_SOURCE_PROTO/URL/VERSION/MIRROR_HASH` 实值；`dl/smartdns*` 缓存列表（`PKG_MIRROR_HASH=skip` 时存在即复用、不校验、不重下的坑） |
| **5** | 重整落地核对：`route_mgr.c/.h` 已删、`dualwan-egress`/`multi-wan-egress` 计数为 0、`route_cache.c` 在位、`DOMAIN_RULE_CACHE_GROUP` 配套、跨组两步兜底、`has_unprivileged_ping4/6` 声明+定义、按出口测速；**全 src 扫描行首 `+`/`-` diff 标记残留**（Build #54 的 `+static int _fast_ping_open_icmp_sock` 事故）、`ping_icmp.c` 花括号平衡 |
| **6** | 根因链源码证据：`local_addr.c` 的 `RTMGRP_IPV6_IFADDR\|IPV4_IFADDR`(0x110) → fd13、`neighbor.c` 的 `RTMGRP_NEIGH`(0x4) → fd14、`dns_server.c` 主 epoll 注册/回调、`neighbors.c` 的 `netlink_neighbor_lock` 与 dump 循环；并判定**修复是否落地**（ENOBUFS 分支不再同步 dump、直接 `break`、`recv_count>100` 上限在 `recvmsg` 之前） |
| **7** | 真编译结果：`.built`、`.o` 数量、编译日志里 `error:` 行 |
| **8** | 设备侧对照命令清单（libc sha256 / Build ID、二进制 md5、maps 段、fd=7 无人 wait 复核） |

产物：`report.md`、`root-cause-evidence.txt`、`smartdns-symbols.txt`，全部进 artifact，并写入 Step Summary。

---

## 判读（拿到报告先看这三行）

**① 第 2 节 `0x62a98` 的函数名**

| 结果 | 链条 |
|---|---|
| `pthread_join` | 主线程等一个永不返回/根本没起的线程 → 无限等 + SIGTERM 退不掉 + 6653/fd14 两个队列无人消费，全闭合 |
| `pthread_cond_wait` / `__timedwait` | 启动/运行期信号丢失，性质相同、位置不同 |
| `pthread_mutex_lock` / `__lock` | 回到"持锁者是谁"，再查栈上业务帧 |
| `??` 且 nm 也无匹配 | libc 版本不一致，看第 1 节的 sha256/Build ID 校验 |

**② 第 1 节设备 libc sha256 与 rootfs 版是否一致**：不一致 → 三个偏移来自另一版 libc，**第 2 节结果作废**，必须用同一 commit 重跑一次构建。

**③ 第 6 节三项 PASS**：说明 `fix-neighbor-epoll-stall` 的修复确实编进了这份源码。如果设备 md5（第 3 节）与构建产物不一致，说明**刷进去的固件不是这份源码**——先查 `dl/` 缓存和 `PKG_SOURCE_VERSION`，别急着再刷。

---

## 与前面现场结论的关系（避免重复劳动）

已经查实、这次不再重复查的：

- `fd=7` 才是 DNS 主 epoll（tfd 10/6/31/32 之外那张），注册 136337(6653)、136340(6553)、136343(fd13)、136344(fd14)；`fd=5` 是另一路，5 个 netlink 与它零交集。
- 卡住时**没有任何线程在 `epoll_wait(fd=7)`**；6653 `rx=0x33D80=212352`、`drops=729`；fd14 `Rmem=212352 / Drops=72`，`O_NONBLOCK` 且无消费者。
- 主线程与另一线程同 uaddr、同 `val=0xffffffff80000010`、同 `timeout=0x0`、同 pc=`libc+0x62a98`。
- 根因链：NEIGH 事件堆积 → ENOBUFS → 旧实现在主 epoll 回调里同步全表 dump 拿 `netlink_neighbor_lock` 等 `NLMSG_DONE` → 主循环停摆。上游 Release48 就有这条路径，不是路由补丁引入的。

**还欠的只有一件事：那三个偏移对应的函数名。** 这份 CI 就是为它写的。

---

## 注意

- 脚本**只读**：不改源码、不 `make`、不重启、不改配置、不装包。
- 编译失败时 `if: always()` 仍会跑，报告里会明确 WARN"构建树/工具链不存在"，不会把失败伪装成成功。
- 独立工作流第一次跑要编 toolchain（约 10~30 分钟）；之后 `cache_toolchain=1` 命中缓存会很快。缓存命中后若出现莫名的编译错误，把 `cache_toolchain` 设 `0` 重跑一次。
- `diy-part.sh` 已经做了防缓存（分支解析成 40 位 SHA + 删 `dl/smartdns*`）；第 4 节会把 `dl/` 里实际残留的 smartdns 包列出来，用来复核 Build #53 那种"编的还是旧包"。
- 当前 `custom-48.4-dulwandiy` 分支源码里 **ENOBUFS 分支已经是 `break`、`recv_count>100` 已在循环顶部**（本次实读确认），所以第 6 节会 PASS。这正好能验证你刷进去的二进制是不是最新这份。
