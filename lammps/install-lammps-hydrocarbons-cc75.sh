#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# LAMMPS + CUDA installer
#
# Target:
#   NVIDIA T1200 Laptop GPU
#   Turing / Compute Capability 7.5 / sm_75
#
# OS:
#   Ubuntu 26.04 / 24.04 / 22.04
#   Native Linux or WSL2
#
# CUDA:
#   CUDA Toolkit 13.4
#
# LAMMPS:
#   patch_2Sep2026
#
# Enabled packages:
#   GPU
#   MOLECULE
#   KSPACE
#   EXTRA-FIX
#   OPENMP
#
# Intended workloads:
#   TraPPE-UA hydrocarbons
#   Green-Kubo viscosity
#   Muller-Plathe RNEMD
#   optional OPLS-AA + PPPM
#
# Run as:
#
#   sudo bash install-lammps-hydrocarbons-cc75.sh
#
###############################################################################

LAMMPS_REF="patch_2Sep2026"
LAMMPS_SRC="/opt/lammps-hydrocarbons"

CUDA_VERSION="13.4"
CUDA_PACKAGE="cuda-toolkit-13-4"
CUDA_HOME="/usr/local/cuda-13.4"

GPU_ARCH="sm_75"

###############################################################################
# Error handler
###############################################################################

trap 'echo; echo "ERROR: installation failed at line $LINENO"; exit 1' ERR

###############################################################################
# Must run as root
###############################################################################

if [ "${EUID}" -ne 0 ]; then
    echo
    echo "ERROR: run this script as root:"
    echo
    echo "  sudo bash $0"
    echo
    exit 1
fi

echo
echo "============================================================"
echo " LAMMPS hydrocarbon MD installation"
echo "============================================================"
echo

###############################################################################
# Detect operating system
###############################################################################

if [ ! -f /etc/os-release ]; then
    echo "ERROR: /etc/os-release not found."
    exit 1
fi

. /etc/os-release

echo "Operating system:"
echo "  ${PRETTY_NAME:-unknown}"
echo

if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: this script expects x86_64."
    exit 1
fi

case "${VERSION_ID:-}" in
    "26.04")
        CUDA_REPO="ubuntu2604"
        ;;
    "24.04")
        CUDA_REPO="ubuntu2404"
        ;;
    "22.04")
        CUDA_REPO="ubuntu2204"
        ;;
    *)
        echo "ERROR: unsupported Ubuntu release:"
        echo "  ${PRETTY_NAME:-unknown}"
        echo
        echo "Supported by this installer:"
        echo "  Ubuntu 22.04"
        echo "  Ubuntu 24.04"
        echo "  Ubuntu 26.04"
        exit 1
        ;;
esac

###############################################################################
# Detect WSL
###############################################################################

IS_WSL=0

if grep -qi microsoft /proc/version 2>/dev/null || \
   grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_WSL=1
fi

if [ "$IS_WSL" -eq 1 ]; then

    echo "Environment:"
    echo "  WSL2 detected"
    echo

    # NVIDIA utilities supplied by Windows driver.
    export PATH="/usr/lib/wsl/lib:$PATH"

    NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"

    if [ -d /usr/lib/wsl/lib ]; then
        export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"
        export LIBRARY_PATH="/usr/lib/wsl/lib:${LIBRARY_PATH:-}"
    fi

else

    echo "Environment:"
    echo "  Native Linux"
    echo

    NVIDIA_SMI="$(command -v nvidia-smi || true)"

fi

###############################################################################
# NVIDIA GPU check
###############################################################################

if [ -z "${NVIDIA_SMI:-}" ] || [ ! -x "$NVIDIA_SMI" ]; then
    echo "ERROR: nvidia-smi was not found."
    exit 1
fi

echo "=== NVIDIA GPU ==="
"$NVIDIA_SMI"
echo

echo "GPU summary:"
"$NVIDIA_SMI" \
    --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader

echo

###############################################################################
# System dependencies
###############################################################################

echo "============================================================"
echo " Installing build dependencies"
echo "============================================================"
echo

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    gcc \
    g++ \
    cmake \
    ninja-build \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    pkg-config \
    gzip \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    openmpi-bin \
    libopenmpi-dev \
    libfftw3-dev \
    zlib1g-dev

echo
echo "=== Host compiler ==="
gcc --version | head -1
g++ --version | head -1

echo
echo "=== CMake ==="
cmake --version | head -1

echo
echo "=== MPI ==="
mpicxx --version | head -1 || true

###############################################################################
# CUDA 13.4 repository
#
# IMPORTANT:
# We install cuda-toolkit-13-4, NOT "cuda" and NOT any NVIDIA Linux driver.
# On WSL the actual GPU driver comes from Windows.
###############################################################################

echo
echo "============================================================"
echo " Installing CUDA Toolkit ${CUDA_VERSION}"
echo "============================================================"
echo

if [ -x "$CUDA_HOME/bin/nvcc" ]; then

    echo "CUDA ${CUDA_VERSION} is already installed:"
    "$CUDA_HOME/bin/nvcc" --version

else

    echo "Adding NVIDIA CUDA repository:"
    echo "  ${CUDA_REPO}"
    echo

    KEYRING="/tmp/cuda-keyring-${CUDA_REPO}.deb"

    wget -O "$KEYRING" \
        "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb"

    dpkg -i "$KEYRING"

    rm -f "$KEYRING"

    apt-get update

    echo
    echo "Installing:"
    echo "  $CUDA_PACKAGE"
    echo

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "$CUDA_PACKAGE"

fi

###############################################################################
# CUDA environment
###############################################################################

if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
    echo "ERROR: nvcc not found:"
    echo "  $CUDA_HOME/bin/nvcc"
    exit 1
fi

export CUDA_HOME="$CUDA_HOME"
export CUDA_PATH="$CUDA_HOME"

export PATH="$CUDA_HOME/bin:$PATH"

export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$CUDA_HOME/lib64:${LIBRARY_PATH:-}"

# Explicit host compiler for NVCC.
export CUDAHOSTCXX="/usr/bin/g++"

echo
echo "=== CUDA compiler ==="
"$CUDA_HOME/bin/nvcc" --version

echo
echo "CUDA_HOME:"
echo "  $CUDA_HOME"

###############################################################################
# Check that we are really using CUDA 13.4
###############################################################################

NVCC_RELEASE="$("$CUDA_HOME/bin/nvcc" --version | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' | head -1)"

echo
echo "Detected CUDA toolkit version:"
echo "  $NVCC_RELEASE"

case "$NVCC_RELEASE" in
    13.4*)
        ;;
    *)
        echo "ERROR: expected CUDA 13.4 but nvcc reports:"
        echo "  $NVCC_RELEASE"
        exit 1
        ;;
esac

###############################################################################
# Clean previous failed LAMMPS build
###############################################################################

echo
echo "============================================================"
echo " Preparing LAMMPS source"
echo "============================================================"
echo

if [ -e "$LAMMPS_SRC" ]; then
    echo "Removing previous source/build tree:"
    echo "  $LAMMPS_SRC"
    rm -rf "$LAMMPS_SRC"
fi

###############################################################################
# Clone pinned LAMMPS version
###############################################################################

echo
echo "Cloning LAMMPS:"
echo "  $LAMMPS_REF"
echo

git clone \
    --depth 1 \
    --branch "$LAMMPS_REF" \
    https://github.com/lammps/lammps.git \
    "$LAMMPS_SRC"

cd "$LAMMPS_SRC"

echo
echo "LAMMPS revision:"
git log -1 --oneline

###############################################################################
# Configure
#
# CUDA_ENABLE_MULTIARCH=OFF is important here:
# compile only for the T1200's sm_75 architecture instead of wasting time
# generating kernels for many CUDA GPU generations.
###############################################################################

echo
echo "============================================================"
echo " Configuring LAMMPS"
echo "============================================================"
echo

rm -rf build

CMAKE_EXTRA=()

if [ "$IS_WSL" -eq 1 ]; then
    CMAKE_EXTRA+=(
        "-DCMAKE_LIBRARY_PATH=/usr/lib/wsl/lib"
    )
fi

cmake \
    -S cmake \
    -B build \
    -G Ninja \
    \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_INSTALL_PREFIX=/usr/local \
    \
    -D CMAKE_C_COMPILER=/usr/bin/gcc \
    -D CMAKE_CXX_COMPILER=/usr/bin/g++ \
    \
    -D BUILD_MPI=ON \
    -D BUILD_OMP=ON \
    \
    -D FFT=FFTW3 \
    \
    -D PKG_MOLECULE=ON \
    -D PKG_KSPACE=ON \
    -D PKG_GPU=ON \
    -D PKG_EXTRA-FIX=ON \
    -D PKG_OPENMP=ON \
    \
    -D DOWNLOAD_POTENTIALS=OFF \
    \
    -D GPU_API=cuda \
    -D GPU_ARCH="$GPU_ARCH" \
    -D GPU_PREC=mixed \
    \
    -D CUDA_ENABLE_MULTIARCH=OFF \
    -D CUDA_BUILD_MULTIARCH=OFF \
    \
    -D CUDPP_OPT=OFF \
    \
    -D CUDAToolkit_ROOT="$CUDA_HOME" \
    -D CUDA_TOOLKIT_ROOT_DIR="$CUDA_HOME" \
    -D CMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
    -D CUDA_HOST_COMPILER=/usr/bin/g++ \
    \
    "${CMAKE_EXTRA[@]}"

###############################################################################
# Show selected CUDA configuration before compiling
###############################################################################

echo
echo "=== Relevant CMake configuration ==="

grep -E \
    'CUDA|GPU_ARCH|GPU_API|GPU_PREC|PKG_GPU|PKG_KSPACE|PKG_MOLECULE|PKG_EXTRA-FIX' \
    build/CMakeCache.txt \
    | sort \
    || true

###############################################################################
# Compile
#
# Cap parallelism at 8 by default so that a WSL laptop does not run out of RAM.
# Override if desired:
#
#   LAMMPS_BUILD_JOBS=16 sudo -E bash script.sh
###############################################################################

CPU_COUNT="$(nproc)"

if [ -n "${LAMMPS_BUILD_JOBS:-}" ]; then
    BUILD_JOBS="$LAMMPS_BUILD_JOBS"
else
    BUILD_JOBS="$CPU_COUNT"

    if [ "$BUILD_JOBS" -gt 8 ]; then
        BUILD_JOBS=8
    fi
fi

echo
echo "============================================================"
echo " Building LAMMPS"
echo "============================================================"
echo
echo "CPU cores detected : $CPU_COUNT"
echo "Build jobs         : $BUILD_JOBS"
echo

cmake --build build --parallel "$BUILD_JOBS"

###############################################################################
# Check executable before install
###############################################################################

if [ ! -x build/lmp ]; then
    echo "ERROR: LAMMPS executable was not produced:"
    echo "  $LAMMPS_SRC/build/lmp"
    exit 1
fi

echo
echo "Built executable:"
ls -lh build/lmp

###############################################################################
# Install system-wide
###############################################################################

echo
echo "============================================================"
echo " Installing LAMMPS"
echo "============================================================"
echo

cmake --install build
ldconfig

LMP="$(command -v lmp || true)"

if [ -z "$LMP" ] || [ ! -x "$LMP" ]; then
    echo "ERROR: lmp was not installed into PATH."
    exit 1
fi

echo "LAMMPS executable:"
echo "  $LMP"

###############################################################################
# Verify packages and required styles
###############################################################################

echo
echo "============================================================"
echo " Checking LAMMPS functionality"
echo "============================================================"
echo

HELP_FILE="$(mktemp)"

"$LMP" -h > "$HELP_FILE"

echo "Installed packages:"
sed -n '/Installed packages/,/^$/p' "$HELP_FILE" || true

check_required()
{
    local PATTERN="$1"
    local DESCRIPTION="$2"

    if grep -Eqi "$PATTERN" "$HELP_FILE"; then
        printf "  [OK]   %s\n" "$DESCRIPTION"
    else
        printf "  [FAIL] %s\n" "$DESCRIPTION"
        echo
        echo "Missing pattern:"
        echo "  $PATTERN"
        echo
        rm -f "$HELP_FILE"
        exit 1
    fi
}

echo
echo "Required hydrocarbon / viscosity functionality:"

check_required 'lj/cut/gpu' \
    'CUDA Lennard-Jones pair style'

check_required 'lj/cut/coul/long/gpu' \
    'CUDA LJ + long-range Coulomb pair style'

check_required 'pppm' \
    'PPPM / KSPACE'

check_required 'harmonic' \
    'harmonic bonded styles'

check_required 'opls' \
    'OPLS dihedral support'

check_required 'ave/correlate' \
    'Green-Kubo fix ave/correlate'

check_required 'ave/time' \
    'fix ave/time'

check_required 'ave/chunk' \
    'RNEMD velocity-profile sampling'

check_required 'viscosity' \
    'Muller-Plathe fix viscosity'

rm -f "$HELP_FILE"

###############################################################################
# CUDA / LAMMPS GPU smoke test
###############################################################################

echo
echo "============================================================"
echo " Running CUDA GPU smoke test"
echo "============================================================"
echo

TESTDIR="$(mktemp -d)"

cat > "$TESTDIR/in.gputest" <<'EOF'
units lj

atom_style atomic

lattice fcc 0.8442

region box block 0 10 0 10 0 10

create_box 1 box
create_atoms 1 box

mass 1 1.0

velocity all create 1.44 87287 mom yes rot yes dist gaussian

pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0 2.5

neighbor 0.3 bin
neigh_modify delay 0 every 1 check yes

fix integrator all nve

thermo 100
thermo_style custom step atoms temp pe ke etotal press

run 1000
EOF

(
    cd "$TESTDIR"

    "$LMP" \
        -sf gpu \
        -pk gpu 1 \
        -in in.gputest \
        2>&1 | tee gpu-test.log
)

echo
echo "=== GPU smoke-test summary ==="

grep -Ei \
    'GPU|NVIDIA|device|Loop time|Performance|ns/day|timesteps/s' \
    "$TESTDIR/gpu-test.log" \
    | tail -60 \
    || true

if ! grep -q "Loop time" "$TESTDIR/gpu-test.log"; then

    echo
    echo "ERROR: GPU test did not finish successfully."
    echo
    echo "Full GPU test log:"
    cat "$TESTDIR/gpu-test.log"

    exit 1
fi

if grep -Eqi \
    'ERROR|CUDA error|device kernel image is invalid|no kernel image' \
    "$TESTDIR/gpu-test.log"; then

    echo
    echo "ERROR: CUDA/LAMMPS GPU error detected."
    echo
    cat "$TESTDIR/gpu-test.log"

    exit 1
fi

rm -rf "$TESTDIR"

###############################################################################
# Python prerequisites
#
# Do NOT pip-install moltemplate/numpy/etc globally.
#
# Your experiment brief requires a .venv inside the actual simulation
# repository. We install all OS prerequisites here and print the exact
# project-local setup commands at the end.
###############################################################################

echo
echo "============================================================"
echo " Final verification"
echo "============================================================"
echo

echo "--- OS ---"
echo "${PRETTY_NAME:-unknown}"

echo
echo "--- WSL ---"
if [ "$IS_WSL" -eq 1 ]; then
    echo "yes"
else
    echo "no"
fi

echo
echo "--- GPU ---"
"$NVIDIA_SMI" \
    --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader

echo
echo "--- CUDA toolkit ---"
"$CUDA_HOME/bin/nvcc" --version

echo
echo "--- GCC ---"
gcc --version | head -1

echo
echo "--- LAMMPS executable ---"
echo "$LMP"

echo
echo "--- LAMMPS revision ---"
git -C "$LAMMPS_SRC" log -1 --oneline

echo
echo "--- LAMMPS version ---"
"$LMP" -h | head -10

echo
echo "============================================================"
echo " SUCCESS"
echo "============================================================"
echo
echo "LAMMPS CUDA installation completed successfully."
echo
echo "Configuration:"
echo
echo "  GPU          : NVIDIA T1200 Laptop GPU"
echo "  architecture : sm_75"
echo "  CUDA         : 13.4"
echo "  LAMMPS       : ${LAMMPS_REF}"
echo "  source       : ${LAMMPS_SRC}"
echo "  executable   : ${LMP}"
echo
echo "Normal GPU invocation:"
echo
echo "  lmp -sf gpu -pk gpu 1 -in input.lammps"
echo
echo
echo "For the hydrocarbon project, switch back to your NORMAL user,"
echo "cd into the project repository and create the required local venv:"
echo
echo "  python3 -m venv .venv"
echo "  . .venv/bin/activate"
echo "  python -m pip install --upgrade pip"
echo "  python -m pip install numpy pandas matplotlib moltemplate pytest"
echo
echo "Then verify:"
echo
echo "  python -c \"import moltemplate, numpy, pandas, matplotlib; print('ok')\""
echo "  which moltemplate.sh"
echo "  find .venv -name trappe1998.lt"
echo "  find .venv -name oplsaa.lt"
echo
