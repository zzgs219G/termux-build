#!/data/data/com.termux/files/usr/bin/bash
# preflight.sh — 上传 CI 之前，在 Termux 本地做能做的全部检查
#
# 目的：CI 一轮要 20-40 分钟。凡是本机能便宜验证的，都不要浪费 CI 时间。
#       这里每一项失败都对应一个 CI 里会出现、但排查要花很久的错误。
#
# 用法：./preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"        # …/lief
ROOT="$(cd "$HERE/.." && pwd)"               # 仓库根
cd "$ROOT"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }

echo "=== preflight: lief android arm64 构建前置检查 ==="
echo

# ── 1. workflow 文件存在且语法上像 YAML ─────────────────────────────
echo "[1] workflow 文件"
WF=".github/workflows/build-lief.yml"
if [ -f "$WF" ]; then ok "$WF 存在"; else bad "$WF 不存在"; fi

# ── 2. Python 头文件包 ─────────────────────────────────────────────
echo "[2] Python 头文件包（交叉编译的关键输入）"
ART=$(ls "$HERE"/vendor/python-headers-*.tar.gz 2>/dev/null | head -1)
if [ -z "$ART" ]; then
    bad "lief/vendor/ 下没有 python-headers-*.tar.gz"
    echo "      → 先跑 ./lief/pack-python-headers.sh"
else
    ok "包存在: $ART ($(du -h "$ART" | cut -f1))"
    TMP=$(mktemp -d)
    if tar xzf "$ART" -C "$TMP" 2>/dev/null; then
        PYH=$(find "$TMP" -maxdepth 2 -name pyconfig.h | head -1)
        PYC=$(find "$TMP" -maxdepth 2 -name Python.h | head -1)
        if [ -n "$PYH" ]; then ok "含 pyconfig.h"; else bad "缺 pyconfig.h"; fi
        if [ -n "$PYC" ]; then ok "含 Python.h";  else bad "缺 Python.h";  fi
        if [ -n "$PYH" ]; then
            for k in SIZEOF_LONG SIZEOF_VOID_P; do
                v=$(grep -E "^#define $k " "$PYH" | awk '{print $3}')
                if [ "$v" = "8" ]; then ok "$k=8（64 位，正确）"
                else bad "$k=$v（应为 8；这份头文件不是 aarch64 Android 的）"; fi
            done
            # 版本号要能和 workflow 里的 PYTHON_VERSION 对上
            d=$(dirname "$PYH"); dname=$(basename "$d")
            ok "头文件目录名: $dname"
            WFVER=$(grep -oP "PYTHON_VERSION: .*?\| '\K[0-9.]+" "$WF" 2>/dev/null | head -1)
            case "$dname" in
                *"${WFVER:-3.14}"*) ok "与 workflow 的 PYTHON_VERSION=${WFVER:-3.14} 匹配" ;;
                *) bad "目录名 $dname 与 workflow 的 ${WFVER:-3.14} 不匹配" ;;
            esac
        fi
    else
        bad "包解压失败"
    fi
    rm -rf "$TMP"
fi

# ── 3. workflow 里的分支假设 ───────────────────────────────────────
echo "[3] workflow 内容检查"
grep -q "android.toolchain.cmake" "$WF" && ok "用了 NDK 的 toolchain file" \
    || bad "没引用 android.toolchain.cmake，交叉编译不会生效"
grep -q "LIEF_PYTHON_API=OFF" "$WF" && ok "核心库阶段关了 Python 绑定（分两步编译）" \
    || warn "没显式 LIEF_PYTHON_API=OFF，可能与下一步冲突"
grep -q "LIEF_PRECOMPILED=OFF" "$WF" && ok "绑定阶段从源码编（不依赖预编译 LIEF）" \
    || warn "没设 LIEF_PRECOMPILED=OFF，find_package(LIEF) 可能失败"
grep -q "Python_INCLUDE_DIR" "$WF" && ok "显式指定 Python_INCLUDE_DIR" \
    || bad "没指定 Python_INCLUDE_DIR，CMake 会去用 runner 的 x86_64 头"

# ── 4. NDK 可达性（判断 workflow 里的 URL 对不对）────────────────────
echo "[4] NDK 下载地址（workflow 里写死的 URL 是否有效）"
NDK_VER=$(grep -oP "NDK_VERSION: '\K[0-9.]+" "$WF" | head -1)
NDK_VER=${NDK_VER:-29.0.0}
MAJOR=${NDK_VER%%.*}
URL="https://dl.google.com/android/repository/android-ndk-r${MAJOR}-linux.zip"
code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 20 "$URL" 2>/dev/null)
if [ "$code" = "200" ]; then ok "r${MAJOR} 可下载（HTTP 200）"
else bad "r${MAJOR} 不可下载（HTTP $code）→ $URL"; fi

# ── 5. 本机 NDK 是否也支持（用于本地对照，非必需）───────────────────
echo "[5] 本机 NDK（仅参考，CI 不用它）"
if [ -d "$HOME/android-sdk/ndk" ]; then
    for d in "$HOME"/android-sdk/ndk/*/; do
        h=$(basename "$(find "$d/toolchains/llvm/prebuilt" -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)")
        [ -n "$h" ] && ok "本机 NDK $(basename "$d"): prebuilt=$h"
    done
else
    warn "本机没有 android-sdk/ndk"
fi

# ── 6. lief 源码结构（确认不是 PyPI 上的 mock sdist）────────────────
echo "[6] LIEF 源码结构假设"
if [ -d "$HOME/tmp/lief-git" ]; then
    ok "本机有 lief 源码副本（~/tmp/lief-git）"
    [ -f "$HOME/tmp/lief-git/src/CMakeLists.txt" ] && ok "src/CMakeLists.txt 存在（完整源码）" \
        || bad "缺 src/CMakeLists.txt（可能是 mock sdist）"
    [ -f "$HOME/tmp/lief-git/api/python/build-requirements.txt" ] && ok "build-requirements.txt 存在" \
        || bad "缺 build-requirements.txt（mock sdist 特征）"
    grep -q "LIEF_PYTHON_API" "$HOME/tmp/lief-git/cmake/LIEFOptions.cmake" 2>/dev/null \
        && ok "LIEFOptions.cmake 有 LIEF_PYTHON_API 开关" || warn "找不到该开关，选项名可能变了"
else
    warn "本机没有 lief 源码副本，跳过（CI 会自己 clone）"
fi

echo
echo "=== 结果: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] || { echo "有失败项，先修再推 CI"; exit 1; }
echo "本机能验的都过了。剩下必须在 CI 才能验：实际交叉编译。"
