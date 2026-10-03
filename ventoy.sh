#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/.run"
PID_FILE="${RUN_DIR}/qemu-nbd.pid"
STATE_FILE="${RUN_DIR}/state"
IMAGE="ventoy-docker:latest"
CONTAINER="ventoy-docker"

# Function to display usage information
usage() {
    cat <<EOF

🚀 ventoy.sh - Run Ventoy against a USB drive on macOS using Docker

Usage:
  $0 start -d <device> [-p <web-port>] [-n <nbd-port>]
  $0 stop

Commands:
  start        Export the USB drive with qemu-nbd, build the image if a newer
               Ventoy release is available, and start the container with
               nbd-client and VentoyWeb running.
  stop         Cleanly detach NBD inside the container, stop the container
               and stop qemu-nbd.

Options (start):
  -d DEVICE    Whole USB disk to use (e.g., /dev/disk5)          [REQUIRED]
  -p PORT      Host port for VentoyWeb (default: 24680)          [OPTIONAL]
  -n PORT      TCP port for qemu-nbd (default: 10809)            [OPTIONAL]

Example:
  $0 start -d /dev/disk5
  $0 stop

Notes:
  • Run as your normal user. sudo is used only for diskutil and qemu-nbd.
  • The device is unmounted before qemu-nbd starts.

EOF
    exit 1
}

# Detect OS
check_os() {
    case "$(uname -s)" in
    Darwin) ;;
    Linux)
        echo "You can use Ventoy natively on Linux. Refer to:"
        echo "  https://www.ventoy.net/en/doc_start.html"
        exit 0
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
    esac
}

check_dependencies() {
    if ! command -v qemu-nbd &>/dev/null; then
        echo "Error: qemu-nbd not found."
        echo "Install it with: brew install qemu"
        exit 1
    fi
    if ! command -v docker &>/dev/null; then
        echo "Error: Docker not found."
        echo "Install Docker: https://www.docker.com/get-started"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        echo "Error: Docker is not running. Start Docker Desktop and try again."
        exit 1
    fi
}

# The pid file is written by qemu-nbd as root, so fall back to sudo to read it
read_pid() {
    [[ -f "${PID_FILE}" ]] || return 1
    cat "${PID_FILE}" 2>/dev/null || sudo cat "${PID_FILE}"
}

qemu_nbd_running() {
    local pid
    pid="$(read_pid)" || return 1
    ps -p "${pid}" &>/dev/null
}

container_exists() {
    docker container inspect "${CONTAINER}" &>/dev/null
}

container_running() {
    [[ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == "true" ]]
}

validate_device() {
    local device="$1"

    if [[ ! "${device}" =~ ^/dev/disk[0-9]+$ ]]; then
        echo "Error: ${device} is not a whole disk. Use a path like /dev/disk5, not /dev/disk5s1."
        exit 1
    fi
    if [[ ! -b "${device}" ]]; then
        echo "Error: Device ${device} does not exist or is not a block device."
        exit 1
    fi
    # Guard against exporting the Mac's own disks
    if ! diskutil info "${device}" | grep -Eq "Device Location: +External"; then
        if [[ "${VENTOY_ALLOW_INTERNAL:-0}" != "1" ]]; then
            echo "Error: ${device} is not an external disk. Refusing to continue."
            echo "Check the device with: diskutil list"
            exit 1
        fi
        echo "Warning: ${device} is not an external disk (VENTOY_ALLOW_INTERNAL=1 is set)."
    fi
}

# Hash of everything that goes into the image besides Ventoy itself
build_hash() {
    (
        cd "${SCRIPT_DIR}"
        find Dockerfile .dockerignore scripts -type f 2>/dev/null | LC_ALL=C sort | xargs shasum -a 256
    ) | shasum -a 256 | cut -d ' ' -f 1
}

image_label() {
    docker image inspect -f "{{ index .Config.Labels \"$1\" }}" "${IMAGE}" 2>/dev/null || true
}

# Build the image only when it is missing, a newer Ventoy release exists,
# or the Dockerfile or container scripts changed since it was built
ensure_image() {
    local latest installed hash installed_hash version
    latest="$(curl -fsS https://api.github.com/repos/ventoy/Ventoy/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)" || true
    installed="$(image_label ventoy.version)"
    installed_hash="$(image_label ventoy.build-hash)"
    hash="$(build_hash)"

    if [[ -z "${latest}" ]]; then
        if [[ -z "${installed}" ]]; then
            echo "Error: Could not determine the latest Ventoy release and no image is built."
            exit 1
        fi
        echo "Warning: Could not check for the latest Ventoy release. Keeping Ventoy ${installed}."
        version="${installed}"
    else
        version="${latest}"
    fi

    if [[ "${installed}" == "${version}" && "${installed_hash}" == "${hash}" ]]; then
        echo "Ventoy ${installed} is up to date."
        return
    fi

    if [[ -z "${installed}" ]]; then
        echo "Building the '${IMAGE}' image with Ventoy ${version}..."
    elif [[ "${installed}" != "${version}" ]]; then
        echo "Updating Ventoy ${installed} to ${version}..."
    else
        echo "Container files changed. Rebuilding the image with Ventoy ${version}..."
    fi
    docker build --pull \
        --build-arg VENTOY_VERSION="${version}" \
        --label ventoy.version="${version}" \
        --label ventoy.build-hash="${hash}" \
        -t "${IMAGE}" "${SCRIPT_DIR}"
}

unmount_device() {
    local device="$1"
    if mount | grep -Eq "^${device}(s[0-9]+)? "; then
        echo "Unmounting ${device}..."
        sudo diskutil unmountDisk force "${device}"
    fi
}

start_qemu_nbd() {
    local device="$1" port="$2"
    echo "Starting qemu-nbd on port ${port} for ${device}..."
    sudo qemu-nbd --fork --pid-file="${PID_FILE}" --persistent \
        -p "${port}" -f raw "${device}"
    sudo chmod 644 "${PID_FILE}"
}

# Wait until VentoyWeb answers or the container exits
wait_for_container() {
    local web_port="$1"
    for _ in $(seq 1 30); do
        if ! container_running; then
            return 1
        fi
        if curl -fs -o /dev/null "http://localhost:${web_port}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

do_start() {
    local device="" web_port="24680" nbd_port="10809"

    while getopts ":d:p:n:" opt; do
        case "${opt}" in
        d) device="${OPTARG}" ;;
        p) web_port="${OPTARG}" ;;
        n) nbd_port="${OPTARG}" ;;
        *) usage ;;
        esac
    done

    if [[ -z "${device}" ]]; then
        echo "Error: Device (-d) is required."
        usage
    fi

    check_os
    check_dependencies

    if qemu_nbd_running || container_running; then
        echo "Error: Ventoy is already running. Run '$0 stop' first."
        exit 1
    fi
    if container_exists; then
        docker rm -f "${CONTAINER}" >/dev/null
    fi

    validate_device "${device}"
    ensure_image

    echo "Administrator access is needed to unmount the disk and run qemu-nbd."
    sudo -v

    mkdir -p "${RUN_DIR}"
    printf 'DEVICE=%s\nWEB_PORT=%s\nNBD_PORT=%s\n' "${device}" "${web_port}" "${nbd_port}" >"${STATE_FILE}"

    # Roll back anything already started if a later step fails or is interrupted
    START_OK="false"
    trap 'if [[ "${START_OK}" != "true" ]]; then echo "Start failed, cleaning up..."; do_stop >/dev/null 2>&1 || true; fi' EXIT
    trap 'exit 130' INT TERM

    unmount_device "${device}"
    start_qemu_nbd "${device}" "${nbd_port}"

    echo "Starting the Docker container..."
    docker run -d \
        --name "${CONTAINER}" \
        --privileged \
        -p "${web_port}":24680 \
        -e NBD_PORT="${nbd_port}" \
        "${IMAGE}" >/dev/null

    if ! wait_for_container "${web_port}"; then
        echo "Error: The container did not start correctly. Container logs:"
        docker logs "${CONTAINER}" 2>&1 | tail -n 20 || true
        exit 1
    fi

    START_OK="true"
    trap - EXIT INT TERM

    cat <<EOF

==============================================================
Ventoy $(docker exec "${CONTAINER}" cat VERSION) is running.

  VentoyWeb:    http://localhost:${web_port}
  Ventoy CLI:   docker exec -it ${CONTAINER} bash
                (then ./Ventoy2Disk.sh <commands>, device /dev/nbd0)

When you are done, run:

  $0 stop

❌ Ventoy GUI is NOT supported. Only Ventoy CLI and VentoyWeb.
==============================================================
EOF
}

do_stop() {
    local device=""
    if [[ -f "${STATE_FILE}" ]]; then
        device="$(sed -n 's/^DEVICE=//p' "${STATE_FILE}")"
    fi

    if container_running; then
        echo "Detaching NBD inside the container..."
        if ! docker exec "${CONTAINER}" sh -c 'sync && ./scripts/cleanup.sh'; then
            echo "⚠️  Warning: NBD detach failed. Pending writes to the USB drive may be lost."
        fi
        echo "Stopping the container..."
        docker stop "${CONTAINER}" >/dev/null
    fi
    if container_exists; then
        docker rm "${CONTAINER}" >/dev/null
    fi

    if qemu_nbd_running; then
        local pid
        pid="$(read_pid)"
        echo "Stopping qemu-nbd (pid ${pid})..."
        sudo kill "${pid}"
        for _ in $(seq 1 10); do
            ps -p "${pid}" &>/dev/null || break
            sleep 1
        done
        if ps -p "${pid}" &>/dev/null; then
            echo "Error: qemu-nbd (pid ${pid}) did not exit."
            exit 1
        fi
    fi

    rm -f "${PID_FILE}" "${STATE_FILE}"

    echo "Stopped."
    if [[ -n "${device}" ]]; then
        echo "You can now eject the drive, or remount it with: diskutil mountDisk ${device}"
    fi
}

if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

case "${COMMAND}" in
start) do_start "$@" ;;
stop)
    check_os
    check_dependencies
    do_stop
    ;;
*) usage ;;
esac
