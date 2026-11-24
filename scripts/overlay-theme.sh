#!/bin/bash
# ================================================================
# overlay-theme.sh —— 主题切换：argon -> design（直接拉库编译）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# 调用时机：diy-part1.sh 第 1 节（feeds 安装之后、加载 .config 之前）
#
# design 主题：https://github.com/0x676e67/luci-theme-design
#   * main 分支 = lede/lua 版 LuCI（本仓库 luci feed 为 openwrt/luci，
#     仍兼容 luasrc/ + htdocs/ 布局）；js 分支不拉。
#   * 锁 commit 5cea733806ccaf17fd63790d171bb2b65f29f8bd，字节级可复现。
#   * 包自带 root/etc/uci-defaults/30_luci-theme-design，会把
#     luci.main.mediaurlbase 设成 /luci-static/design。
#
# "去掉 argon 主题设置"的两处来源（厂商硬件层 20b4cf4）：
#   1) workflow Clone 步骤原本 checkout 的 package/luci-theme-argon
#      —— 已改为不 checkout，本脚本再做一次 rm -rf 兜底。
#   2) luci-app-tyfza1-pon 包里的两个 uci-defaults 脚本：
#        95-tyfza1-argon          迁移脚本：首次开机写 mediaurlbase=argon
#        97-tyfza1-argon-default  每次开机强制写回 argon（序号 97 > 30，会抢主题）
#      两个都必须删，否则 design 被 argon 抢回默认主题。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"
THEME_URL="${THEME_URL:-https://github.com/0x676e67/luci-theme-design}"
THEME_REF="${THEME_REF:-5cea733806ccaf17fd63790d171bb2b65f29f8bd}"

echo "=========================================="
echo "overlay-theme: argon -> design（拉库编译）"
echo "  url = $THEME_URL"
echo "  ref = $THEME_REF"
echo "  wrt = $WRT"
echo "=========================================="

test -f "$WRT/package/base-files/files/bin/config_generate" \
  || { echo "ERROR: $WRT 不是 OpenWrt 源码根" >&2; exit 1; }

# ---- 1. 去掉 argon 包本体（workflow 已不 checkout，这里兜底）----
rm -rf "$WRT/package/luci-theme-argon" \
       "$WRT/package/feeds/luci/luci-theme-argon" 2>/dev/null || true
# feeds 软链可能指向外部（packages/luci feed 不含 argon，但保险起见清软链本身）
find "$WRT/package/feeds" -maxdepth 2 -type l -name 'luci-theme-argon' -delete 2>/dev/null || true
echo "  OK   argon 包本体已移除"

# ---- 2. 去掉厂商 argon 默认主题设置（uci-defaults）----
PON_UCID="$WRT/package/luci-app-tyfza1-pon/root/etc/uci-defaults"
n_rm=0
for s in 95-tyfza1-argon 97-tyfza1-argon-default; do
  if [ -f "$PON_UCID/$s" ]; then
    rm -f "$PON_UCID/$s"
    n_rm=$((n_rm+1))
    echo "  OK   已删除 $s"
  fi
done
# 收尾断言：源码树任何 uci-defaults 里都不允许再出现 argon 主题设置
if grep -rqs -e '/luci-static/argon' -e 'luci\.themes\.Argon' \
     "$WRT/package/luci-app-tyfza1-pon" 2>/dev/null; then
  echo "ERROR: PON 包仍有 argon 默认主题设置（会抢走 design）" >&2
  exit 1
fi
echo "  OK   厂商 argon 默认主题设置已清除（删除 $n_rm 个脚本）"

# ---- 2b. 去掉 PON 包 Makefile 里对已删除 argon 包的依赖 ----
# 厂商 package/luci-app-tyfza1-pon 的 LUCI_DEPENDS 写死了
#   +luci-theme-argon +luci-i18n-argon-config-zh-cn
# argon 包已删，但 luci.mk 会把这两项原样写进 PON 包的 apk Depends，
# apk 安装阶段解析不到就报：
#   ERROR: unable to select packages:
#     luci-theme-argon (no such package): required by luci-app-tyfza1-pon
#     luci-i18n-argon-config-zh-cn (no such package): required by ...
# 主题改由 design 单独提供，PON 包不应硬依赖某个主题，删掉这两项即可
# （基础中文 +luci-i18n-base-zh-cn 保留，不受影响）。
PON_MK="$WRT/package/luci-app-tyfza1-pon/Makefile"
if [ -f "$PON_MK" ]; then
  sed -i -E \
    -e 's/\+luci-theme-argon([[:space:]]|$)//g' \
    -e 's/\+luci-i18n-argon-config-zh-cn([[:space:]]|$)//g' \
    "$PON_MK"
  echo "  OK   PON 包 Makefile 的 argon 依赖已移除"
else
  echo "::warning::未找到 $PON_MK，跳过 argon 依赖清理"
fi
# 断言：PON 包 Makefile 的 LUCI_DEPENDS 不得再依赖 argon（apk 安装会失败）
if [ -f "$PON_MK" ] && grep '^LUCI_DEPENDS:=' "$PON_MK" | grep -q 'argon'; then
  echo "ERROR: $PON_MK 的 LUCI_DEPENDS 仍含 argon 依赖（apk 安装会失败）" >&2
  grep '^LUCI_DEPENDS:=' "$PON_MK" >&2
  exit 1
fi
echo "  OK   PON 包依赖无 argon 残留"

# ---- 3. 直接拉库 design 主题（锁 SHA，字节级可复现）----
DST="$WRT/package/luci-theme-design"
rm -rf "$DST"
mkdir -p "$DST"
git init -q "$DST"
git -C "$DST" remote add origin "$THEME_URL"
if ! git -C "$DST" fetch -q --depth=1 origin "$THEME_REF"; then
  echo "::warning::按 SHA 拉取失败，回退 main 分支"
  git -C "$DST" fetch -q --depth=1 origin main
fi
git -C "$DST" checkout -q FETCH_HEAD
GOT="$(git -C "$DST" rev-parse HEAD)"
echo "  OK   design 主题已拉到 package/luci-theme-design @ ${GOT:0:12}"

# ---- 4. 断言：包结构 + 默认主题脚本在位 ----
test -f "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 缺失" >&2; exit 1; }
grep -q 'luci.mk' "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 未 include luci.mk" >&2; exit 1; }
test -d "$DST/htdocs/luci-static/design" \
  || { echo "ERROR: design 主题静态目录缺失" >&2; exit 1; }
test -f "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: design 主题缺默认主题脚本 30_luci-theme-design" >&2; exit 1; }
grep -q '/luci-static/design' "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: 30_luci-theme-design 未设置 mediaurlbase=/luci-static/design" >&2; exit 1; }
echo "  OK   design 包结构 + 默认主题脚本就位"

# ---- 5. 修正 design 主题版本号（新版 apk 拒收 '-纯数字' release 段）----
# 0x676e67/luci-theme-design 与 kenzok8 feed 的同名主题都用
#   PKG_VERSION:=5.8.0-20240106
# 新版 apk-tools 把 "-20240106" 解析成第二个 release 段，报
#   ERROR: info field 'version' has invalid value: package version is invalid
# 统一改成点号分段 5.8.0.20240106（与内核 6.18.55、2.3.1 等合法包口径一致）。
# 必须同时改两份：编译实际用的是 feeds install 软链的 feeds/kenzok8 那份，
# overlay 拉库到 package/ 的是另一份；两份版本号相同，都要规范化。
n_fix=0
while IFS= read -r mf; do
  [ -f "$mf" ] || continue
  sed -i -E 's/^(PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+)-([0-9]{6,8})$/\1.\2/' "$mf"
  n_fix=$((n_fix+1))
done < <(find "$WRT/package" "$WRT/feeds" -path '*/luci-theme-design/Makefile' 2>/dev/null)
echo "  OK   design 主题版本号已规范化（$n_fix 份 Makefile）"

# 断言：所有 design 主题 Makefile 不得再残留 '-纯数字' 版本段（apk 会拒收）
_bad=0
while IFS= read -r mf; do
  [ -f "$mf" ] || continue
  if grep -Eq '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[0-9]{6,8}$' "$mf"; then
    echo "ERROR: $mf 版本号含非法 '-纯数字' 段（apk 会拒收）: $(grep '^PKG_VERSION' "$mf")" >&2
    _bad=1
  fi
done < <(find "$WRT/package" "$WRT/feeds" -path '*/luci-theme-design/Makefile' 2>/dev/null)
[ "$_bad" -eq 0 ] || exit 1
echo "  OK   无非法 apk 版本号残留"

echo "🎉 overlay-theme.sh 完成"
