<!-- markdownlint-configure-file { "MD004": { "style": "consistent" } } -->
<!-- markdownlint-disable MD033 -->

# VentoyDocker

<p align="center">
  <img src="./assets/VentoyDocker.png" alt="VentoyDocker logo" width="300" />
  <br>
  <strong>Run Ventoy via Docker</strong>
</p>

<!-- markdownlint-enable MD033 -->

VentoyDocker runs [Ventoy](https://www.ventoy.net/) inside a Docker container so macOS users can create Ventoy bootable USB drives without a native Ventoy build.

## Support Status

| Interface | Status |
| --- | --- |
| Ventoy CLI | Supported |
| VentoyWeb | Supported |
| Ventoy GUI | Not supported |

Linux users can run Ventoy natively. See the official [Ventoy getting started documentation](https://www.ventoy.net/en/doc_start.html).

## Tutorial

[![VentoyDocker Demo](https://i.imgflip.com/a6j2jf.jpg)](https://youtu.be/70btP4Nli1w?si=pVojLN-cwY4qmqzo)

## Prerequisites

- macOS
- Docker
- QEMU, including `qemu-nbd`
- A USB drive to install Ventoy on

Install QEMU with Homebrew:

```bash
brew install qemu
```

## Quick Start

> **Warning**
> Ventoy installation can erase or repartition the selected USB drive. Double-check the device path before running these commands.

1. Clone the repository:

   ```bash
   git clone https://github.com/Mr-Sunglasses/VentoyDocker.git
   cd VentoyDocker
   ```

2. Find the USB device path:

   ```bash
   diskutil list
   ```

   Use the whole external disk path, for example `/dev/disk5`, not a partition such as `/dev/disk5s1`.

3. Start Ventoy:

   ```bash
   ./ventoy.sh start -d /dev/disk5
   ```

4. Open VentoyWeb at `http://localhost:24680`, or use the Ventoy CLI:

   ```bash
   docker exec -it ventoy-docker bash
   ./Ventoy2Disk.sh <commands>
   ```

   Inside the container the USB drive is `/dev/nbd0`.

5. When you are done, stop everything:

   ```bash
   ./ventoy.sh stop
   ```

## How It Works

### Starting

```bash
./ventoy.sh start -d /dev/disk5
```

Run the script as your normal user. It asks for your password through `sudo` only for the steps that need root (unmounting the disk and running `qemu-nbd`). The `start` command:

1. Checks that the device is a whole external disk. Internal disks are refused to protect your Mac's own drives.
2. Checks GitHub for the latest Ventoy release and builds the Docker image only if it is missing, a newer release is available, or the `Dockerfile` or `scripts/` changed since the image was built.
3. Unmounts the disk if it is mounted.
4. Starts `qemu-nbd` in the background to export the disk over NBD, and records its process ID in `.run/qemu-nbd.pid`.
5. Starts the `ventoy-docker` container, which connects `nbd-client` to the exported disk as `/dev/nbd0` and starts VentoyWeb.

If any step fails, everything already started is stopped again.

Options:

| Option | Default | Description |
| --- | --- | --- |
| `-d DEVICE` | (required) | Whole USB disk, for example `/dev/disk5` |
| `-p PORT` | `24680` | Host port for VentoyWeb |
| `-n PORT` | `10809` | TCP port for `qemu-nbd` |

For example, to serve VentoyWeb on port 8080:

```bash
./ventoy.sh start -d /dev/disk5 -p 8080
```

### Stopping

```bash
./ventoy.sh stop
```

The `stop` command flushes and detaches NBD inside the container, stops and removes the container, and stops `qemu-nbd`. The clean NBD detach is essential to avoid data loss, so always use `stop` rather than killing the container. The disk stays unmounted afterwards. Eject it, or remount it with `diskutil mountDisk /dev/disk5`.

`stop` is safe to run more than once and also cleans up after an interrupted session.

### Pinning a Ventoy Version

`ventoy.sh` always uses the latest Ventoy release. To build an image with a specific version instead:

```bash
docker build --build-arg VENTOY_VERSION=1.1.12 --label ventoy.version=1.1.12 -t ventoy-docker:latest .
```

Note that the next `./ventoy.sh start` replaces it with the latest release when GitHub is reachable.

## FAQ

### Why does `ventoy.sh` ask for my password?

`qemu-nbd` needs direct access to the USB block device, and unmounting it requires administrator rights. Only those commands run through `sudo`.

### Can I use an internal disk?

No. `ventoy.sh` refuses disks that macOS does not report as external. For testing with a disk image you can override this with `VENTOY_ALLOW_INTERNAL=1`, at your own risk.

### Can I use this on Linux?

VentoyDocker is primarily for macOS. On Linux, use Ventoy directly by following the official [Ventoy getting started documentation](https://www.ventoy.net/en/doc_start.html).

## Contributing

Contributions are welcome. Open an issue for bug reports or feature requests, and use the repository templates when submitting pull requests.

## Authors

- [@Mr-Sunglasses](https://www.github.com/Mr-Sunglasses)

## License

This project is licensed under the [MIT License](LICENSE).

## Contributors

Thanks to everyone helping VentoyDocker grow.

[![Contributors](https://contrib.rocks/image?repo=Mr-Sunglasses/VentoyDocker)](https://github.com/Mr-Sunglasses/VentoyDocker/graphs/contributors)

## Support

If this project helps you, consider starring the repository.

[![Built with love](https://forthebadge.com/images/badges/built-with-love.svg)](https://forthebadge.com)
