#!/usr/bin/env bash
# 修复 Droidspaces 的 SYSVIPC kABI 补丁在部分 6.1 子版本上的上下文失配。
#
# 上游补丁（001.GKI-below-6.12-fix_sysvipc_kabi_*.patch）假设 struct task_struct
# 末尾的 ANDROID_KABI_RESERVE(1) 仍为空闲，因此用槽位 1/2/3 承载
# sysv_sem + sysv_shm。但在 6.1.118 等版本里槽位 1 已被
#   ANDROID_KABI_USE(1, unsigned int saved_state);
# 占用，补丁第二个 hunk 的上下文对不上而被拒绝（只留下 .rej），
# 而第一个 hunk（注释掉原始 sysvsem/sysvshm 字段）却已生效。
# 结果：CONFIG_SYSVIPC=y 后 ipc/sem.c、kernel/fork.c 找不到 task_struct 成员，编译失败。
#
# 本脚本按补丁原意补上缺失的槽位定义，整体向后顺延到 2/3/4。
# 全程幂等：已修复或补丁本就应用成功的场合直接跳过。
set -euo pipefail

SCHED="${1:-include/linux/sched.h}"

if [ ! -f "$SCHED" ]; then
  echo "::error::未找到 $SCHED"
  exit 1
fi

# 补丁第一个 hunk 未生效 -> 不是这个补丁的场景，直接跳过
if ! grep -qE '^[[:space:]]*//[[:space:]]*struct sysv_sem' "$SCHED"; then
  echo "未检测到 Droidspaces SYSVIPC 补丁的字段注释，跳过"
  exit 0
fi

# 槽位已就绪（补丁正常应用或本脚本已跑过）
if grep -qE 'ANDROID_KABI_USE\([0-9]+,[[:space:]]*struct sysv_sem sysvsem\)' "$SCHED"; then
  echo "SYSVIPC kABI 槽位已就绪，跳过"
  exit 0
fi

# 只处理槽位 1 被 saved_state 占用的布局
if ! grep -qF 'ANDROID_KABI_USE(1, unsigned int saved_state);' "$SCHED"; then
  echo "::error::未找到 saved_state 占用槽位 1 的布局，无法自动修复 SYSVIPC kABI" >&2
  exit 1
fi

python3 - "$SCHED" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

ANCHOR = "\tANDROID_KABI_USE(1, unsigned int saved_state);\n"
if ANCHOR not in lines:
    sys.exit("锚点行格式不符，放弃修改")

idx = lines.index(ANCHOR)

# 锚点之后应紧跟 RESERVE(2)/RESERVE(3)/RESERVE(4)
want = [
    "\tANDROID_KABI_RESERVE(2);\n",
    "\tANDROID_KABI_RESERVE(3);\n",
    "\tANDROID_KABI_RESERVE(4);\n",
]
if lines[idx + 1:idx + 4] != want:
    sys.exit(
        "锚点后的保留槽位不符合预期：\n" + "".join(repr(l) for l in lines[idx + 1:idx + 4])
    )

block = [
    "\n",
    "#ifdef CONFIG_SYSVIPC\n",
    "\tANDROID_KABI_USE(2, struct sysv_sem sysvsem);\n",
    "\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(3); ANDROID_KABI_RESERVE(4), struct sysv_shm sysvshm);\n",
    "#else\n",
    "\tANDROID_KABI_RESERVE(2);\n",
    "\tANDROID_KABI_RESERVE(3);\n",
    "\tANDROID_KABI_RESERVE(4);\n",
    "#endif\n",
]

new = lines[: idx + 1] + block + lines[idx + 4:]
path.write_text("".join(new), encoding="utf-8")

# 清掉残留的 .rej，避免产物里出现误导性的冲突文件
rej = path.with_name(path.name + ".rej")
if rej.exists():
    rej.unlink()
    print(f"已删除 {rej}")
print("已按槽位 2/3/4 补齐 SYSVIPC kABI 定义")
PY

echo "SYSVIPC kABI 修复完成"
grep -n -A5 "ANDROID_KABI_USE(1, unsigned int saved_state);" "$SCHED" | head -12
