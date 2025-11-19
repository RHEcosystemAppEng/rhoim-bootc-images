# vLLM Build Dependencies for UBI 9

## System Dependencies (from dnf/yum)

### Required Build Tools:
- `gcc` - C compiler
- `gcc-c++` - C++ compiler  
- `make` - Build automation tool
- `cmake` - Cross-platform build system (>=3.26.1)
- `ninja-build` - Fast build system
- `git` - Version control (or use curl for tarball download)

### Python Development:
- `python3.11` or `python3.9` - Python interpreter
- `python3.11-pip` or `python3-pip` - Python package manager
- `python3.11-devel` or `python3-devel` - Python development headers

### Optional but Recommended:
- `numactl` - NUMA runtime library (if available)
- `numactl-devel` - NUMA development headers (if available)

**Note:** NUMA libraries may not be available in UBI repositories. vLLM can be built without NUMA support using `-DVLLM_NUMA_DISABLED`.

## Python Dependencies (from pip)

### Build Requirements (requirements/build.txt):
- `cmake>=3.26.1`
- `ninja`
- `packaging>=24.2`
- `setuptools>=77.0.3,<80.0.0`
- `setuptools-scm>=8`
- `torch==2.8.0`
- `wheel`
- `jinja2>=3.1.6`
- `regex`
- `build`

### CPU Requirements (requirements/cpu.txt):
- `numba==0.60.0` (Python 3.9) or `numba==0.61.2` (Python >3.9)
- `torch==2.8.0` (CPU version for aarch64)
- `torchaudio` (for image processors)
- `torchvision` (for image processors)
- `py-cpuinfo` (for aarch64 - CPU info gathering)
- `datasets` (for benchmark scripts)

### Runtime Dependencies:
- `transformers` - HuggingFace transformers library
- `sentencepiece` - SentencePiece tokenizer
- `fastapi` - Web framework for API server
- `uvicorn[standard]` - ASGI server

## Build Environment Variables

### Required:
- `VLLM_TARGET_DEVICE=cpu` - Build for CPU target
- `SETUPTOOLS_SCM_PRETEND_VERSION=0.11.0` - Version for tarball builds (no git metadata)

### Optional:
- `CC=/usr/bin/gcc` - C compiler path
- `CXX=/usr/bin/g++` - C++ compiler path
- `CXXFLAGS="-Wno-error -Wno-psabi -DVLLM_NUMA_DISABLED"` - Compiler flags
  - `-Wno-error` - Don't treat warnings as errors
  - `-Wno-psabi` - Suppress ABI warnings
  - `-DVLLM_NUMA_DISABLED` - Disable NUMA support

## Known Issues and Solutions

### Issue: NUMA library linking error
**Error:** `/usr/bin/ld: cannot find -lnuma`

**Solution:** 
1. Try installing `numactl` and `numactl-devel` packages
2. If not available, patch CMakeLists.txt to remove `-lnuma` from linker flags
3. Use `-DVLLM_NUMA_DISABLED` compiler flag

### Issue: Python development headers missing
**Error:** `Could NOT find Python (missing: Python_INCLUDE_DIRS)`

**Solution:** Install `python3.11-devel` or `python3-devel` package

### Issue: C++17/C++14 compatibility warnings
**Error:** Parameter passing warnings treated as errors

**Solution:** Add `-Wno-error -Wno-psabi` to CXXFLAGS

## Build Command Summary

```bash
# Install system dependencies
dnf -y install gcc gcc-c++ make cmake ninja-build git python3.11 python3.11-pip python3.11-devel

# Install Python build dependencies
pip install -r requirements/build.txt
pip install -r requirements/cpu.txt --extra-index-url https://download.pytorch.org/whl/cpu

# Build vLLM
CC=/usr/bin/gcc \
CXX=/usr/bin/g++ \
CXXFLAGS="-Wno-error -Wno-psabi -DVLLM_NUMA_DISABLED" \
VLLM_TARGET_DEVICE=cpu \
SETUPTOOLS_SCM_PRETEND_VERSION=0.11.0 \
pip install --no-cache-dir .
```

