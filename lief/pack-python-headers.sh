#!/data/data/com.termux/files/usr/bin/bash
# pack-python-headers.sh — 把 Termux 的 Python 头文件打包，供 CI 交叉编译用
#
# 为什么需要这一步：
#   lief 的 Python 绑定用 nanobind，构建时要 find_package(Python
#   COMPONENTS Development.Module)。交叉编译到 Android arm64 时，
#   必须提供【目标平台】的 Python.h 和 pyconfig.h。
#
#   为什么不能用 runner 上自带的 Python 头文件：
#     runner 是 x86_64 Linux，它的 pyconfig.h 描述的是 glibc + x86_64，
#     里面 SIZEOF_LONG / SIZEOF_VOID_P / HAVE_FORK 等值是按 x86_64 生成的。
#     用这份头文件编出来的 .so 里，Python 结构体（PyObject_HEAD 等）的
#     布局会按错误的宽度算 → 产物在真机 import 时直接崩，或读错字段。
#
#   而 Termux 的 pyconfig.h 就是 aarch64-Android 的，宽度/特性全对，
#   所以以它为准。
#
# 用法：
#   ./pack-python-headers.sh              # 产出 dist/python-headers.tar.gz
#   ./pack-python-headers.sh 3.13         # 指定版本
set -euo pipefail

VER="${1:-$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')}"
SRC="$PREFIX/include/python$VER"

[ -d "$SRC" ] || {
    echo "✗ 找不到 $SRC" >&2
    echo "  当前 PREFIX=$PREFIX" >&2
    echo "  已安装的 python 头文件目录：" >&2
    ls -d "$PREFIX"/include/python* 2>/dev/null >&2 || echo "    （一个都没有）" >&2
    exit 1
}
[ -f "$SRC/pyconfig.h" ] || { echo "✗ 缺 $SRC/pyconfig.h" >&2; exit 1; }
[ -f "$SRC/Python.h" ]   || { echo "✗ 缺 $SRC/Python.h" >&2; exit 1; }

OUT_DIR="$(cd "$(dirname "$0")" && pwd)/dist"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/python-headers-$VER.tar.gz"

# 只打头文件：整个 include 目录下还有别的库的头（openssl 等），
# 全打会到几十 MB，而 CI 只需要 Python 的。
cd "$PREFIX/include"
tar czf "$OUT" "python$VER"

echo "✅ $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "内容抽查（关键三项）："
tar tzf "$OUT" | grep -E "pyconfig\.h$|Python\.h$" | head -5
echo
echo "pyconfig.h 里的目标平台关键值："
grep -E "^#define (SIZEOF_LONG|SIZEOF_VOID_P|HAVE_FORK) " "$SRC/pyconfig.h" | sed 's/^/  /'
echo
echo "下一步：把这个文件传到 CI 那边（三选一，见 README.md）"
