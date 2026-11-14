# android-python-module.cmake — 预定义 Python::Module，绕开 find_package 的 libpython 依赖
#
# 为什么需要：
#   lief 的 Python 绑定通过 nanobind 构建。nanobind 的 CMakeLists.txt:140
#   有这段判断：
#
#       if (NOT TARGET Python::Module OR NOT TARGET Python::Interpreter)
#         find_package(Python 3.8 REQUIRED COMPONENTS Interpreter Development.Module)
#       endif()
#
#   也就是说：如果 Python::Module 和 Python::Interpreter 两个 target 都已存在，
#   它就不会调 find_package。
#
#   而 find_package(Development.Module) 在 Android 交叉编译下必然失败：
#   它要 Python_LIBRARIES（即 libpython3.14.so），但 Android 上【没有】
#   独立的 libpython —— Python 符号是编进进程里的（Termux 的 python 可执行
#   文件本身就是宿主）。扩展模块只需要 [Python.h 头] + [运行时已存在的符号]，
#   不链接 libpython。这是 Android/Linux 嵌入式平台编译 Python 扩展的标准做法。
#
#   实测报错（run 43593822048 第 10 步）：
#       Could NOT find Python (missing: Python_LIBRARIES Development.Module)
#       (found suitable version "3.14.4", minimum required is "3.8")
#
# 做法：
#   手工造出两个 imported target，指向 Termux 的头文件目录。
#   不设 IMPORTED_LOCATION（因为不存在对应的 .so），只给头文件路径。
#
# 变量来源（workflow 里通过 -D 传入）：
#   NB_PYINC       目标平台 Python 头文件目录（含 Python.h / pyconfig.h）
#   NB_PYEXE       runner 上可执行的 python3，仅用于探测版本号
if (NOT DEFINED NB_PYINC)
  message(FATAL_ERROR "需要 -DNB_PYINC=<目标平台 Python 头文件目录>")
endif()

# ── Interpreter：nanobind 用它查 Python 版本，指向 runner 的 python3 ──
# 只用来取版本号，不参与编译产物，所以用 host 的解释器是正确的。
if (NOT DEFINED NB_PYEXE)
  set(NB_PYEXE "python3")
endif()

execute_process(
  COMMAND "${NB_PYEXE}" -c "import sys; print('%d.%d' % sys.version_info[:2])"
  OUTPUT_VARIABLE _nb_pyver
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _nb_rc
)
if (NOT _nb_rc EQUAL 0)
  message(FATAL_ERROR "无法用 ${NB_PYEXE} 探测 Python 版本")
endif()
message(STATUS "nanobind shim: Python 版本 ${_nb_pyver}")

# 版本号也要给 CMake 的 find 逻辑用（某些模块会读这些变量）
set(Python_VERSION      "${_nb_pyver}")
set(Python_VERSION_MAJOR "${_nb_pyver}" )
string(REPLACE "." ";" _nb_vl "${_nb_pyver}")
list(GET _nb_vl 0 _nb_major)
list(GET _nb_vl 1 _nb_minor)
set(Python_VERSION_MAJOR "${_nb_major}")
set(Python_VERSION_MINOR "${_nb_minor}")

# ── Interpreter target ──
if (NOT TARGET Python::Interpreter)
  add_executable(Python::Interpreter IMPORTED)
  set_target_properties(Python::Interpreter PROPERTIES
    IMPORTED_LOCATION "${NB_PYEXE}"
  )
endif()

# ── Module target（关键）：只有头文件，没有 IMPORTED_LOCATION ──
#
# 不设 IMPORTED_LOCATION 是刻意的：
#   - Linux 上 CMake 允许 MODULE 类型的 imported target 不带 location
#     （头文件-only 是合法用法，nanobind 自己的文档也提到这个场景）
#   - 一旦设了，链接阶段会尝试把它加进 link line，而 Android 没有 libpython
#     可链，会报 cannot find -lpython3.14
if (NOT TARGET Python::Module)
  add_library(Python::Module INTERFACE IMPORTED)
  set_target_properties(Python::Module PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${NB_PYINC}"
  )
endif()

# nanobind 的 nanobind-config.cmake 会读这些变量决定 ABI tag 和编译宏
set(Python_INCLUDE_DIRS "${NB_PYINC}")
set(Python_SOABI        "cpython-${_nb_major}${_nb_minor}-aarch64-linux-android")
set(Python_STDLIB       "")

message(STATUS "nanobind shim: Python::Module -> 头文件 ${NB_PYINC}")
message(STATUS "nanobind shim: Python_SOABI = ${Python_SOABI}")
message(STATUS "nanobind shim: 不链接 libpython（Android 无独立 libpython）")
