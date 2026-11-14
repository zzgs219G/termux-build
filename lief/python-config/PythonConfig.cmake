# PythonConfig.cmake — 伪造的 Python 包配置，供 Cross-Compiling 到 Android 用
#
# 为什么需要这个文件：
#   lief 0.17.6 的 api/python/CMakeLists.txt:35 是【无条件】调用：
#
#       find_package(Python REQUIRED COMPONENTS Interpreter Development.Module)
#
#   注意它前面没有任何 `if (NOT TARGET Python::Module)` 之类的判断
#   （nanobind 那边有，LIEF 这边没有）。所以只预建 target 不够——
#   find_package 照样会执行，照样去找 libpython，照样失败：
#
#       Could NOT find Python (missing: Python_LIBRARIES Python_INCLUDE_DIRS
#       Interpreter Development.Module)
#       （实测 run 43595003184）
#
#   而 find_package(Python) 一旦在 CMAKE_MODULE_PATH 或
#   Python_DIR 里找到 PythonConfig.cmake，就走 config 模式，
#   直接采用文件里声明的变量和 target，不再自己去找 libpython。
#
# 这个方案的正规性：
#   "config mode" 是 CMake 官方的包查找方式之一，用于包自己提供
#   <Package>Config.cmake 的场景。交叉编译时由工具链/SDK 提供目标平台的
#   Config 文件是标准做法（Android NDK 自己就提供了一堆）。
#   我们这里是在扮演"目标平台 Python SDK"的角色。
#
# 传入的变量（workflow 里 -D 指定）：
#   NB_PYINC   目标平台 Python 头文件目录（含 Python.h / pyconfig.h）
#   NB_PYEXE   host 上可执行的 python3，仅用于探测版本与 EXT_SUFFIX

if (NOT DEFINED NB_PYINC)
  message(FATAL_ERROR "PythonConfig.cmake: 需要 -DNB_PYINC=<目标平台 Python 头文件目录>")
endif()
if (NOT DEFINED NB_PYEXE)
  set(NB_PYEXE "python3")
endif()

# ── 探测版本（用 host 解释器；目标平台没有可执行的 python）──
execute_process(
  COMMAND "${NB_PYEXE}" -c "import sys;print('%d.%d'%sys.version_info[:2])"
  OUTPUT_VARIABLE _pyver
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _rc)
if (NOT _rc EQUAL 0)
  message(FATAL_ERROR "PythonConfig.cmake: 无法用 ${NB_PYEXE} 探测版本")
endif()
string(REPLACE "." ";" _vl "${_pyver}")
list(GET _vl 0 _pyMAJ)
list(GET _vl 1 _pyMIN)

# ── 探测 EXT_SUFFIX（nanobind 会用它拼产物文件名）──
execute_process(
  COMMAND "${NB_PYEXE}" -c "import sysconfig;print(sysconfig.get_config_var('EXT_SUFFIX'))"
  OUTPUT_VARIABLE _pyext
  OUTPUT_STRIP_TRAILING_WHITESPACE)

message(STATUS "PythonConfig.cmake: 目标 Python ${_pyver} (Android aarch64)")
message(STATUS "PythonConfig.cmake: 头文件 ${NB_PYINC}")
message(STATUS "PythonConfig.cmake: 不声明 Python_LIBRARIES（Android 无独立 libpython）")

# ── 声明所有 find_package(Python) 会检查的变量 ──
# REQUIRED_COMPONENTS 里的每一项都要"看起来满足"，否则 FPHSA 会报缺失。
# ── 探测完整版本号（三段式，find_package 会校验格式）──
execute_process(
  COMMAND "${NB_PYEXE}" -c "import sys;print('%d.%d.%d'%sys.version_info[:3])"
  OUTPUT_VARIABLE _pyfull
  OUTPUT_STRIP_TRAILING_WHITESPACE)
if (_pyfull STREQUAL "")
  set(_pyfull "${_pyver}.0")
endif()

set(Python_FOUND              TRUE)
set(Python_VERSION            "${_pyfull}")
set(Python_VERSION_MAJOR      "${_pyMAJ}")
set(Python_VERSION_MINOR      "${_pyMIN}")
set(Python_VERSION_PATCH      0)
set(Python_VERSION_TWEAK      0)
set(Python_VERSION_COUNT      3)
set(Python_INTERPRETER_ID     "Python")
set(Python_EXECUTABLE         "${NB_PYEXE}")
set(Python_INCLUDE_DIRS       "${NB_PYINC}")
set(Python_INCLUDE_DIR        "${NB_PYINC}")
set(Python_Development_FOUND  TRUE)
set(Python_Development.Module_FOUND TRUE)
set(Python_Interpreter_FOUND  TRUE)
# 关键：显式声明"没有库需要链接"。这是 Android 交叉编译的实际情况
# ——Python 符号在宿主可执行文件里，扩展模块不链接 libpython。
# 设为空字符串而不是 unset，是为了让 FPHSA 认为"组件已找到"
# （它检查的是变量是否被定义，不是是否非空）。
set(Python_LIBRARIES          "")
set(Python_LIBRARY            "")

set(Python_SOABI              "cpython-${_pyMAJ}${_pyMIN}-aarch64-linux-android")
set(Python_SOSABI             "")
set(Python_STDLIB             "")

# Python3_* 镜像（FindPython3 模块用另一套前缀）
foreach (_v VERSION VERSION_MAJOR VERSION_MINOR VERSION_PATCH VERSION_COUNT
             EXECUTABLE INCLUDE_DIRS INCLUDE_DIR LIBRARIES LIBRARY
             SOABI SOSABI STDLIB INTERPRETER_ID)
  if (DEFINED Python_${_v})
    set(Python3_${_v} "${Python_${_v}}")
  endif()
endforeach()
set(Python3_FOUND TRUE)
set(Python3_Development_FOUND TRUE)
set(Python3_Development.Module_FOUND TRUE)
set(Python3_Interpreter_FOUND TRUE)

# ── 建立 target ──
# Development.Module 对应的 target 是 Python::Module。
# 刻意做成 INTERFACE IMPORTED 且【不设 IMPORTED_LOCATION】：
# 一旦设了，链接阶段会把它加进 link line 去找 -lpython3.x，而 Android 没有。
if (NOT TARGET Python::Module)
  add_library(Python::Module INTERFACE IMPORTED)
  set_target_properties(Python::Module PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${NB_PYINC}")
endif()

if (NOT TARGET Python::Interpreter)
  add_executable(Python::Interpreter IMPORTED)
  set_target_properties(Python::Interpreter PROPERTIES
    IMPORTED_LOCATION "${NB_PYEXE}")
endif()

if (NOT TARGET Python3::Module)
  add_library(Python3::Module INTERFACE IMPORTED)
  set_target_properties(Python3::Module PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${NB_PYINC}")
endif()
if (NOT TARGET Python3::Interpreter)
  add_executable(Python3::Interpreter IMPORTED)
  set_target_properties(Python3::Interpreter PROPERTIES
    IMPORTED_LOCATION "${NB_PYEXE}")
endif()
