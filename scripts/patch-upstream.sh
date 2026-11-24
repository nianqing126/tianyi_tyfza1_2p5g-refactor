#!/bin/bash
# 修补上游源码树里与本机型相关的缺陷（幂等，可重复执行）。
#
# 用法：
#   ASSETS=<资产目录> WRT=<源码树> bash scripts/patch-upstream.sh
#
# 修三件事：
#   1. package/tyfza1-pon-control/files/tyfza1-factory 的 factory_blob() 参数错位：
#      函数签名是 factory_blob <offset> <size> <dest>，但结尾写的是
#        mv "$tmp" "$2"
#      $2 是「长度」而不是目标路径，于是临时文件被 mv 成当前目录下名为 4096 的文件，
#      目标目录永远是空的 → /lib/firmware 下 flash-calibration.bin / bosa-calibration.bin /
#      a2h.bin 全是悬空软链接，WiFi 校准与 BOSA 校准拿不到数据。
#      修法：mkdir -p 目标目录 + mv "$tmp" "$3"。
#   2. 校验 rootfs overlay 里的 WiFi AP 固件齐全（上游没有任何包安装它们，
#      只能由 files/lib/firmware/realtek/tyfza1/ 提供）。
#   3. 放开 generic/510 fitblk 的 4 MiB FIT 上限（改 16384 页 + kvmalloc），
#      否则 /dev/fit0 建不出来，刷入态启动直接灯全灭。

set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
FACTORY="$WRT/package/tyfza1-pon-control/files/tyfza1-factory"
FW_DIR="$ASSETS/files/lib/firmware/realtek/tyfza1"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 1. tyfza1-factory: factory_blob 目标参数 ----------
[ -f "$FACTORY" ] || fail "找不到 $FACTORY（上游目录结构变了？）"

if grep -q 'mv "\$tmp" "\$2"' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tmv "$tmp" "$2"'
new = '\t\tmkdir -p "${3%/*}"\n\t\tmv "$tmp" "$3"'
if old not in text:
    raise SystemExit('ERROR: 未找到预期的 mv "$tmp" "$2" 行（缩进不符）')
p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')
print('patched tyfza1-factory: factory_blob -> mv "$tmp" "$3"')
PY
else
  echo "tyfza1-factory 已是修好的版本，跳过"
fi

grep -q 'mv "\$tmp" "\$3"' "$FACTORY" \
  || fail 'tyfza1-factory 修补失败：没有 mv "$tmp" "$3"'

# ---------- 1b. tyfza1-factory: flash-calibration 只写 284 字节 ----------
# 2026-11-13 真机联机实测：驱动 board-cal.h 要求
#   fw->size == sizeof(struct rtl_ax_board_cal) == 284（TYFC0003 容器）
# 大小不符直接 -EINVAL，两张卡 probe 全挂、无 phy0/phy1、无线全无。
# 上游写整块 4096 字节（结构体后全是 0xFF），必须改成 284。
# 保险起见包脚本与 files/ 覆盖副本都修（本脚本只改包内原件；
# files/etc/init.d/tyfza1-factory 是我们的权威覆盖副本，仓库里已是 284）。
if grep -q '0x2000)) 4096' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old5 = 'factory_blob $((0x2000)) 4096 "$runtime/tyfza1/rtl8852ce/flash-calibration.bin"'
old2 = 'factory_blob $((0x3000)) 4096 "$runtime/tyfza1/rtl8192xbe/flash-calibration.bin"'
new5 = 'factory_blob $((0x2000)) 284 "$runtime/tyfza1/rtl8852ce/flash-calibration.bin"'
new2 = 'factory_blob $((0x3000)) 284 "$runtime/tyfza1/rtl8192xbe/flash-calibration.bin"'
if old5 not in text or old2 not in text:
    raise SystemExit('ERROR: 未找到 4096 的 flash-calibration factory_blob 行')
text = text.replace(old5, new5, 1).replace(old2, new2, 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched tyfza1-factory: flash-calibration 4096 -> 284')
PY
else
  echo "tyfza1-factory flash-calibration 已是 284 字节版本，跳过"
fi
grep -q '0x2000)) 284' "$FACTORY" \
  || fail 'tyfza1-factory 修补失败：flash-calibration 没改成 284 字节'
! grep -q 'mv "\$tmp" "\$2"' "$FACTORY" \
  || fail 'tyfza1-factory 仍残留 mv "$tmp" "$2"'

# 空块（R10 的 0x4000 bosa / 0x5000 a2h 区域整段 0xFF）会静默跳过，
# 加一条 logger 便于真机排查「校准软链接悬空」这类问题。
if ! grep -q 'is empty, skipped' "$FACTORY"; then
  python3 - "$FACTORY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old = '\t\tchmod 0644 "$tmp"\n'
assert old in text, 'chmod line not found'
text = text.replace(old, '', 1)   # 让 chmod 只作用于成功分支后的临时文件
old_else = '\telse\n\t\trm -f "$tmp"\n\t\treturn 1\n'
new_else = '\telse\n\t\tlogger -t tyfza1-factory "$3 is empty, skipped"\n\t\trm -f "$tmp"\n\t\treturn 1\n'
assert old_else in text, 'else branch not found'
text = text.replace(old_else, new_else, 1)
text = text.replace('\t\tmv "$tmp" "$3"\n', '\t\tchmod 0644 "$tmp"\n\t\tmv "$tmp" "$3"\n', 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched tyfza1-factory: log skipped blobs')
PY
fi
grep -q 'is empty, skipped' "$FACTORY" \
  || fail 'tyfza1-factory 缺少跳过日志'

# 修好后 factory_blob 必须是 284 字节调用（两条卡各一处），避免上游再次改动后静默错位
grep -q 'factory_blob \$((0x2000)) 284' "$FACTORY" \
  || fail 'factory_blob 8852ce 调用点与预期不符（上游改动？）'
grep -q 'factory_blob \$((0x3000)) 284' "$FACTORY" \
  || fail 'factory_blob 8192xbe 调用点与预期不符（上游改动？）'

# ---------- 2. WiFi AP 固件齐全性 ----------
# 上游没有任何包提供这些 bin，缺一个驱动就 request_firmware -2 直接失败。
EXPECTED="
rtl8852c-u1-ap.bin 406448
rtl8852c-u2-ap.bin 369160
rtl8192xb-u1-ap.bin 387680
rtl8192xb-u2-ap.bin 387752
array_mp_8852c_nctl_reg.bin 14256
array_mp_8852c_nctl_reg_a.bin 14152
array_mp_8192xb_nctl_reg.bin 11368
"

count=0
while read -r name size; do
  [ -n "${name:-}" ] || continue
  f="$FW_DIR/$name"
  [ -f "$f" ] || fail "缺少 WiFi 固件 $f"
  actual=$(stat -c %s "$f")
  [ "$actual" = "$size" ] \
    || fail "$name 大小不符：期望 $size，实际 $actual（文件被截断？）"
  count=$((count + 1))
done <<EOF
$EXPECTED
EOF

[ "$count" = 7 ] || fail "WiFi 固件数量异常：$count != 7"
extra=$(find "$FW_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)
[ "$extra" = 7 ] || fail "WiFi 固件目录里有 $extra 个 .bin，期望 7 个（多余文件需确认用途）"

# ---------- 3. fitblk：解除 4MiB FIT 上限（刷入态起不来的根因） ----------
#
# target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch
# 里写着（注意 FIT_MAX_PAGES 与数值之间是两个 TAB，不是空格）：
#   #define FIT_MAX_PAGES		1024
#   if (size > PAGE_SIZE * FIT_MAX_PAGES) ret = -EOPNOTSUPP;
#   fit = kmalloc(size, GFP_KERNEL);
# 4 KiB 页时上限只有 4 MiB，而本机型 sysupgrade 的 FIT 是 20.7 MB、initramfs 是
# 23.6 MB，于是 probe 直接返回 -95：
#   fitblk fitblk: probe with driver fitblk failed with error -95
# /dev/fit0 永远不出现 → 内核按 root=/dev/fit0 挂根失败 → 灯全灭。
# initramfs 不需要 root 设备，所以内存启动一直正常：这正是"内存能起、刷入起不来"
# 的唯一原因。
#
# 修法：上限提到 16384 页（64 MiB），并把整块 kmalloc 改成 kvmalloc —— 20 MB
# 的 kmalloc 会因伙伴系统 MAX_ORDER 直接 -ENOMEM，vmalloc 走 vmap 区才拿得到。
# run20 教训：匹配必须对空白容错（\s+），按单空格精确匹配直接 0 命中 fail。
FITBLK_PATCH="$WRT/target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch"
[ -f "$FITBLK_PATCH" ] || fail "找不到 $FITBLK_PATCH（上游 pending 目录结构变了？）"

# 幂等守卫：已放开上限（16384）则整段跳过，避免二次执行时找不到 1024 报错
if grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+16384' "$FITBLK_PATCH"; then
  echo "fitblk 补丁已放开上限，跳过"
else
python3 - "$FITBLK_PATCH" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
subs = [
    # 上游原文是 "#define FIT_MAX_PAGES\t\t1024"（两个 TAB），用 \s+ 容错匹配
    (r'#define\s+FIT_MAX_PAGES\s+1024\b', '#define FIT_MAX_PAGES\t\t16384'),
    (r'fit = kmalloc\(size, GFP_KERNEL\);', 'fit = kvmalloc(size, GFP_KERNEL);'),
    (r'\bkfree\(fit\);', 'kvfree(fit);'),
]
for old, new in subs:
    hits = re.findall(old, text)
    if len(hits) != 1:
        raise SystemExit('ERROR: fitblk 补丁里 %r 出现 %d 次（期望 1 次，上游改动？）'
                         % (old, len(hits)))
    text = re.sub(old, new, text, count=1)
# kvmalloc 声明在 <linux/slab.h>、kvfree 在 <linux/vmalloc.h>；上游新增的
# fitblk.c 没有显式包含它们（原来靠 kmalloc 的传递包含），显式补上避免隐性依赖。
# 注意：插入的是"新建文件"hunk 里的 + 行，必须同步把 hunk 头 @@ -0,0 +1,N @@
# 的 N 加 2，否则行数计数失配，git apply / quilt 会拒绝整个补丁。
if '<linux/slab.h>' not in text:
    anchor = '+#include <linux/refcount.h>\n'
    if text.count(anchor) != 1:
        raise SystemExit('ERROR: fitblk 补丁里 %r 出现 %d 次，无法插入 slab.h'
                         % (anchor, text.count(anchor)))
    text = text.replace(anchor,
        anchor + '+#include <linux/slab.h>\n+#include <linux/vmalloc.h>\n', 1)
    ins = text.find('+#include <linux/slab.h>\n')
    hstart = text.rfind('\n@@', 0, ins) + 1
    hend = text.find('\n', hstart)
    hline = text[hstart:hend]
    m = re.match(r'@@ -(\d+(?:,\d+)?) \+(\d+(?:,\d+)?) @@$', hline)
    if not m:
        raise SystemExit('ERROR: 无法解析插入点所在 hunk 头：%r' % hline)
    add, newc = m.group(2).split(',')
    hline2 = hline.replace(' +%s,%s @@' % (add, newc),
                           ' +%s,%d @@' % (add, int(newc) + 2), 1)
    text = text[:hstart] + hline2 + text[hend:]
    # 校验：从 hunk 头之后起，第 N 行（N=新计数）之前必须都是 +/空格/-/ 续行，
    # 第 N+1 行必须是下一个 diff 头（diff --git / --- / +++ / @@）或文件尾。
    lines = text.split('\n')
    hidx = text[:hstart].count('\n')          # hunk 头所在行号
    n = int(newc) + 2
    for ln in lines[hidx + 1 : hidx + 1 + n]:
        if ln and ln[0] not in '+-\\ ':
            raise SystemExit('ERROR: hunk 正文混入非补丁行：%r' % ln[:60])
    if len(lines) > hidx + 1 + n:
        after = lines[hidx + 1 + n]
        if after and not after.startswith(('diff ', '--- ', '+++ ', '@@ ')):
            raise SystemExit('ERROR: hunk 行数与声明不符，第 %d 行是 %r'
                             % (hidx + 2 + n, after[:60]))
p.write_text(text, encoding='utf-8', newline='\n')
print('patched fitblk: FIT_MAX_PAGES 1024 -> 16384, kmalloc -> kvmalloc, +slab/vmalloc.h')
PY

grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+16384' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（FIT_MAX_PAGES）'
grep -q 'fit = kvmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvmalloc）'
grep -q 'kvfree(fit);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvfree）'
grep -q '#include <linux/slab.h>' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁缺少 slab.h（kvmalloc 声明）'
grep -q '#include <linux/vmalloc.h>' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁缺少 vmalloc.h（kvfree 声明）'
! grep -q 'fit = kmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁仍残留 kmalloc(size)'
! grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+1024' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁仍残留 1024 上限'
echo "FITBLK_LIMIT_OK=True (16384 pages = 64 MiB, kvmalloc)"
fi

echo "patch-upstream OK: factory_blob 已修，WiFi 固件 7/7 校验通过，fitblk 上限已放开"

# ---------- 4. rtl9617c-xram: R10 面板端口命名 ----------
# 上游命名 switch 按 2.5G 板写死：2.5G jack=NI port6 -> lan1，GE jack port1..3 ->
# lan2..lan4，port0 幻影口 -> lan0。R10 是 4×GE，内部 GPHY 在 NI port0..3，且 PCB
# 反序接线：port0=面板 LAN4、port1=LAN3、port2=LAN2、port3=LAN1
# （2026-11-14 用户真机逐口插线验证）。套用上游映射的结果：
#   lan1 缺失、lan0 被当 WAN/幻影口、面板 LAN2/LAN3 名字互换。
# 修法：机器 compatible 含 youhua,pt1570-r10 时 index = 4 - port，lan1..lan4 与
# 面板丝印一一对应；其它机型（含天邑 2.5G/4GE）仍走上游 switch，互不影响。
XRAM="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/ethernet/realtek/rtl9617c-xram.c"
[ -f "$XRAM" ] || fail "找不到 $XRAM（上游目录结构变了？）"
if grep -q 'of_machine_is_compatible("youhua,pt1570-r10")' "$XRAM"; then
  echo "xram R10 端口命名已修补，跳过"
else
python3 - "$XRAM" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
anchor = '\tswitch (port) {\n\tcase 0:\n\t\tindex = 0;'
if text.count(anchor) != 1:
    raise SystemExit('ERROR: xram.c 端口命名 switch 锚点出现 %d 次（期望 1，上游改动？）'
                     % text.count(anchor))
patch = (
    '\tif (of_machine_is_compatible("youhua,pt1570-r10")) {\n'
    '\t\t/* R10: the four internal GPHYs sit on NI ports 0..3 and the PCB\n'
    '\t\t * routes them to the panel in reverse (2026-11-14 user-verified\n'
    '\t\t * per jack): port 0 = silkscreen LAN4 ... port 3 = LAN1. Name by\n'
    '\t\t * silkscreen so lan1..lan4 match the case labels. */\n'
    '\t\tindex = 4 - port;\n'
    '\t} else\n'
)
text = text.replace(anchor, patch + anchor, 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched rtl9617c-xram: R10 silkscreen naming (index = 4 - port)')
PY
fi
grep -q 'of_machine_is_compatible("youhua,pt1570-r10")' "$XRAM" \
  || fail 'xram R10 端口命名修补失败'
grep -q 'index = 4 - port;' "$XRAM" \
  || fail 'xram R10 命名映射（index = 4 - port）缺失'
echo "XRAM_R10_NAMING_OK=True (lan1..lan4 = panel LAN1..LAN4)"

# ---------- 5. 公共 dtsi 的 chosen.bootargs 补齐 FIT 自洽启动参数 ----------
# 上游 rtl9617c-tyfza1.dtsi 的 /chosen/bootargs 只有 console/loglevel，
# 没有 root= 和 u-boot,version；它靠 bootloader 把 rootdisk 翻成 root= 注入，
# 但 qwe-qaq rtl9617c-uboot 没有这段逻辑 -> 内核挂根失败（刷入起不来）。
# R10 板级 DTS 自带一个完整 chosen 覆盖块，所以 R10 一直是好的；
# 天邑 4GE/2.5G 用上游 DTS、没有覆盖块，才暴露这个问题（run #... 的
# verify-fit-boot.py: bootargs 里没有 root=/dev/fit0）。
# 这里改公共 dtsi：对所有板级 DTS（R10/天邑4GE/天邑2.5G）统一生效，
# R10 自己的覆盖块后写覆盖、值相同，不受影响。rootdisk/volname=fit 上游已有，
# 不动（verify-fit-boot.py 的 phandle 检查依赖它）。
DTSI="$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi"
[ -f "$DTSI" ] || fail "找不到 $DTSI（上游 dtsi 结构变了？）"
python3 - "$DTSI" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')

BOOT_EXTRA = ' root=/dev/fit0 rootwait rootfstype=squashfs'
# 已修过（幂等）：bootargs 已含 root=/dev/fit0 且 chosen 内有 u-boot,version
if 'root=/dev/fit0' in text and 'u-boot,version' in text:
    print('dtsi chosen.bootargs 已含 FIT 启动参数，跳过')
    raise SystemExit(0)

lines = text.split('\n')
out = []
in_chosen = False
boot_done = uboot_done = False
for ln in lines:
    # 只处理第一个 /chosen 块（含 bootargs 的那个）；用大括号深度避免误判
    if re.match(r'^\s*chosen\s*\{', ln):
        in_chosen = True
    if in_chosen and re.match(r'^\s*bootargs\s*=', ln):
        m = re.match(r'^(\s*bootargs\s*=\s*")([^"]*)(".*)$', ln)
        if not m:
            raise SystemExit('ERROR: bootargs 行格式无法解析: ' + ln)
        val = m.group(2)
        if 'root=/dev/fit0' not in val:
            ln = m.group(1) + val.rstrip() + BOOT_EXTRA + m.group(3)
        boot_done = True
        out.append(ln)
        # 紧随 bootargs 之后插入 u-boot,version（同一 chosen 块内）
        if 'u-boot,version' not in text:
            indent = re.match(r'^(\s*)', ln).group(1)
            out.append(indent + 'u-boot,version = "2025.01";')
            uboot_done = True
        continue
    out.append(ln)
    if in_chosen and re.match(r'^\s*\};', ln):
        in_chosen = False

new = '\n'.join(out)
if 'root=/dev/fit0' not in new:
    raise SystemExit('ERROR: 未能给 bootargs 追加 root=/dev/fit0')
if 'u-boot,version' not in new:
    raise SystemExit('ERROR: 未能给 chosen 补 u-boot,version')
p.write_text(new, encoding='utf-8', newline='\n')
print('dtsi chosen: bootargs 补齐 root=/dev/fit0 rootwait rootfstype=squashfs + u-boot,version')
PY
# 断言
grep -q 'bootargs = ".*root=/dev/fit0.*rootwait' "$DTSI" \
  || fail "dtsi bootargs 未补齐 root=/dev/fit0/rootwait"
grep -q 'u-boot,version' "$DTSI" \
  || fail "dtsi chosen 缺 u-boot,version"
grep -q 'rootdisk' "$DTSI" \
  || fail "dtsi 丢 rootdisk（fitblk ABI 会被破坏）"
echo "DTSI_FIT_BOOT_OK=True (公共 dtsi 的 chosen 已是 FIT 自洽启动参数)"
