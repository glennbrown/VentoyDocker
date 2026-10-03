#!/usr/bin/env bash

# Container entrypoint: connect the host's NBD export and run VentoyWeb

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

NBD_PORT="${NBD_PORT:-10809}"
NBD_DEVICE="${NBD_DEVICE:-/dev/nbd0}"

cd "$(dirname "$0")/.."

# Detach NBD if the container is stopped without running cleanup.sh first
shutdown() {
    echo "Shutting down..."
    if [[ -n "${WEB_PID:-}" ]]; then
        kill "${WEB_PID}" 2>/dev/null || true
    fi
    sync
    nbd-client -d "${NBD_DEVICE}" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown TERM INT

echo "Connecting to NBD on host.docker.internal:${NBD_PORT}..."
for attempt in $(seq 1 5); do
    if ./scripts/mount.sh -p "${NBD_PORT}" -d "${NBD_DEVICE}"; then
        break
    fi
    if [[ "${attempt}" -eq 5 ]]; then
        echo "Error: Could not connect to NBD on host.docker.internal:${NBD_PORT}."
        exit 1
    fi
    sleep 2
done

NBD_NAME="${NBD_DEVICE#/dev/}"

# The container's /dev is not managed by udev, so create nodes for any
# partitions already on the disk (needed by Ventoy2Disk.sh -l and -u).
# Rereading the partition table waits for the kernel's partition scan.
blockdev --rereadpt "${NBD_DEVICE}" 2>/dev/null || true
for part in /sys/class/block/"${NBD_NAME}"p*; do
    [[ -e "${part}/dev" ]] || continue
    node="/dev/$(basename "${part}")"
    [[ -b "${node}" ]] || mknod -m 0660 "${node}" b $(tr ':' ' ' <"${part}/dev")
done

# Ventoy only lists disks whose /sys/block link points under a "/usb" path,
# which an NBD device never does. Replace /sys/block with a view that holds
# only the NBD disk, linked through a "/usb" path. This also hides the Docker
# VM's own disks from Ventoy, even with "Show All Devices" enabled.
mkdir -p /run/ventoy/usb/"${NBD_NAME}"
mount --bind /sys/devices/virtual/block/"${NBD_NAME}" /run/ventoy/usb/"${NBD_NAME}"
mount -t tmpfs tmpfs /sys/block
ln -s /run/ventoy/usb/"${NBD_NAME}" /sys/block/"${NBD_NAME}"

echo "Starting VentoyWeb..."
./VentoyWeb.sh -H 0.0.0.0 &
WEB_PID=$!
wait "${WEB_PID}"
