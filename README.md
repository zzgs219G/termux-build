# termux-build

在 GitHub Actions 上交叉编译，产出 **Termux（aarch64 / Android）能直接用**的
二进制或 Python 扩展。

## 为什么需要这个仓库

很多库不发布 Android 预编译包，而手机上又编不动：

| 问题 | 具体表现 |
|---|---|
| 没有 Android wheel | `pip install lief` → `LIEF does not provide precompiled wheels for 'android - aarch64'` |
| 源码太老编不过 | `keystone-engine` 的 CMake 用了已移除的 `CMP0051` 策略 |
| 手机资源不够 | lief 几十万行 C++，本机可用内存 3.5 GB，编到第 12 个 .o 就吃力 |

CI 的 x86_64 runner 有完整资源和工具链，编完把产物拉回手机即可。

## 目录结构

每个构建目标一个目录，互不干扰：

```
termux-build/
├── .github/workflows/
│   └── build-lief.yml            构建 lief
└── lief/
    ├── pack-python-headers.sh    Termux 侧：生成 Python 头文件包
    ├── preflight.sh              推 CI 前的本地预检
    └── vendor/
        └── python-headers-3.14.tar.gz
```

要加新的构建目标（比如 keystone），就新增 `keystone/` 目录
和 `.github/workflows/build-keystone.yml`，不要动 `lief/`。

## 当前目标：lief

### 为什么必须带 Termux 的 pyconfig.h

lief 的 Python 绑定用 nanobind，构建时执行
`find_package(Python COMPONENTS Development.Module)`，需要**目标平台**的
`Python.h` 和 `pyconfig.h`。

runner 上的 `/usr/include/python3.x/pyconfig.h` 描述的是 **x86_64 + glibc**。
里面几十个平台相关宏（`SIZEOF_*`、`HAVE_*`、`_Py_*`）都是按 x86_64 生成的。
用错版本编出来的模块，Python 结构体（`PyObject_HEAD`、`PyTypeObject`）布局
按错误假设计算 → 真机 `import` 立刻崩，而且崩点看起来跟 lief 毫无关系。

所以本仓库**内置** Termux 的 `pyconfig.h`（408 KB），workflow 里还硬校验：

```bash
for k in SIZEOF_LONG SIZEOF_VOID_P; do
  v=$(grep "^#define $k " pyconfig.h | awk '{print $3}')
  [ "$v" = "8" ] || exit 1
done
```

### 为什么不能用 pip 的 sdist

PyPI 上的 lief sdist 是 **mock 包**（7.8 KB）。它的 `backend/setup.py:144`
里只有一段平台检查，真正源码 `src/` 和 `build-requirements.txt` 都被剔除。
从 sdist 永远编不出来，必须用 git 源码。

### 用法

```bash
# 1. 本地预检（19 项，能查的都先查，省 CI 时间）
./lief/preflight.sh

# 2. 推 CI
git add . && git commit -m "..." && git push

# 3. Actions 页面手动触发 "build lief for android arm64"
#    或打 tag：git tag v1 && git push --tags

# 4. 下载 artifact（lief-py3.14-android-arm64.tar.gz），拉回手机
cd ~/Download
tar xzf lief-py3.14-android-arm64.tar.gz   # 得到 lief/ 目录
rm -rf ~/逆向工具/pymods/lief
mv lief ~/逆向工具/pymods/

# 5. 验证
~/逆向工具/bin/repy -c "import lief; print(lief.__version__)"
# → 0.17.6-6f3594f
```

参数（都可留空用默认）：

| 输入 | 默认 | 说明 |
|---|---|---|
| `lief_ref` | `0.17.6` | LIEF 的 tag 或 commit |
| `python_version` | `3.14` | 必须与 Termux 一致 |
| `android_api` | `24` | 最低 API，Termux 是 24 |
| `ndk_version` | `29.0.0` | |

### artifact 里是什么

```
lief-py3.14-android-arm64.tar.gz
└── lief/
    ├── __init__.py                              from . import _lief 后 re-export 符号
    ├── _lief.cpython-314-aarch64-linux-android.so   编译产物（10 MB）
    ├── ELF/ DEX/ PE/ MachO/ ...                 纯 Python 子模块
    └── ...
```

两个容易踩的点（已在 CI 里硬校验）：

1. **扩展模块名必须是 `_lief.<abi>.so`**（下划线开头）。
   它的 init 函数是 `PyInit__lief`，改名成 `lief.*.so` 会报
   `ImportError: dynamic module does not define module export function (PyInit_lief)`。
2. **`DT_NEEDED` 必须含 `libpython3.14.so`**。
   Termux 的 `python3.14` 是动态链接 libpython 的（可执行文件本身只导出
   6 个符号，2162 个符号都在 `.so` 里）。Android 的 `dlopen` 不会把
   libpython 的符号暴露给扩展模块，所以模块必须自己声明依赖它。
   缺了会报 `cannot locate symbol "_Py_FalseStruct"`。

### Python 版本变了怎么办

```bash
./lief/pack-python-headers.sh          # 自动读当前 python3 版本
cp lief/dist/python-headers-*.tar.gz lief/vendor/
# 同时更新 vendor 里的 libpython（文件名带版本号）
cp $PREFIX/lib/libpythonX.Y.so lief/vendor/
git add lief/vendor/
```

同时在 workflow 里把 `PYTHON_VERSION` 默认值改掉，并把
`-lpython3.14` 改成对应版本。

## 已知风险（如实）

**已在真机验证通过**（2026-11-14）：
`import lief` → `0.17.6-6f3594f`，`lief.ELF.parse()` 正常读段表。

仍然存在的限制：

| 项 | 说明 |
|---|---|
| lief 版本 | 只在 `0.17.6` 上验证过。换版本可能遇到新的 API/CMake 变化 |
| Python 版本 | 只在 3.14 上验证。换版本必须同时换 pyconfig.h 和 libpython |
| 其他 ABI | 只构建 arm64-v8a。armeabi-v7a 需要改 `ANDROID_ABI` 和 libpython |
| ccache | key 含 LIEF_REF/api/python 版本，任一变化必然全量重编（约 7 分钟）；同参数重跑约 30 秒 |

## 历史

本仓库原名 `reasonix-termux`，用于记录 DeepSeek-Reasonix CLI 在 Termux
的安装方法。原内容已删除，仓库改为通用的交叉编译流水线。
