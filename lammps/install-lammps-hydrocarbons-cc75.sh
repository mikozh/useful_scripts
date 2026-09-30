#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# LAMMPS + CUDA installation
#
# GPU:
#   NVIDIA T1200 Laptop GPU
#   Turing / Compute Capability 7.5 / sm_75
#
# Workloads:
#   - TraPPE-UA hydrocarbons
#   - Green-Kubo viscosity
#   - Muller-Plathe RNEMD
#   - optional OPLS-AA + PPPM
#
# RUN THIS ENTIRE SCRIPT AS ROOT:
#
#   sudo bash install-lammps-hydrocarbons.sh
###############################################################################

LAMMPS_REF="stable_22Jul2025_update6"
LAMMPS_SRC="/opt/lammps-hydrocarbons"

CUDA_VERSION="12.9"
CUDA_PACKAGE="cuda-toolkit-12-9"
CUDA_HOME="/usr/local/cuda-12.9"

GPU_ARCH="sm_75"

###############################################################################
# Require root
###############################################################################

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: Run this script as root:"
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
# Basic checks
###############################################################################

if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: This script expects x86_64."
    exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi was not found."
    echo "The NVIDIA driver/GPU must already be working."
    exit 1
fi

echo "=== NVIDIA GPU ==="
nvidia-smi
echo

if [ ! -f /etc/os-release ]; then
    echo "ERROR: /etc/os-release not found."
    exit 1
fi

. /etc/os-release

echo "Operating system:"
echo "  ${PRETTY_NAME:-unknown}"
echo

IS_WSL=0

if grep -qi microsoft /proc/version 2>/dev/null || \
   grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_WSL=1
    echo "WSL2 environment detected."
    echo "The Windows NVIDIA driver will NOT be modified."
else
    echo "Native Linux environment detected."
fi

###############################################################################
# System/build dependencies
###############################################################################

echo
echo "=== Installing build dependencies ==="

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    curl \
    wget \
    ca-certificates \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    openmpi-bin \
    libopenmpi-dev \
    libfftw3-dev \
    zlib1g-dev

echo
echo "CMake:"
cmake --version | head -1

echo
echo "MPI:"
mpicxx --version | head -1 || true

###############################################################################
# CUDA 12.9 toolkit
###############################################################################

if [ -x "$CUDA_HOME/bin/nvcc" ]; then

    echo
    echo "=== CUDA 12.9 already installed ==="
    "$CUDA_HOME/bin/nvcc" --version

else

    echo
    echo "=== Installing CUDA Toolkit ${CUDA_VERSION} ==="
    echo
    echo "This installs cuda-toolkit-12-9 only."
    echo "It does NOT intentionally install/replace the NVIDIA driver."
    echo

    if [ "$IS_WSL" -eq 1 ]; then

        CUDA_REPO="wsl-ubuntu"

    else

        case "${VERSION_ID:-}" in
            "22.04")
                CUDA_REPO="ubuntu2204"
                ;;
            "24.04")
                CUDA_REPO="ubuntu2404"
                ;;
            *)
                echo "ERROR:"
                echo "Automatic CUDA setup is configured for"
                echo "Ubuntu 22.04 and 24.04."
                echo
                echo "Detected:"
                echo "  ${PRETTY_NAME:-unknown}"
                exit 1
                ;;
        esac

    fi

    CUDA_KEYRING="/tmp/cuda-keyring.deb"

    wget -q \
        "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb" \
        -O "$CUDA_KEYRING"

    dpkg -i "$CUDA_KEYRING"
    rm -f "$CUDA_KEYRING"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "$CUDA_PACKAGE"

fi

###############################################################################
# Explicit CUDA environment
###############################################################################

export CUDA_HOME="$CUDA_HOME"
export CUDA_PATH="$CUDA_HOME"
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"

echo
echo "=== CUDA compiler ==="
"$CUDA_HOME/bin/nvcc" --version

echo
echo "CUDA_HOME=$CUDA_HOME"

###############################################################################
# Download pinned LAMMPS
###############################################################################

echo
echo "=== Downloading LAMMPS ${LAMMPS_REF} ==="

mkdir -p /opt

if [ -d "$LAMMPS_SRC/.git" ]; then

    echo "Existing LAMMPS source tree:"
    echo "  $LAMMPS_SRC"

    git -C "$LAMMPS_SRC" fetch --tags --force
    git -C "$LAMMPS_SRC" checkout --force "$LAMMPS_REF"

else

    git clone \
        --depth 1 \
        --branch "$LAMMPS_REF" \
        https://github.com/lammps/lammps.git \
        "$LAMMPS_SRC"

fi

cd "$LAMMPS_SRC"

echo
echo "LAMMPS revision:"
git log -1 --oneline

###############################################################################
# Configure LAMMPS
#
# Required for hydrocarbon viscosity project:
#
# MOLECULE
#   bonded hydrocarbons
#
# KSPACE
#   PPPM for optional OPLS-AA
#
# GPU
#   lj/cut/gpu
#   lj/cut/coul/long/gpu
#
# EXTRA-FIX
#   fix viscosity for Muller-Plathe RNEMD
#
# OPENMP
#   CPU/bonded acceleration
#
# DOWNLOAD_POTENTIALS=OFF
#   prevents unrelated external-potential downloads/timeouts
###############################################################################

echo
echo "=== Configuring LAMMPS ==="

rm -rf build

cmake \
    -S cmake \
    -B build \
    -G Ninja \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_INSTALL_PREFIX=/usr/local \
    -D BUILD_MPI=ON \
    -D BUILD_OMP=ON \
    -D FFT=FFTW3 \
    -D PKG_MOLECULE=ON \
    -D PKG_KSPACE=ON \
    -D PKG_GPU=ON \
    -D PKG_EXTRA-FIX=ON \
    -D PKG_OPENMP=ON \
    -D DOWNLOAD_POTENTIALS=OFF \
    -D GPU_API=cuda \
    -D GPU_ARCH="$GPU_ARCH" \
    -D GPU_PREC=mixed \
    -D CUDAToolkit_ROOT="$CUDA_HOME" \
    -D CUDA_TOOLKIT_ROOT_DIR="$CUDA_HOME" \
    -D CMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"

###############################################################################
# Build
###############################################################################

echo
echo "=== Building LAMMPS ==="

cmake --build build --parallel "$(nproc)"

echo
echo "=== Build result ==="

ls -lh build/lmp

###############################################################################
# Install
###############################################################################

echo
echo "=== Installing LAMMPS into /usr/local ==="

cmake --install build
ldconfig

###############################################################################
# Locate executable
###############################################################################

LMP="$(command -v lmp || true)"

if [ -z "$LMP" ]; then
    echo "ERROR: lmp was not found after installation."
    exit 1
fi

echo
echo "LAMMPS executable:"
echo "  $LMP"

###############################################################################
# Package/style verification
###############################################################################

echo
echo "============================================================"
echo " LAMMPS package/style check"
echo "============================================================"

"$LMP" -h | sed -n '/Installed packages/,/^$/p' || true

HELP_OUTPUT="$(mktemp)"
"$LMP" -h > "$HELP_OUTPUT"

check_text()
{
    local TEXT="$1"
    local DESCRIPTION="$2"

    if grep -q "$TEXT" "$HELP_OUTPUT"; then
        printf "  [OK]   %s\n" "$DESCRIPTION"
    else
        printf "  [FAIL] %s\n" "$DESCRIPTION"
        echo
        echo "LAMMPS help output did not contain:"
        echo "  $TEXT"
        rm -f "$HELP_OUTPUT"
        exit 1
    fi
}

echo
echo "Checking required hydrocarbon functionality:"

check_text "lj/cut/gpu" \
    "GPU Lennard-Jones: lj/cut/gpu"

check_text "lj/cut/coul/long/gpu" \
    "GPU OPLS electrostatics: lj/cut/coul/long/gpu"

check_text "harmonic" \
    "harmonic bonded styles"

check_text "opls" \
    "OPLS dihedral style"

check_text "pppm" \
    "KSPACE / PPPM"

check_text "ave/correlate" \
    "Green-Kubo: fix ave/correlate"

check_text "viscosity" \
    "Muller-Plathe: fix viscosity"

check_text "ave/chunk" \
    "RNEMD profile: fix ave/chunk"

rm -f "$HELP_OUTPUT"

###############################################################################
# GPU smoke test
###############################################################################

echo
echo "============================================================"
echo " NVIDIA T1200 GPU smoke test"
echo "============================================================"

TESTDIR="$(mktemp -d)"

cat > "$TESTDIR/in.gputest" <<'EOF'
units lj

lattice fcc 0.8442

region box block 0 10 0 10 0 10

create_box 1 box
create_atoms 1 box

mass 1 1.0

velocity all create 1.44 87287

pair_style lj/cut 2.5
pair_coeff 1 1 1.0 1.0 2.5

fix integrator all nve

thermo 100
thermo_style custom step temp pe ke etotal press

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
echo "=== Important GPU-test lines ==="

grep -Ei \
    'GPU|device|Loop time|Performance|NVIDIA' \
    "$TESTDIR/gpu-test.log" \
    | tail -40 || true

if ! grep -q "Loop time" "$TESTDIR/gpu-test.log"; then

    echo
    echo "ERROR: GPU smoke test did not complete."
    echo
    echo "Full log:"
    cat "$TESTDIR/gpu-test.log"

    exit 1
fi

rm -rf "$TESTDIR"

###############################################################################
# Final diagnostics
###############################################################################

echo
echo "============================================================"
echo " FINAL INSTALLATION SUMMARY"
echo "============================================================"

echo
echo "--- GPU ---"

nvidia-smi \
    --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader || true

echo
echo "--- CUDA toolkit used to build LAMMPS ---"

"$CUDA_HOME/bin/nvcc" --version

echo
echo "--- LAMMPS ---"

"$LMP" -h | head -10 || true

echo
echo "--- executable ---"

echo "$LMP"

echo
echo "--- source revision ---"

git -C "$LAMMPS_SRC" log -1 --oneline

echo
echo "--- source directory ---"

echo "$LAMMPS_SRC"

echo
echo "============================================================"
echo " SUCCESS"
echo "============================================================"

echo
echo "LAMMPS GPU installation completed successfully."
echo
echo "GPU:"
nvidia-smi --query-gpu=name --format=csv,noheader

echo
echo "CUDA target:"
echo "  $GPU_ARCH"

echo
echo "Normal GPU invocation:"
echo
echo "  lmp -sf gpu -pk gpu 1 -in input.lammps"
echo
echo "LAMMPS source:"
echo
echo "  $LAMMPS_SRC"
echo
echo "IMPORTANT:"
echo "Create the hydrocarbon project's Python .venv as your NORMAL USER,"
echo "not as root."
echo
