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

# 4. 下载 artifact，拉回手机
mkdir -p ~/逆向工具/pymods/lief
cp ~/Download/lief*.so ~/逆向工具/pymods/lief/

# 5. 验证
~/逆向工具/bin/repy -c "import lief; print(lief.__version__)"
```

参数（都可留空用默认）：

| 输入 | 默认 | 说明 |
|---|---|---|
| `lief_ref` | `main` | LIEF 的 tag 或 commit。**建议先用 `0.17.6`** |
| `python_version` | `3.14` | 必须与 Termux 一致 |
| `android_api` | `24` | 最低 API，Termux 是 24 |
| `ndk_version` | `29.0.0` | |

### Python 版本变了怎么办

```bash
./lief/pack-python-headers.sh          # 自动读当前 python3 版本
cp lief/dist/python-headers-*.tar.gz lief/vendor/
git add lief/vendor/
```

同时在 workflow 里把 `PYTHON_VERSION` 默认值改掉。

## 已知风险（如实）

**这套脚本没在真机验证过。** 本机内存只剩 3.5 GB，编 lief 不现实，
所以只能靠 CI。第一次跑很可能要改，最可能卡在三处：

| 环节 | 可能失败 | 修法 |
|---|---|---|
| `find_package(Python)` | 仍去用 runner 的 x86_64 Python | 加 `-DPython_NO_SYSTEM_PACKAGES=ON` |
| 链接 | 要 `libpython3.14.so`（Android 没有） | 传空 `-DPython_LIBRARY=` |
| 产物导入 | 真机 ImportError | `readelf -d` 看 `DT_NEEDED`，不该有 libpython |

其他变量：

- **lief 版本**：默认 `main`。建议先 `lief_ref = 0.17.6` 跑通再试新版。
- **Python 3.14 太新**：lief 要求 `>= 3.10`，但 nanobind 对 3.14 的兼容性是变量。
- **时间**：给了 180 分钟超时，2 核 runner 全量编译约 30–60 分钟。

## 历史

本仓库原名 `reasonix-termux`，用于记录 DeepSeek-Reasonix CLI 在 Termux
的安装方法。原内容已删除，仓库改为通用的交叉编译流水线。
