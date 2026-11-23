#!/bin/bash
# ================================================================
# overlay-rtw89.sh —— 把上游 refactor 官方 rtw89 WiFi 驱动移植到
# 20b4cf4 硬件层源码树（替换逆向 rtl_ax_ap 方案）。
#
# 来源：lyq1996/rtl9617c-openwrt @ fd909a3
#   "rtl9617c: add rtw89 wifi driver for rtl8192xbe and rtl8852ce"
#
# 为什么换：
#   逆向 rtl_ax_ap 方案在本仓库踩了 PE 引擎 / TSSI / RFE50 / calibration
#   symlink / 284 字节 / regdb 一连串坑，2.4G 真机始终搜不到。上游官方
#   rtw89 驱动直接从 factory 卷的 nvmem cell 读 TYFC0003 校准（mac/xtal/
#   gain/tssi 全解析），不依赖 /tmp 软链、不校验 size==284，从根上绕开。
#
# 硬件层（20b4cf4）与上游（5ba60e0）的 target 树完全不同（补丁集 100-215
# vs 300-740），所以不能整树 clone 上游。本脚本只移植 rtw89 相关四件套：
#   1. 驱动源码 6 个文件 -> target/linux/rtl9617c/files-6.18/.../rtw89/
#   2. 内核补丁 740      -> target/linux/rtl9617c/patches-6.18/
#   3. 内核 config       -> target/linux/rtl9617c/config-6.18
#      （开 rtw89 + NVMEM + MTD_UBI_NVMEM，关 rtl_ax_ap）
#   4. DTS nvmem 绑定    -> 公共 dtsi 的 &pcie0/&pcie1 wifi 节点（全机型覆盖）
#   5. 固件             -> 双链路：
#      a) 编进内核（CONFIG_EXTRA_FIRMWARE）：board/rtw89/firmware/ 下 6 个 ->
#         files-6.18/firmware/，含 5G 探测序列 rtw8852c_fw-2.bin / -1.bin /
#         .bin 三个别名 + rtw8192xb_fw.bin + regulatory.db(.p7s)。
#         built-in 驱动/cfg80211 早期 probe 直接命中，不依赖 rootfs（根因修复）。
#         真机日志证实：rtw89 请求 -2/-1/.bin、cfg80211 请求 regulatory.db，
#         全部发生在 rootfs(fit0) 挂载前 372s，sysfs fallback 每个卡 60s。
#      b) rootfs 兜底（files/lib/firmware/rtw89/ 下 2 个，workflow cp）。
#
# 幂等：重复执行安全。任何一步不满足预期都 fail，绝不产出半套驱动。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$PWD}"

fail() { echo "ERROR: $*" >&2; exit 1; }

DRV_SRC="$ASSETS/board/rtw89/driver"
PATCH_SRC="$ASSETS/board/rtw89/patches/740-wifi-rtw89-8192xb.patch"
FW_SRC="$ASSETS/board/rtw89/firmware"
DRV_DST="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtw89"
# 内核 EXTRA_FIRMWARE 从 files-6.18/firmware/ 读取（该目录在内核 prepare 阶段
# 被 OpenWrt rsync 进内核源码树，相对 CONFIG_EXTRA_FIRMWARE_DIR=firmware）。
FW_DST="$WRT/target/linux/rtl9617c/files-6.18/firmware/rtw89"
# regulatory.db 由 cfg80211(built-in) 从固件根请求，路径不带 rtw89/ 前缀
REGDB_DST="$WRT/target/linux/rtl9617c/files-6.18/firmware"
PATCH_DST="$WRT/target/linux/rtl9617c/patches-6.18/740-wifi-rtw89-8192xb.patch"
CFG="$WRT/target/linux/rtl9617c/config-6.18"
# 校准绑定写到公共 dtsi（rtl9617c-tyfza1.dtsi），而不是某个板级 DTS：
# 所有板级 DTS（R10/r10、tyfza1-4ge、tyfza1-2p5g）都 #include 这个 dtsi，
# 且 pcie0/pcie1 节点与 wifi_cal_radio0/radio1 校准 cell 的 label 都定义在里面。
# 这样无论 TARGET_MODEL 选哪个机型，rtw89 都能从 factory 卷读到校准数据。
# 之前写死 R10 DTS 是缺陷：编译天邑机型时绑定根本不进 dtb -> 无 WLAN。
DTS="$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi"

for f in "$DRV_SRC" "$PATCH_SRC" "$FW_SRC" "$CFG" "$DTS"; do
  [ -e "$f" ] || fail "缺少 $f"
done

echo "=========================================="
echo "overlay-rtw89: 官方驱动替换 rtl_ax_ap"
echo "  assets = $ASSETS"
echo "  wrt    = $WRT"
echo "=========================================="

# ---- 1. 驱动源码 ----
mkdir -p "$DRV_DST"
n=0
for f in rtw8192xb.c rtw8192xb.h rtw8192xb_table.c rtw8192xbe.c \
         rtw89_factory.c rtw89_factory.h; do
  [ -f "$DRV_SRC/$f" ] || fail "缺少驱动源文件 $DRV_SRC/$f"
  cp -f "$DRV_SRC/$f" "$DRV_DST/$f"
  n=$((n + 1))
done
[ "$n" -eq 6 ] || fail "驱动源文件数 $n != 6"
md5sum "$DRV_DST"/* | sha256sum | cut -d' ' -f1 > /tmp/rtw89-driver.sha256
echo "  驱动源码 $n 个文件已落地"

# ---- 1b. 固件编进内核（CONFIG_EXTRA_FIRMWARE 的数据源）----
# 根因（真机 TTL 日志证实）：rtw89 / cfg80211 都是 built-in(=y)，PCI probe 在
# 4.4s 发生，而 root=/dev/fit0 到 372s 才挂载。此时 /lib/firmware/ 还不存在：
#   5G  rtw89_8852ce 依次请求 rtw8852c_fw-2.bin / -1.bin / .bin
#   2.4G rtw89_8192xbe 请求 rtw8192xb_fw.bin
#   regdb cfg80211 请求 regulatory.db（372.258s，挂载前 28ms）
# 每次 request_firmware 找不到就 sysfs fallback 卡 60s（-110），共 6 次 = 360s，
# 然后 probe -22 失败 -> 无 WLAN + 启动慢 6 分钟。
# 解法：把这些固件放进 files-6.18/firmware/（内核 prepare 阶段 rsync 进源码树），
# 用 CONFIG_EXTRA_FIRMWARE 编进内核镜像。built-in 固件查询优先于文件系统，
# early probe 直接命中，不依赖 rootfs 挂载时序。
# 5G 三个别名内容相同（固件只认 basename format 后缀），全部列出避免探测失败。
# 注意：files/lib/firmware/ 那份仍保留（rootfs 里），供运行时重载兜底。
mkdir -p "$FW_DST" "$REGDB_DST"
fw_n=0
for fw in rtw8852c_fw-2.bin rtw8852c_fw-1.bin rtw8852c_fw.bin rtw8192xb_fw.bin; do
  [ -f "$FW_SRC/$fw" ] || fail "缺少固件源 $FW_SRC/$fw"
  cp -f "$FW_SRC/$fw" "$FW_DST/$fw"
  fw_n=$((fw_n + 1))
done
[ "$fw_n" -eq 4 ] || fail "WiFi 固件数 $fw_n != 4"
for fw in regulatory.db regulatory.db.p7s; do
  [ -f "$FW_SRC/$fw" ] || fail "缺少固件源 $FW_SRC/$fw"
  cp -f "$FW_SRC/$fw" "$REGDB_DST/$fw"
  fw_n=$((fw_n + 1))
done
[ "$fw_n" -eq 6 ] || fail "内置固件总数 $fw_n != 6"
echo "  固件 $fw_n 个已落地 files-6.18/firmware（WiFi 4 + regdb 2，含 5G -2/-1 别名）"

# ---- 2. 内核补丁 ----
cp -f "$PATCH_SRC" "$PATCH_DST"
grep -q 'RTL8192XB' "$PATCH_DST" \
  || fail "740 补丁落地后没有 RTL8192XB 标记"
echo "  内核补丁 740-wifi-rtw89-8192xb.patch 已落地"

# ---- 2b. 物理移除旧的 rtl_ax_ap 驱动（根因修复）----
# 201-native-radio.patch 会往内核注入两行：
#   +source "drivers/net/wireless/realtek/rtl_ax_ap/Kconfig"   -> 定义 config RTL_AX_AP
#   +obj-$(CONFIG_RTL_AX_AP)  += rtl_ax_ap/                    -> 递归编译该目录
# 只要这两行在，内核 Kconfig 就有 RTL_AX_AP 符号，syncconfig 在缺值时按
# tristate 默认重新打开(=m)，进而编译 rtl_ax_ap 并撞上已删除的 pe-tx-code.h
# （CI 连续两次同一报错）。改 config 的 not-set 不可靠——syncconfig 会覆盖。
# 彻底解法：整个删除 201 补丁（它全部内容就是接 rtl_ax_ap，无其它改动）+ 删除驱动
# 目录，让内核根本看不到该符号。注意不能只逐行删 + 行——那会破坏 hunk 的 @@ 行数
# 计数导致 "malformed patch"（CI 已踩）。删整文件最干净。
python3 - "$WRT" <<'PY'
import pathlib, sys
wrt = pathlib.Path(sys.argv[1])
patch = wrt / "target/linux/rtl9617c/patches-6.18/201-native-radio.patch"
if patch.exists():
    patch.unlink()
    print('  已删除 201-native-radio.patch（rtl_ax_ap 内核注入整套）')
else:
    print('  201 补丁不存在，跳过')

drv = wrt / "target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
if drv.exists():
    import shutil
    shutil.rmtree(drv)
    print('  已删除 rtl_ax_ap 驱动目录')
else:
    print('  rtl_ax_ap 驱动目录不存在，跳过')

# 删除 modules.mk 里整个 KernelPackage/rtl-ax-ap 定义块（否则打包阶段找不到
# rtl_ax_ap.ko 报 "module is missing"）。保留其它 KernelPackage（如 usb-led）。
mods = wrt / "target/linux/rtl9617c/modules.mk"
if mods.exists():
    src = mods.read_text(encoding='utf-8')
    start = src.find('define KernelPackage/rtl-ax-ap')
    end_marker = '$(eval $(call KernelPackage,rtl-ax-ap))'
    end = src.find(end_marker)
    if start != -1 and end != -1:
        end += len(end_marker)
        # 连带吃掉块后的空行
        while end < len(src) and src[end] == '\n':
            end += 1
        mods.write_text(src[:start] + src[end:], encoding='utf-8', newline='\n')
        print('  modules.mk 已删除 KernelPackage/rtl-ax-ap 块')
    else:
        print('  modules.mk 无 rtl-ax-ap 块，跳过')
else:
    print('  modules.mk 不存在，跳过')

# 从 image/Makefile 的 DEVICE_PACKAGES 移除 kmod-rtl-ax-ap（两个硬件层模板 Device）。
img = wrt / "target/linux/rtl9617c/image/Makefile"
if img.exists():
    txt = img.read_text(encoding='utf-8')
    n = txt.count('kmod-rtl-ax-ap')
    if n:
        txt = txt.replace('kmod-rtl-ax-ap ', '').replace(' kmod-rtl-ax-ap', '')
        img.write_text(txt, encoding='utf-8', newline='\n')
        print(f'  image/Makefile 移除 kmod-rtl-ax-ap {n} 处')
PY
# 断言：内核 target 树里不能再有任何 rtl_ax_ap / kmod-rtl-ax-ap 引用
! grep -rq 'rtl_ax_ap' "$WRT/target/linux/rtl9617c/patches-6.18/" \
  || fail "补丁仍有 rtl_ax_ap 引用（内核会重新编译旧驱动）"
! grep -rq 'CONFIG_RTL_AX_AP' "$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/" \
  || fail "内核源码树仍有 CONFIG_RTL_AX_AP 引用"
! grep -q 'KernelPackage/rtl-ax-ap' "$WRT/target/linux/rtl9617c/modules.mk" \
  || fail "modules.mk 仍有 kmod-rtl-ax-ap 包定义（打包阶段找不到 .ko）"
! grep -q 'kmod-rtl-ax-ap' "$WRT/target/linux/rtl9617c/image/Makefile" \
  || fail "image/Makefile 仍引用 kmod-rtl-ax-ap"
echo "  内核树已彻底无 rtl_ax_ap 驱动（Kconfig/Makefile/包/镜像依赖全清）"

# ---- 3. 内核 config ----
# 硬件层 config 默认：CONFIG_RTL_AX_AP=m，NVMEM 全关。rtw89 必须反过来。
# 用 python 逐行幂等处理：删旧符号 -> 追加新符号；保留其余原样。
python3 - "$CFG" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
lines = p.read_text(encoding='utf-8').splitlines()

# 新块要写入的符号全集 —— 这些符号的旧行（=y/=m/not set）全部先删，
# 保证每个符号在新块里只有一行，避免 make defconfig 因重复符号告警/行为不定。
write_syms = (
    'CONFIG_WLAN_VENDOR_REALTEK', 'CONFIG_CFG80211',
    'CONFIG_CFG80211_DEVELOPER_WARNINGS',
    'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB',
    'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS',
    'CONFIG_CFG80211_DEFAULT_PS', 'CONFIG_CFG80211_DEBUGFS',
    'CONFIG_CFG80211_CRDA_SUPPORT', 'CONFIG_CFG80211_WEXT',
    'CONFIG_MAC80211', 'CONFIG_MAC80211_RC_MINSTREL',
    'CONFIG_MAC80211_RC_DEFAULT_MINSTREL',
    'CONFIG_MAC80211_LEDS', 'CONFIG_MAC80211_DEBUG_MENU',
    'CONFIG_RTW89', 'CONFIG_RTW89_CORE', 'CONFIG_RTW89_PCI',
    'CONFIG_RTW89_8192XB', 'CONFIG_RTW89_8192XBE',
    'CONFIG_RTW89_8852C', 'CONFIG_RTW89_8852CE',
    # 740 补丁/内核 Kconfig 里 RTW89 菜单下其余芯片符号：必须全部显式设置，
    # 否则 syncconfig 遇到 (NEW) 符号在非交互编译下报 Error 1（真机 CI 已踩）。
    'CONFIG_RTW89_8851BE', 'CONFIG_RTW89_8851BU',
    'CONFIG_RTW89_8852AE', 'CONFIG_RTW89_8852BE',
    'CONFIG_RTW89_8852BU', 'CONFIG_RTW89_8852BTE',
    'CONFIG_RTW89_8922AE', 'CONFIG_RTW89_DEBUGMSG',
    'CONFIG_NVMEM', 'CONFIG_NVMEM_LAYOUTS', 'CONFIG_NVMEM_SYSFS',
    'CONFIG_NVMEM_REALTEK_TAURUS_OTP', 'CONFIG_MTD_UBI_NVMEM',
    # 固件编进内核：built-in rtw89 早期 probe 不依赖 rootfs 挂载。
    'CONFIG_EXTRA_FIRMWARE', 'CONFIG_EXTRA_FIRMWARE_DIR',
    # 旧的逆向驱动符号：先删旧值（=m），下面 new 块显式写 not set。
    # 只删不写会让 syncconfig 视其为 NEW 并按 Kconfig 默认重新打开（=m），
    # 内核随即编译 rtl_ax_ap 并撞上已删除的 pe-tx-code.h（CI 已踩）。
    'CONFIG_RTL_AX_AP',
)

def is_target(line):
    s = line.strip()
    for sym in write_syms:
        if s == sym or s.startswith(sym + '=') or s == '# ' + sym + ' is not set':
            return True
    return False

lines = [l for l in lines if not is_target(l)]

# 上游 rtw89 内核配置口径（全部 built-in =y，不开 debug）。
# CFG80211_REQUIRE_SIGNED_REGDB / USE_KERNEL_REGDB_KEYS 关闭：与上游一致，
# 避免 world domain(00) NO-IR 让 5G AP 起不来（本仓库 regdb 仍随 files 落地）。
new = [
    '# ===== rtw89 official WiFi (from lyq1996/refactor fd909a3) =====',
    'CONFIG_WLAN_VENDOR_REALTEK=y',
    'CONFIG_CFG80211=y',
    '# CONFIG_CFG80211_DEVELOPER_WARNINGS is not set',
    '# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB is not set',
    '# CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS is not set',
    'CONFIG_CFG80211_DEFAULT_PS=y',
    '# CONFIG_CFG80211_DEBUGFS is not set',
    'CONFIG_CFG80211_CRDA_SUPPORT=y',
    '# CONFIG_CFG80211_WEXT is not set',
    'CONFIG_MAC80211=y',
    'CONFIG_MAC80211_RC_MINSTREL=y',
    'CONFIG_MAC80211_RC_DEFAULT_MINSTREL=y',
    '# CONFIG_MAC80211_LEDS is not set',
    # MAC80211_MESH / HAS_RC / RC_DEFAULT 保留硬件层原值（rtw89 不改这些）
    '# CONFIG_MAC80211_DEBUG_MENU is not set',
    'CONFIG_RTW89=y',
    'CONFIG_RTW89_CORE=y',
    'CONFIG_RTW89_PCI=y',
    'CONFIG_RTW89_8192XB=y',
    'CONFIG_RTW89_8192XBE=y',
    'CONFIG_RTW89_8852C=y',
    'CONFIG_RTW89_8852CE=y',
    # 必须显式 not set：否则 syncconfig 视其为 (NEW)，非交互编译直接 Error 1。
    '# CONFIG_RTW89_8851BE is not set',
    '# CONFIG_RTW89_8851BU is not set',
    '# CONFIG_RTW89_8852AE is not set',
    '# CONFIG_RTW89_8852BE is not set',
    '# CONFIG_RTW89_8852BU is not set',
    '# CONFIG_RTW89_8852BTE is not set',
    '# CONFIG_RTW89_8922AE is not set',
    '# CONFIG_RTW89_DEBUGMSG is not set',
    # 显式关闭旧逆向驱动：否则 syncconfig 按 Kconfig 默认(=m)重新启用，
    # 内核编译 rtl_ax_ap 会因缺 pe-tx-code.h 而 Stop（真机 CI 已踩）。
    '# CONFIG_RTL_AX_AP is not set',
    '# ===== nvmem: factory calibration cell for rtw89 =====',
    'CONFIG_NVMEM=y',
    'CONFIG_NVMEM_LAYOUTS=y',
    'CONFIG_NVMEM_SYSFS=y',
    'CONFIG_NVMEM_REALTEK_TAURUS_OTP=y',
    'CONFIG_MTD_UBI_NVMEM=y',
    # ===== 固件编进内核：解决 built-in 驱动早期 probe 读不到 rootfs 固件 =====
    # 真机日志：rtw89 5G 请求 -2.bin/-1.bin/.bin 三次，cfg80211 请求 regulatory.db，
    # 全在 rootfs(fit0) 挂载前，每次 sysfs fallback 卡 60s -> probe -22 无 WLAN。
    # 三个 5G 别名 + 2.4G + regulatory.db(.p7s) 全部内置，早期 probe 直接命中。
    # DIR=firmware 相对内核源码根；固件由 1b 步放到 files-6.18/firmware/。
    'CONFIG_EXTRA_FIRMWARE="rtw89/rtw8852c_fw-2.bin rtw89/rtw8852c_fw-1.bin rtw89/rtw8852c_fw.bin rtw89/rtw8192xb_fw.bin regulatory.db regulatory.db.p7s"',
    'CONFIG_EXTRA_FIRMWARE_DIR="firmware"',
]
p.write_text('\n'.join(lines + new) + '\n', encoding='utf-8', newline='\n')
PY
for sym in CONFIG_RTW89=y CONFIG_RTW89_CORE=y CONFIG_RTW89_PCI=y \
           CONFIG_RTW89_8192XB=y CONFIG_RTW89_8192XBE=y \
           CONFIG_RTW89_8852C=y CONFIG_RTW89_8852CE=y \
           '# CONFIG_RTW89_8851BE is not set' \
           '# CONFIG_RTW89_8851BU is not set' \
           '# CONFIG_RTW89_8852AE is not set' \
           '# CONFIG_RTW89_8852BE is not set' \
           '# CONFIG_RTW89_8852BU is not set' \
           '# CONFIG_RTW89_8852BTE is not set' \
           '# CONFIG_RTW89_8922AE is not set' \
           '# CONFIG_RTW89_DEBUGMSG is not set' \
           CONFIG_NVMEM=y CONFIG_NVMEM_LAYOUTS=y CONFIG_NVMEM_SYSFS=y \
           CONFIG_NVMEM_REALTEK_TAURUS_OTP=y CONFIG_MTD_UBI_NVMEM=y; do
  grep -qx "$sym" "$CFG" || fail "config 缺 $sym（缺 not-set 会让 syncconfig 遇 NEW 报错）"
done
grep -qx '# CONFIG_RTL_AX_AP is not set' "$CFG" \
  || fail "config 未显式关闭 CONFIG_RTL_AX_AP（只删行会让 syncconfig 按默认=m 重开，编译撞 pe-tx-code.h）"
! grep -q '^CONFIG_RTL_AX_AP=' "$CFG" || fail "config 仍有 CONFIG_RTL_AX_AP=m/y（两套驱动会抢 PCI 设备）"
# EXTRA_FIRMWARE 必须含真机日志请求的全部固件名（-2/-1/.bin + 2.4G + regdb）
for fw in rtw89/rtw8852c_fw-2.bin rtw89/rtw8852c_fw-1.bin rtw89/rtw8852c_fw.bin \
          rtw89/rtw8192xb_fw.bin regulatory.db regulatory.db.p7s; do
  grep -q "^CONFIG_EXTRA_FIRMWARE=\".*$fw.*\"$" "$CFG" \
    || fail "config 的 EXTRA_FIRMWARE 缺 $fw（早期 probe 会 sysfs fallback 卡 60s 后失败）"
done
grep -q '^CONFIG_EXTRA_FIRMWARE_DIR="firmware"$' "$CFG" \
  || fail "config 缺 CONFIG_EXTRA_FIRMWARE_DIR=firmware（内置固件找不到路径）"
echo "  config 已切 rtw89（NVMEM on / rtl_ax_ap off / 固件编内核 EXTRA_FIRMWARE）"

# ---- 4. DTS：把 factory 校准 cell 接到 PCIe wifi 节点 ----
# 公共 dtsi 已定义 pcie0(@f4325000)/pcie1(@f4326000) 与
# wifi_cal_radio0(@2000,5G)/radio1(@3000,2.4G)，但没把校准 cell 接到 PCIe 下的
# wifi 设备。rtw89_factory.c 用 nvmem_cell_get(dev,"wifi-calibration") 从各自
# PCI 设备节点读取，所以必须在这里绑。绑定加到公共 dtsi（所有板级 DTS 都 include
# 它），任一机型都能生效；这是修复"切天邑机型后无 WLAN"的关键。
python3 - "$DTS" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
if 'RTW89_NVMEM_BIND' in text:
    print('  DTS nvmem 绑定已存在，跳过')
    raise SystemExit(0)

block = '''
/* RTW89_NVMEM_BIND: 官方 rtw89 校准链路（来自上游 tyfza1-2p5g.dts） */
&pcie0 {
	status = "okay";

	wifi5g: wifi@0,0 {
		compatible = "pci10ec,c852";
		reg = <0x0000 0 0 0 0>;
		nvmem-cells = <&wifi_cal_radio0>;
		nvmem-cell-names = "wifi-calibration";
	};
};

&pcie1 {
	status = "okay";

	wifi2g: wifi@0,0 {
		compatible = "pci10ec,0192";
		reg = <0x0000 0 0 0 0>;
		nvmem-cells = <&wifi_cal_radio1>;
		nvmem-cell-names = "wifi-calibration";
	};
};
'''
p.write_text(text.rstrip() + '\n' + block, encoding='utf-8', newline='\n')
PY
grep -q 'RTW89_NVMEM_BIND' "$DTS" || fail "DTS nvmem 绑定失败"
grep -q 'nvmem-cells = <&wifi_cal_radio0>' "$DTS" || fail "5G 校准 cell 未绑定"
grep -q 'nvmem-cells = <&wifi_cal_radio1>' "$DTS" || fail "2.4G 校准 cell 未绑定"
echo "  DTS: pcie0(5G)/pcie1(2.4G) 已绑定 factory 校准 cell"

# ---- 5. 固件落地校验（两条链路） ----
# 链路 A（内核 built-in）：files-6.18/firmware/ 下 6 个文件（WiFi 4 含 -2/-1 别名
#   + regdb 2），由 CONFIG_EXTRA_FIRMWARE 编进内核，early probe 可读（1b 已落地）。
# 链路 B（rootfs 兜底）：files/lib/firmware/rtw89/ 下 2 个文件，workflow cp 进 rootfs，
#   供运行时固件重载使用。
for fw in rtw8852c_fw-2.bin rtw8852c_fw-1.bin rtw8852c_fw.bin rtw8192xb_fw.bin; do
  f="$FW_DST/$fw"
  [ -f "$f" ] || fail "缺内置固件 $f"
  [ "$(stat -c %s "$f")" -gt 100000 ] || fail "内置固件 $fw 大小异常"
done
for fw in regulatory.db regulatory.db.p7s; do
  f="$REGDB_DST/$fw"
  [ -f "$f" ] || fail "缺内置 regdb $f"
  [ -s "$f" ] || fail "内置 regdb $f 为空"
done
for fw in rtw8192xb_fw.bin rtw8852c_fw.bin; do
  f="$ASSETS/files/lib/firmware/rtw89/$fw"
  [ -f "$f" ] || fail "缺固件 $f"
  [ "$(stat -c %s "$f")" -gt 100000 ] || fail "固件 $fw 大小异常"
done
echo "  rtw89 固件就位（内核内置 WiFi 4 + regdb 2，rootfs 2）"

echo "RTW89_OVERLAY_OK=True (driver 6 + patch 1 + config + dts + fw builtin6/rootfs2)"
