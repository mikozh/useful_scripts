# Install KMS server as desribed here https://winitpro.ru/index.php/2021/10/28/kms-server-vlmcsd-na-linux-dlya-aktivacii-windows-office/
#
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

WORKDIR="/root/vlmcsd-src"
REPO_URL="https://github.com/Wind4/vlmcsd"
LOG_DIR="/var/log/vlmcsd"
LOG_FILE="${LOG_DIR}/vlmcsd.log"
SERVICE_NAME="vlmcsd.service"
SERVICE_DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
SERVICE_DROPIN_FILE="${SERVICE_DROPIN_DIR}/override.conf"
CONFIG_FILE="/etc/vlmcsd/vlmcsd.ini"

echo "[1/8] Installing build dependencies..."
apt update
apt install -y git build-essential debhelper fakeroot dpkg-dev

echo "[2/8] Preparing source directory..."
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "[3/8] Cloning vlmcsd sources..."
git clone "${REPO_URL}" vlmcsd
cd vlmcsd
git submodule update --init debian

echo "[4/8] Building Debian package..."
dpkg-buildpackage -rfakeroot -D -us -uc

echo "[5/8] Installing built package..."
cd "${WORKDIR}"
DEB_PKG="$(find . -maxdepth 1 -type f -name 'vlmcsd_*_amd64.deb' | head -n 1 || true)"

if [[ -z "${DEB_PKG}" ]]; then
  echo "ERROR: built package not found"
  exit 1
fi

dpkg -i "${DEB_PKG}"

echo "[6/8] Configuring logs and service account..."
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

if ! id -u vlmcsd >/dev/null 2>&1; then
  useradd -s /usr/sbin/nologin -r -M vlmcsd
fi

chown -R vlmcsd:vlmcsd "${LOG_DIR}"
chmod 755 "${LOG_DIR}"
chmod 640 "${LOG_FILE}"

if [[ -f "${CONFIG_FILE}" ]]; then
  if grep -qE '^[#[:space:]]*LogFile[[:space:]]*=' "${CONFIG_FILE}"; then
    sed -i "s|^[#[:space:]]*LogFile[[:space:]]*=.*|LogFile = ${LOG_FILE}|" "${CONFIG_FILE}"
  else
    printf "\nLogFile = %s\n" "${LOG_FILE}" >> "${CONFIG_FILE}"
  fi
else
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    printf "LogFile = %s\n" "${LOG_FILE}" > "${CONFIG_FILE}"
fi

echo "[7/8] Creating systemd override..."
mkdir -p "${SERVICE_DROPIN_DIR}"
cat > "${SERVICE_DROPIN_FILE}" <<EOF
[Service]
User=vlmcsd
Group=vlmcsd
EOF

echo "[8/8] Restarting service..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo
echo "=== STATUS ==="
systemctl --no-pager --full status "${SERVICE_NAME}" || true

echo
echo "=== PROCESS ==="
ps aux | grep '[v]lmcsd' || true

echo
echo "=== PORT 1688 ==="
ss -lnptu | grep ':1688' || true

echo
echo "=== LOG TAIL ==="
tail -n 50 "${LOG_FILE}" || true

echo
echo "Done."
