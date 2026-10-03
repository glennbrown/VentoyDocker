FROM ubuntu:latest

# Install system dependencies
RUN apt update && apt install -y \
    nbd-client util-linux \
    wget ca-certificates tar xz-utils \
    parted fdisk \
    udev \
    dosfstools

# Create work directory
WORKDIR /root

# Ventoy version to install: "latest" or a specific version such as "1.1.12"
ARG VENTOY_VERSION=latest

# Fetch the latest release metadata. Remote ADD sources are re-fetched on every
# build, so the cache is invalidated and the version check below always reruns.
ADD https://api.github.com/repos/ventoy/Ventoy/releases/latest /tmp/ventoy-release.json

# Download, verify and extract Ventoy into a version independent directory
RUN set -eu; \
    if [ "$VENTOY_VERSION" = "latest" ]; then \
        VERSION=$(sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' /tmp/ventoy-release.json | head -n 1); \
    else \
        VERSION="${VENTOY_VERSION#v}"; \
    fi; \
    if [ -z "$VERSION" ]; then \
        echo "Could not determine the latest Ventoy version (GitHub API rate limit?)" >&2; \
        exit 1; \
    fi; \
    echo "Installing Ventoy $VERSION"; \
    BASE_URL="https://github.com/ventoy/Ventoy/releases/download/v${VERSION}"; \
    TARBALL="ventoy-${VERSION}-linux.tar.gz"; \
    wget -q "${BASE_URL}/${TARBALL}" "${BASE_URL}/sha256.txt"; \
    grep " ${TARBALL}\$" sha256.txt | sha256sum -c -; \
    tar -xzf "$TARBALL"; \
    mv "ventoy-${VERSION}" ventoy; \
    echo "$VERSION" > ventoy/VERSION; \
    rm -f "$TARBALL" sha256.txt /tmp/ventoy-release.json

# Set Working Directory
# This is where the Ventoy files are located
WORKDIR /root/ventoy

COPY ./scripts/ /root/ventoy/scripts/

RUN chmod +x /root/ventoy/scripts/*.sh

# Connect to the host's NBD export and start VentoyWeb
ENTRYPOINT ["/root/ventoy/scripts/entrypoint.sh"]
