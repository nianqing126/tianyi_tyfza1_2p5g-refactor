#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制 + 配置定型（加载 .config 之后运行）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# ================================================================
set -euo pipefail

# ---- 失败诊断 ----------------------------------------------------
# 断言失败时输出 GitHub 注解（::error::），run 页面顶部直接能看到原因，
# 不用翻几千行日志；ERR trap 兜住"没预想到会失败"的命令（如 make defconfig）。
# 注意 fail 里的 exit 不触发 ERR trap，所以不会重复报错。
fail() { echo "::error::diy-part2: $*" >&2; exit 1; }
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::diy-part2 意外失败 rc=$rc：$BASH_COMMAND" >&2' ERR

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"

# ---- 机型选择：来自 workflow_dispatch 的 target_model 输入 ----
# 只编所选机型；其余机型在下面第 5 节统一关闭。
ALL_DEVICES="youhua_pt1570_r10 tianyi_tyfza1_2p5g tianyi_tyfza1_4ge youhua_pt1500_h10_2p5g"
PROFILE="${TARGET_MODEL:-youhua_pt1570_r10}"
case " $ALL_DEVICES " in
  *" $PROFILE "*) ;;
  *) fail "未知机型 '$PROFILE'（可选：$ALL_DEVICES）" ;;
esac
# 主机名/SSID 默认值跟随机型（仍可用环境变量覆盖）
case "$PROFILE" in
  youhua_pt1570_r10)      MODEL_LABEL="PT1570-R10" ;;
  tianyi_tyfza1_2p5g)     MODEL_LABEL="TYFZA1-2.5G" ;;
  tianyi_tyfza1_4ge)      MODEL_LABEL="TYFZA1-4GE" ;;
  youhua_pt1500_h10_2p5g) MODEL_LABEL="PT1500-H10" ;;
esac
WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-$MODEL_LABEL}"
WRT_SSID="${WRT_SSID:-$MODEL_LABEL}"
# 双频独立 SSID（2026-11-14 真机确定）：5G 带 -5G 后缀，2.4G 带 -2.4G 后缀。
SSID_5G="${SSID_5G:-${WRT_SSID}-5G}"
SSID_24G="${SSID_24G:-${WRT_SSID}-2.4G}"
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
FW_AUTHOR="${FW_AUTHOR:-lu1991}"
echo "TARGET_MODEL=$PROFILE (hostname/SSID=$MODEL_LABEL)"

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

echo "=========================================="
echo "diy-part2: 默认值定制 + 配置定型"
echo "=========================================="

echo "---- [1/7] config_generate 默认值 ----"
# ---- 1. config_generate 默认值 ----
if [ -f "$CFG" ]; then
  sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
  sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
  sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
  sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "✅ IP=$WRT_IP hostname=$WRT_NAME tz=$WRT_TZ NTP=国内源"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

echo "---- [1b/7] 无线模板（SSID 分频段 / 首启启用） ----"
# ---- 1b. 无线默认值：首启即启用 + 分频段 SSID ----
# mac80211.uc 是 /etc/config/wireless 的生成器，必须改掉的行为：
#   默认把 wifi-iface 写成 disabled='1'（只有 board.json 带 wlan.defaults
#   才启用，R10 没有），结果"刷完看不到任何 SSID"。
if [ -f "$WIFI_UC" ]; then
  command -v python3 >/dev/null 2>&1 \
    || fail "改写 mac80211.uc 需要 python3"
  python3 - "$WIFI_UC" "$SSID_24G" "$SSID_5G" <<'PY'
import sys

path, ssid24, ssid5 = sys.argv[1], sys.argv[2], sys.argv[3]
# newline="" 关掉换行转换：否则在 Windows 上跑会写出 CRLF，ucode 解析异常
src = open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")

# 1) 模板里的"默认值表达式"逐个换成固定值；每处必须唯一命中，否则说明
#    上游模板已经改了，宁可立刻失败也不要编出一个 SSID 还是 OpenWrt 的固件。
subs = [
    ('${defaults?.ssid || "OpenWrt"}',
     "${defaults?.ssid || (band_name == '2g' ? \"%s\" : \"%s\")}" % (ssid24, ssid5)),
    ('${defaults?.encryption || encryption}', 'none'),
    ('${defaults?.key || ""}', ''),
    ("set ${si}.disabled='${defaults ? 0 : 1}'", "set ${si}.disabled='0'"),
]
for old, new in subs:
    n = src.count(old)
    if n != 1:
        sys.exit("ERROR: mac80211.uc 模板片段命中 %d 次（应为 1）：%r" % (n, old))
    src = src.replace(old, new)

# htmode 推导块保持上游原样：2G/5G 的协议由驱动宣称的能力决定
# （详见上方注释；原厂固件就是这么工作的）。

open(path, "w", encoding="utf-8", newline="").write(src)
PY
  # 改完必须真的落地，否则两小时的编译白跑
  grep -qF "set \${si}.disabled='0'" "$WIFI_UC" \
    || fail "mac80211.uc 默认启用改写失败（上游模板变了？）"
  grep -qF "set \${si}.encryption='none'" "$WIFI_UC" \
    || fail "mac80211.uc 加密未设为 none"
  grep -qF "$SSID_24G" "$WIFI_UC" \
    || fail "2.4G SSID（$SSID_24G）未写入模板"
  grep -qF "$SSID_5G" "$WIFI_UC" \
    || fail "5G SSID（$SSID_5G）未写入模板"
  # 交还驱动推导：模板里不允许再出现我们曾经注入的 htmode 字面量钉死。
  # 注意只能查 "HT20" 字面量，不能查 `band_name == "2G"` —— 上游模板第 77 行
  # 本来就是 `if (band_name == "2G") width = 20;`（2G 带宽锁 20MHz），
  # 2026-11-16 run 43787694475 就是因为把它当标记而误判失败。
  if grep -qE 'htmode[[:space:]]*=[[:space:]]*"HT20"' "$WIFI_UC"; then
    fail "mac80211.uc 仍存在 htmode 钉死（应交还驱动推导）"
  fi
  # 正向确认：推导块必须是上游原样，否则说明替换脚本把它改坏了
  grep -qF 'filter(htmode_order, (m) => band[lc(m)])[0]' "$WIFI_UC" \
    || fail "mac80211.uc 的 htmode 推导块被改动（应交还驱动推导）"
  echo "✅ 无线默认：5G=$SSID_5G / 2.4G=$SSID_24G，加密=none，首启即启用，htmode 交还驱动推导"
else
  echo "::warning::未找到 $WIFI_UC，跳过无线默认值"
fi

echo "---- [1c/7] 2.4G 开机兜底脚本 ----"
# ---- 1c. 2.4G 开机兜底：首启阶段补齐 country / 启用 / 不隐藏 ----
# 编译期改的是"生成器"，前提是刷机时选"不保留配置"；否则 /etc/config/wireless
# 不会重新生成，等于没改。这里在首启阶段再兜一次。
# 注意：协议（htmode）与信道同样交还驱动推导，兜底脚本不做钉死 —— 与原厂一致。
WIFI24=files/etc/uci-defaults/97-pt1570-r10-wifi24
test -f "$WIFI24" \
  || fail "缺少 $WIFI24（2.4G 只有编译期改写，重启后可能回退）"
grep -qE "country='?CN" "$WIFI24" \
  || fail "$WIFI24 未设置 country=CN"
if grep -qE "htmode='?[A-Z]+[0-9]+|channel='?[0-9]+" "$WIFI24"; then
  fail "$WIFI24 不应钉死 htmode / 信道（应交还驱动推导）"
fi
echo "✅ 2.4G 开机兜底脚本就位：$WIFI24"

echo "---- [1d/7] 主题：design（拉库） ----"
# diy-part1.sh 已调 overlay-theme.sh：拉库 luci-theme-design（锁 SHA）、
# 删除厂商 PON 包里 95/97 两个 argon 默认主题脚本，design 自带 30 号脚本设默认。
grep -q '^CONFIG_PACKAGE_luci-theme-design=y$' .config \
  || echo "CONFIG_PACKAGE_luci-theme-design=y" >> .config
echo "✅ 主题 design（0x676e67/luci-theme-design，直接拉库）；argon 已移除"

echo "---- [2/7] apk 源声明 ----"
# ---- 2. apk 源声明 ----
mkdir -p files/etc/apk/repositories.d
{
  echo "# 本 target 架构 aarch64_cortex-a55，官方/国内镜像一般没有该目录，"
  echo "# 默认不启用任何外部源。配套内核模块与用户态包用同批 packages。"
} > files/etc/apk/repositories.d/distfeeds.list
echo "✅ distfeeds.list 已生成"

echo "---- [3/7] 固件版本号 ----"
# ---- 3. 固件版本号：追加作者与构建时间 ----
FW_BUILD_TIME="${FW_BUILD_TIME:-$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M')}"
DESC_BODY='%D %V %C'
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-· ${FW_AUTHOR} · ${FW_BUILD_TIME}}"
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE
for f in package/base-files/files/etc/openwrt_release \
         package/base-files/files/usr/lib/os-release; do
  if [ -f "$f" ]; then
    if [ "${f##*/}" = "openwrt_release" ]; then
      perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$f"
    else
      perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$f"
    fi
    echo "✅ 版本号模板已更新: $f"
  fi
done

echo "---- [4/7] 机型 profile ----"
# ---- 4. 机型 profile 双保险 ----
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config || \
  echo "CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y" >> .config
sed -i "/^CONFIG_TARGET_PROFILE=/d" .config
echo "CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" >> .config

echo "---- [4b/7] ccache / initramfs ----"
# ---- 4b. 编译加速（ccache）与镜像范围（initramfs） ----
# ccache 的开关在上游 config/Config-devel.in 里是：
#     menuconfig DEVEL
#     config CCACHE
#         bool "Use ccache" if DEVEL        <-- 有 "if DEVEL"
# 也就是说 DEVEL=n 时该符号**不可见**，Kconfig 会把它强制回默认值 n，
# .config 里写的 CONFIG_CCACHE=y 会被 defconfig 改写成 "# ... is not set"。
# 2026-11-14 实测：只写 CCACHE=y 时，下面第 6 节的断言直接失败（job 25 秒退出）。
# 所以必须同时打开 DEVEL —— 它只是让"开发者选项"可见，不改默认产物。
sed -i '/^# CONFIG_DEVEL is not set$/d; /^CONFIG_DEVEL=/d' .config
echo "CONFIG_DEVEL=y" >> .config
# DEVEL=y 会顺带把 AUTOREBUILD 的默认值变成 y（config/Config-devel.in 里
# "bool ... if DEVEL" + "default y"）。CI 里它只会让 make 反复重编，显式关掉。
sed -i '/^# CONFIG_AUTOREBUILD is not set$/d; /^CONFIG_AUTOREBUILD=/d' .config
echo "# CONFIG_AUTOREBUILD is not set" >> .config
# ccache 缓存目录由 rules.mk 决定：CONFIG_CCACHE_DIR 为空时用 $(TOPDIR)/.ccache
# （即源码根的 .ccache），workflow 按这个路径做缓存。
sed -i '/^# CONFIG_CCACHE is not set$/d; /^CONFIG_CCACHE=/d' .config
echo "CONFIG_CCACHE=y" >> .config
echo "✅ ccache: 启用（DEVEL=y，AUTOREBUILD 关闭）"

# initramfs-recovery 要单独再编一遍内核（约多 8 分钟）。
# 默认不编；需要救砖镜像时在 Run workflow 里勾 build_initramfs。
if [ "${BUILD_INITRAMFS:-false}" = "true" ]; then
  sed -i '/^# CONFIG_TARGET_ROOTFS_INITRAMFS is not set$/d' .config
  echo "CONFIG_TARGET_ROOTFS_INITRAMFS=y" >> .config
  echo "✅ initramfs-recovery: 构建（+约 8 分钟）"
else
  sed -i '/^CONFIG_TARGET_ROOTFS_INITRAMFS=y$/d' .config
  echo "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" >> .config
  echo "✅ initramfs-recovery: 跳过（仅出 sysupgrade.itb）"
fi

echo "---- [5/7] 两次 defconfig（最慢的一步） ----"
# ---- 5. 两次 defconfig + 丢包重新断言 ----
# uboot-envtools 的 host fw_printenv 在此 target 会挂，必须保持关闭
sed -i 's|^CONFIG_PACKAGE_uboot-envtools=y|# CONFIG_PACKAGE_uboot-envtools is not set|' .config

make defconfig
# defconfig 会丢掉未被 profile 显式点名的包；这里按本仓库配置口径重新断言。
for sym in tyfza1-pon-control luci-ssl uhttpd fitblk \
           luci-theme-design luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
           wpad-mbedtls wifi-scripts iw wireless-regdb \
           kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
           kmod-fs-ext4 kmod-fs-vfat kmod-nls-utf8 kmod-gpio-button-hotplug \
           ucode-mod-math; do
  if ! grep -q "^CONFIG_PACKAGE_${sym}=y$" .config; then
    sed -i "/^# CONFIG_PACKAGE_${sym} is not set$/d; /^CONFIG_PACKAGE_${sym}=/d" .config
    echo "CONFIG_PACKAGE_${sym}=y" >> .config
    echo "  re-asserted $sym"
  fi
done
make defconfig

# 只构建所选机型：defconfig 会把 target 的默认机型一起选中，多产出其它 itb。
# 产物文件名 tianyi_* 字母序在 youhua_* 之前，取产物/校验时极易抓错（2026-11-13 实测）。
for d in $ALL_DEVICES; do
  [ "$d" = "$PROFILE" ] && continue
  sed -i "s|^CONFIG_TARGET_rtl9617c_generic_DEVICE_${d}=y$|# CONFIG_TARGET_rtl9617c_generic_DEVICE_${d} is not set|" .config
done
n_dev=$(grep -cE '^CONFIG_TARGET_rtl9617c_generic_DEVICE_[A-Za-z0-9_]+=y$' .config || true)
[ "$n_dev" = "1" ] \
  || fail "启用了 $n_dev 个机型，必须只有 $PROFILE"

echo "---- [6/7] 硬断言 ----"
# ---- 6. 硬断言（任何一条失败都说明配置被破坏，提前终止而不是编两小时后炸）----
echo "===== hard assertions ====="
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config \
  || fail "profile $PROFILE 未启用"
# defconfig 会把没有依赖的选项清掉，这里确认"加速"与"镜像范围"没被悄悄改回去
grep -q '^CONFIG_DEVEL=y$' .config \
  || fail "CONFIG_DEVEL 被 defconfig 丢弃（它不可见时 CONFIG_CCACHE 会连带失效）"
echo "  OK   CONFIG_DEVEL=y"
grep -q '^CONFIG_CCACHE=y$' .config \
  || fail "CONFIG_CCACHE 被 defconfig 丢弃（编译会慢很多）"
echo "  OK   CONFIG_CCACHE=y"
if grep -qE '^CONFIG_AUTOREBUILD=y$' .config; then
  fail "CONFIG_AUTOREBUILD 被 DEVEL 带成 y（会让 make 反复重编）"
fi
echo "  OK   AUTOREBUILD 已关闭"
if [ "${BUILD_INITRAMFS:-false}" = "true" ]; then
  grep -q '^CONFIG_TARGET_ROOTFS_INITRAMFS=y$' .config \
    || fail "勾了 build_initramfs 但 CONFIG_TARGET_ROOTFS_INITRAMFS 未启用"
  echo "  OK   initramfs-recovery 已启用"
else
  grep -q '^# CONFIG_TARGET_ROOTFS_INITRAMFS is not set$' .config \
    || fail "未勾 build_initramfs，但 initramfs 仍被启用（会多编一次内核）"
  echo "  OK   initramfs-recovery 已关闭"
fi
for sym in tyfza1-pon-control luci-ssl uhttpd fitblk \
           luci-theme-design luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
           wpad-mbedtls wifi-scripts iw wireless-regdb \
           kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
           kmod-fs-ext4 kmod-fs-vfat kmod-nls-utf8 kmod-gpio-button-hotplug \
           ucode-mod-math; do
  grep -q "^CONFIG_PACKAGE_${sym}=y$" .config \
    || fail "$sym 在两次 defconfig 后被丢弃"
  echo "  OK   $sym"
done
# 主题口径：design（拉库编译）+ 包自带 30_luci-theme-design 设默认；
# argon 包与厂商 95/97 抢主题脚本已在 diy-part1 的 overlay-theme.sh 里清除。
grep -q '^CONFIG_PACKAGE_luci-theme-design=y$' .config \
  || fail "CONFIG_PACKAGE_luci-theme-design 在两次 defconfig 后被丢弃"
echo "  OK   CONFIG_PACKAGE_luci-theme-design=y"
! grep -q 'CONFIG_PACKAGE_luci-theme-argon=y' .config \
  || fail "不应启用 luci-theme-argon（与 design 抢默认主题）"
echo "  OK   luci-theme-argon 未启用"
! grep -q 'CONFIG_PACKAGE_luci-theme-fluent=y' .config \
  || fail "不应启用 luci-theme-fluent（本仓库配置口径为 design）"
echo "  OK   无 Fluent"

# files/ 不应残留任何静态主题目录（htdocs/htdocs/luci-static 等），主题一律走包构建
find files \( -iname '*vantage*' -o -iname '*fluent*' -o -iname '*argon*' \
              -o -iname '*design*' \) \
  ! -path '*/etc/uci-defaults/*' \
  -print -quit 2>/dev/null | grep -q . \
  && fail "files/ 里残留静态主题文件（应删除，主题走包构建）"
echo "  OK   files/ 无静态主题残留"
grep -q '^# CONFIG_PACKAGE_uboot-envtools is not set$' .config \
  || fail "uboot-envtools 必须关闭"
echo "  OK   uboot-envtools disabled"

# FIT rootfs 能不能挂上，取决于两个内核符号（必须落在 target config，
# 写顶层 .config 会被 make defconfig 静默丢弃）
grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' target/linux/rtl9617c/config-6.18 \
  || fail "target config-6.18 缺少 CONFIG_UIMAGE_FIT_BLK=y"
grep -q '^CONFIG_MTD_ROOTFS_ROOT_DEV=y$' target/linux/generic/config-6.18 \
  || fail "generic config-6.18 缺少 CONFIG_MTD_ROOTFS_ROOT_DEV=y"
echo "  OK   UIMAGE_FIT_BLK + MTD_ROOTFS_ROOT_DEV"

# 板级注入核验
grep -q "SUPPORTED_DEVICES += youhua,pt1570-r10" target/linux/rtl9617c/image/Makefile \
  || fail "image/Makefile 缺少 SUPPORTED_DEVICES"
grep -q "youhua,pt1570-r10" target/linux/rtl9617c/base-files/lib/upgrade/platform.sh \
  || fail "platform.sh 白名单缺少 youhua,pt1570-r10"
test -f target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts \
  || fail "DTS 缺失"
echo "  OK   DTS + image/Makefile + platform.sh"

# 空配置 defconfig 会把上游默认 target 的包写成显式 =y（污染源），反向断言
for bad in kmod-mac80211 kmod-cfg80211 kmod-mt7915e kmod-mt76-core \
           wpad-basic-mbedtls mt7981-wo-firmware eip197-mini-firmware; do
  if grep -qE "^CONFIG_PACKAGE_${bad}=(y|m)$" .config; then
    fail "检测到污染包 ${bad}（默认 target 的包残留）"
  fi
done
echo "  OK   无 mediatek/openwrt_one 残留包"

# rtw89 官方驱动核验（diy-part1 的 overlay-rtw89.sh 已落地）
DST=target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtw89
[ -f "$DST/rtw89_factory.c" ] && [ -f "$DST/rtw8192xb.c" ] \
  || fail "rtw89 驱动源码未落地（overlay-rtw89.sh 失败？）"
grep -q '^CONFIG_RTW89_8192XBE=y$' target/linux/rtl9617c/config-6.18 \
  || fail "config-6.18 缺 CONFIG_RTW89_8192XBE=y"
grep -q '^CONFIG_MTD_UBI_NVMEM=y$' target/linux/rtl9617c/config-6.18 \
  || fail "config-6.18 缺 CONFIG_MTD_UBI_NVMEM=y（factory 校准读不到）"
grep -q 'wifi_cal_radio1' target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi \
  || fail "公共 dtsi 未绑定 factory 校准 cell（overlay-rtw89.sh 未落地？）"
echo "  OK   rtw89 官方驱动 + factory nvmem 校准链路（全机型）"

echo "===== key config ====="
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET)=' .config || true
cp .config "$ASSETS/Config-final.txt"
echo "🎉 diy-part2.sh 完成"
