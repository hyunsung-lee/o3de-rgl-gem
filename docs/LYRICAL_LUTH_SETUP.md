# Running RGL on ROS 2 Lyrical Luth

Upstream RGL (RobotecGPULidar) only ships prebuilt binaries for Humble and
Jazzy. Kilted Kaiju can reuse the Jazzy binary because its `rclcpp` is
ABI-compatible. **Lyrical Luth cannot** — a handful of `rclcpp` functions
(`shutdown`, `ok`, `PublisherBase::setup_intra_process`,
`IntraProcessManager::add_publisher`) changed to take `shared_ptr` args by
`const&` instead of by value, which is a binary-incompatible change. Loading
the Jazzy binary against Lyrical fails with `undefined symbol` errors for
those four mangled names.

The fix has two parts, both already done in these forks:

- [hyunsung-lee/o3de-rgl-gem](https://github.com/hyunsung-lee/o3de-rgl-gem)
  branch `lyrical-support` — adds a `RGL_USE_LOCAL_BUILD` path to
  `Code/FindRGL.cmake` so, for `ROS_DISTRO=lyrical`, the gem copies a locally
  built RGL instead of downloading a prebuilt zip.
- [hyunsung-lee/RobotecGPULidar](https://github.com/hyunsung-lee/RobotecGPULidar)
  branch `lyrical-support-v0.21.0` — patches RGL itself to build against
  Lyrical's `rclcpp` and against OptiX 9.1 (see "Why OptiX 9.1" below).

## One-time host setup

These are host-level dependencies, not part of either repo, so they have to
be redone on any new machine.

### 1. CUDA Toolkit

Ubuntu 26.04 ships CUDA in its own repos — no NVIDIA apt repo needed:

```
sudo apt install -y cuda-toolkit
export PATH=/usr/local/cuda/bin:$PATH   # add to your shell profile
```

### 2. Patch a CUDA/glibc header conflict

Ubuntu 26.04's glibc declares `rsqrt`/`rsqrtf` as `noexcept`, which conflicts
with CUDA 13.1's own (non-`noexcept`) declarations in `crt/math_functions.h`,
causing every `nvcc` invocation to fail with:

```
error: exception specification is incompatible with that of previous function "rsqrt"
```

Fix (safe — `rsqrt`/`rsqrtf` never throw):

```bash
MATH_H=/usr/local/cuda/targets/x86_64-linux/include/crt/math_functions.h
sudo cp "$MATH_H" "${MATH_H}.orig"   # back up first
sudo sed -i \
  -e 's/double                 rsqrt(double x);/double                 rsqrt(double x) noexcept(true);/' \
  -e 's/float                  rsqrtf(float x);/float                  rsqrtf(float x) noexcept(true);/' \
  "$MATH_H"
```

If this ever gets fixed upstream in a newer CUDA point release, this step
can be dropped — try building without it first.

### 3. OptiX SDK

RGL's documented requirement is OptiX 7.2, but that's stale — the actual
constraint (`setup.py`) is just that `OptiX_INSTALL_DIR` is set. This has to
be downloaded manually; NVIDIA gates it behind a developer-account login and
click-through EULA, so there's no way to script this step:

1. https://developer.nvidia.com/designworks/optix/download (log in / create
   a free NVIDIA Developer account).
2. Download the latest Linux x86_64 `.sh` installer.
3. Extract it:
   ```bash
   sudo mkdir -p /opt/optix && sudo chown "$USER" /opt/optix
   bash NVIDIA-OptiX-SDK-*.sh --skip-license --prefix=/opt/optix
   export OptiX_INSTALL_DIR=/opt/optix   # add to your shell profile
   ```

**Why OptiX 9.1, not 7.2:** the RTX 50-series (Blackwell) is new enough that
7.2-era SDKs may not be the best match, and the *actual* API surface RGL's
source uses (`optixModuleCreateFromPTX`, an `OptixPipelineLinkOptions`
struct with a `debugLevel` member) changed in OptiX 8+. The
`lyrical-support-v0.21.0` branch already ports around this
(`optixModuleCreate` + dropping `debugLevel`). If NVIDIA ships a version
that changes the API further, that's the file to check:
`src/Optix.cpp`, around `initializeStaticOptixStructures()`.

## Build RGL from the fork

```bash
git clone --branch lyrical-support-v0.21.0 \
  https://github.com/hyunsung-lee/RobotecGPULidar.git
cd RobotecGPULidar

source /opt/ros/lyrical/setup.bash   # ROS2 env must be sourced first
export PATH=/usr/local/cuda/bin:$PATH
export OptiX_INSTALL_DIR=/opt/optix

./setup.py --install-deps
./setup.py --install-ros2-deps       # builds radar_msgs from source via colcon
./setup.py --with-ros2 --cmake="-DRGL_BUILD_TESTS=OFF"
```

(`-DRGL_BUILD_TESTS=OFF` sidesteps an unrelated GoogleTest/CMake
incompatibility with very new GCC versions — CMake's compile-features table
for GCC doesn't yet recognize GCC 15.2 on Ubuntu 26.04.)

Verify it's ABI-clean before moving on:

```bash
LD_BIND_NOW=1 ldd -r build/lib/libRobotecGPULidar.so | grep -i "symbol\|undefined"
# no output = clean
```

## Wire it into the gem

Copy the build output into the path `Code/FindRGL.cmake` expects
(gitignored, so this is a per-machine step even when using the fork):

```bash
GEM_DIR=<path to your o3de-rgl-gem checkout>
DEST=$GEM_DIR/Code/3rdParty/rgl-lyrical-local-build
mkdir -p "$DEST/lib" "$DEST/include/rgl/api/extensions"
cp build/lib/libRobotecGPULidar.so                              "$DEST/lib/"
cp include/rgl/api/core.h                                        "$DEST/include/rgl/api/"
cp extensions/ros2/include/rgl/api/extensions/ros2.h             "$DEST/include/rgl/api/extensions/"
```

Then use the `lyrical-support` branch of the gem fork:

```bash
cd $GEM_DIR
git remote add fork https://github.com/hyunsung-lee/o3de-rgl-gem.git   # if not already added
git fetch fork
git checkout lyrical-support
```

If your O3DE project's build directory already has a cached (broken) RGL
download from a previous configure, clear it before reconfiguring —
otherwise the unchanged version+distro metadata will skip the re-fetch:

```bash
GEM_BUILD_DIR=<project>/build/linux/External/o3de-rgl-gem-*/Code
rm -f "$GEM_BUILD_DIR"/{RGL_VERSION,ROS_DISTRO,RGL_DOWNLOAD_IN_PROGRESS}
rm -rf "$GEM_BUILD_DIR/3rdParty/RobotecGPULidar"
```

Then reconfigure and rebuild as usual. You should see:

```
Using locally built RGL from .../Code/3rdParty/rgl-lyrical-local-build for ROS lyrical...
```

and `libRGL.Editor.so` should load cleanly in the O3DE Editor log (no
`undefined symbol` / `cannot open shared object file` errors).

## If RGL_VERSION moves past 0.21.0

`Code/FindRGL.cmake`'s `RGL_VERSION` will get bumped upstream eventually.
When that happens, re-derive `lyrical-support-v0.21.0`'s patches against the
new tag (`git checkout v<new-version>`, re-apply the same three-file diff)
and rebuild — the patches are small and unlikely to bitrot, but they're not
guaranteed to apply cleanly forever.
