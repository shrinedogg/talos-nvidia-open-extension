# talos-nvidia-open-extension

Talos Linux system extensions shipping the **latest NVIDIA open GPU kernel
modules**, built standalone from [siderolabs/extensions] so driver bumps don't
wait on Sidero's release cadence. The open modules support **Turing or newer
GPUs only** (GTX 16xx / RTX 20xx+, A-, H-, L-, B-series). Three images are
produced: `nvidia-open-modules` (kernel modules compiled against the Talos
kernel), `nvidia-open-firmware` (the matching GSP firmware), and
`nvidia-open-toolkit` (userspace driver libraries, `nvidia-smi`,
`nvidia-persistenced` and the NVIDIA container toolkit, installed from the
same `.run` installer).

The kernel-module extension only loads on a kernel that embeds the
certificate that signed the modules. Talos signs its kernel modules with a
key generated per build and never published, so this repo publishes its own
Talos kernel and imager; see [Kernel and module signing](#kernel-and-module-signing).

## How it works

The build is two-phase:

1. **Kernel-modules pkg** — the Talos `kernel-build` stage is not published
   upstream (it only exists inside the [siderolabs/pkgs] build graph), so
   `make nvidia-open-latest-pkg` clones siderolabs/pkgs at the pinned `PKGS`
   tag into `~/.cache/talos-nvidia-open-extension/pkgs`, overlays this repo's
   `overlay/nvidia-open-latest` pkg recipe plus `vars.yaml`, and builds inside
   that graph. The modules are compiled from the **GitHub source tarball** of
   [NVIDIA/open-gpu-kernel-modules] (including the OS-independent resource
   manager under `src/`, which redist archives ship as precompiled blobs) —
   this is what lets us track GA releases the moment they're tagged. BuildKit
   rebuilds the chain tools → kernel-prepare → kernel-build → nvidia modules —
   a full kernel compile, 60+ minutes on a cold cache. The result
   is pushed to `<registry>/<username>/nvidia-open-latest-pkg`. The same
   graph also publishes the kernel (`kernel:<PKGS>`) and zfs
   (`zfs-pkg:<PKGS>`) images — see [Kernel and module signing](#kernel-and-module-signing).
2. **Extensions** — `make nvidia-open-modules nvidia-open-firmware nvidia-open-toolkit`
   builds the Talos system-extension images from this repo's bldr graph: the
   modules extension repackages the pkg image from phase 1, the firmware
   extension extracts GSP firmware from NVIDIA's official `.run` installer
   (makeself `--extract-only`; nothing is installed) into
   `/usr/lib/firmware/nvidia/<version>/`, and the toolkit extension runs the
   `.run` installer's `nvidia-installer` against its rootfs with
   `--no-kernel-modules` (libraries and tools under `/usr/local`), builds
   `nvidia-container-toolkit` from source, and ships the `nvidia-persistenced`
   and `nvidia-cdi-gen` Talos services.

Kernel-bound images (modules, firmware) follow the convention
`<driver-version>-<talos-version>`, e.g. `610.43.02-v1.13.5`. The toolkit is
not kernel-bound and is versioned `<driver>-<toolkit>`, e.g.
`610.57.04-v1.19.1`.

3. **Kernel, imager and rebuilt upstream extensions** — the same pkgs graph
   also publishes `kernel:<PKGS>` and `zfs-pkg:<PKGS>`, signed with this
   repo's key. `make imager` builds `siderolabs/talos` at `TALOS_VERSION` with
   `PKG_KERNEL` pointed at that kernel and pushes `imager:<TALOS_VERSION>`;
   `make sidero-extensions` rebuilds the upstream kernel-module extensions
   listed in `SIDERO_EXTENSIONS` against it. A self-hosted Image Factory
   serving this imager and a catalog built with `make catalog` produces
   installers on which `nvidia-open-modules` loads.

## Build

Prerequisites: Docker with buildx, and an account on any OCI registry
(Docker Hub is the default — `docker login` first; ghcr.io or a local
registry work too via `REGISTRY=`/`USERNAME=`). The repositories must be
public for Talos nodes to pull the extension images (or configure registry
auth in the machine config). For CI, set the `DOCKERHUB_USERNAME`,
`DOCKERHUB_TOKEN` and `MODULE_SIGNING_KEY` repository secrets (the latter is
the module signing key — see below).

```sh
# Phase 1: compile the kernel, the kernel modules pkg and zfs-pkg
# (must be pushed — phase 2 and the nodes pull them)
make kernel nvidia-open-latest-pkg zfs-pkg PUSH=true REGISTRY=docker.io USERNAME=<dockerhub-user>

# Phase 2: build and push the extension images
make nvidia-open-modules nvidia-open-firmware nvidia-open-toolkit PUSH=true REGISTRY=docker.io USERNAME=<dockerhub-user>

# Inspect an extension rootfs locally without pushing
make local-nvidia-open-modules DEST=_out

# Discover the pkgs tag pinned by a Talos release (for the PKGS Makefile var)
make talos-pkgs-version TALOS_VERSION=v1.14.0

# Phase 3: imager and upstream extensions on our kernel
make imager sidero-extensions linux-firmware-mirror PUSH=true REGISTRY=docker.io USERNAME=<dockerhub-user>

# Shell tests (catalog builder, imager contract, signing-key helper, signature verifier)
make test
```

**Kernel source fallback:** cdn.kernel.org is currently functional, so the
build pulls the canonical kernel release tarball from there with the
checksums pinned in the siderolabs/pkgs Pkgfile (`KERNEL_SRC_FALLBACK=0`, the
default). `KERNEL_SRC_FALLBACK=1` redirects the kernel download to
git.kernel.org's cgit snapshot service with independently pinned checksums
(see Makefile) — kept as an escape hatch because kernel.org's tarball
distribution went down globally for a period in 2026-07. Re-pin
`KERNEL_SRC_*` when bumping `PKGS`.

**Build host note:** the phase-1 kernel compile targets `linux/amd64` by
default; on an Apple Silicon Mac that runs under emulation and takes hours.
Prefer the GitHub Actions `kernel-pkgs` job (native amd64 runner) for full
builds, and keep local builds for validation.

## Kernel and module signing

Talos builds its kernel with `CONFIG_MODULE_SIG_ALL=y` and boots with
`module.sig_enforce=1`, so a module only loads if the kernel embeds the
certificate that signed it. Upstream siderolabs/pkgs generates a fresh
signing key in every `kernel-build` and never publishes it, so modules built
here cannot load on a stock Talos kernel
([issue #11](https://github.com/shrinedogg/talos-nvidia-open-extension/issues/11)).
This repo therefore owns the signing key: the public certificate is
committed at `certs/module-signing.crt`, and the matching private key is a
PEM (private key plus certificate, generated with
`hack/module-signing-key.sh generate`) that must never be committed —
`.gitignore` excludes `*.pem`.

- **CI releases:** store the PEM as the `MODULE_SIGNING_KEY` repository
  secret. The workflow installs it and fails before any build if it is
  missing or does not match `certs/module-signing.crt`.
- **Local builds:** put the PEM at
  `~/.cache/talos-nvidia-open-extension/module-signing-key.pem` or point
  `MODULE_SIG_KEY_FILE=<path>` at it. Without it, `make` generates a
  throwaway key, which is fine for compile checks; `PUSH=true` refuses to
  push anything signed by a key that does not match
  `certs/module-signing.crt`.
- `make overlay-sync` drops the key into the pkgs `kernel-build` and points
  `CONFIG_MODULE_SIG_KEY` at it (both the amd64 and arm64 kernel configs).
  Every built `.ko` is verified against the certificate the kernel embeds,
  and release builds additionally compare that certificate with
  `certs/module-signing.crt` (`hack/verify-module-signatures.sh`).

The same phase-1 graph publishes the signed kernel as
`<registry>/<username>/kernel:<PKGS>` and zfs as
`<registry>/<username>/zfs-pkg:<PKGS>`, mirroring
`ghcr.io/siderolabs/<name>:<PKGS>`, so the same `PKGS` pin selects these
images when `PKGS_PREFIX` is pointed at `<registry>/<username>`. The
modules only load on a node that boots this kernel.

## Version pinning

Driver bumps track **GitHub GA releases** of [NVIDIA/open-gpu-kernel-modules]
directly. Any GA tag is pinnable: module sources come from the release
tarball, and GSP firmware from the matching `.run` installer at
`download.nvidia.com/XFree86` (published for `Linux-x86_64` and
`Linux-aarch64` alongside every release). This deliberately runs ahead of
NVIDIA's redist channel (and of `siderolabs/extensions`, which pins from it).
Do **not** pin the `595.44.x`-style Vulkan-beta releases — they are marked
prerelease on GitHub, and Renovate's `github-releases` datasource skips them
by default.

To bump the driver:

1. Edit `NVIDIA_DRIVER_VERSION` in `vars.yaml`.
2. Run `hack/update-checksums.sh` — downloads the source tarball, both
   `.run` installers and the container-toolkit tarball (~850 MB total) and
   recomputes all eight checksums; NVIDIA publishes none for these artifacts.

To bump Talos, three Makefile pins move together:

- `TALOS_VERSION` — the target Talos release.
- `PKGS` — must equal the pkgs tag pinned by that Talos release, from
  `talos/pkg/machinery/gendata/data/pkgs` (`make talos-pkgs-version`).
- `TOOLS` — must match `TOOLS_REV` in that pkgs tag's `Pkgfile`.

Also re-pin `GLIBC_IMAGE` in `vars.yaml` from that release's bundle
(`talosctl image talos-bundle <ver> | grep glibc`): the toolkit's glibc must
match the glibc extension built for the same Talos release.

## Usage

See [`_docs/machine-config-example.yaml`](_docs/machine-config-example.yaml) for
a machine-config patch. Key points:

- All three extensions must be baked into an installer built from this repo's
  imager (self-hosted Image Factory schematic); the public factory's installers
  use Sidero's kernel and reject these modules. The **firmware and modules
  versions must match exactly** - GSP firmware is mandatory and version-locked
  to the driver.
- The modules extension blacklists the nvidia modules in `modprobe.d`, so they
  must be loaded explicitly via `machine.kernel.modules`: `nvidia`,
  `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`.
- All three extensions must be installed together, and `nvidia-open-modules`,
  `nvidia-open-firmware` and `nvidia-open-toolkit` must carry the same driver
  version. Do not install `siderolabs/nvidia-container-toolkit-*` or
  `siderolabs/nvidia-open-gpu-kernel-modules-*` alongside them. The toolkit
  extension registers the `nvidia` containerd runtime handler
  (`/etc/cri/conf.d/10-nvidia-container-runtime.part`) and generates the CDI
  spec at `/run/cdi/nvidia.yaml`; nodes need
  `machine.sysctls: net.core.bpf_jit_harden: "1"` as with Sidero's toolkit.

## Kernel and module signing

Talos builds its kernel with `CONFIG_MODULE_SIG_ALL=y` and boots with
`module.sig_enforce=1`; the signing key is generated inside each
`kernel-build` and never published. Modules built anywhere else are rejected
with `key was rejected by service` (issue #11), and `module.sig_enforce=0`
cannot override the built-in `=1` (the parameter is set-once).

This repo therefore owns the key:

- `certs/module-signing.crt` is the public certificate (committed).
- The private key (PEM with key and certificate) is the `MODULE_SIGNING_KEY`
  repository secret; `make overlay-sync` installs `MODULE_SIG_KEY_FILE`
  (default `~/.cache/talos-nvidia-open-extension/module-signing-key.pem`) into
  `kernel/build/certs/` and sets `CONFIG_MODULE_SIG_KEY` to it. Without the
  key a throwaway one is generated for compile checks; `PUSH=true` refuses it.
- Every `.ko` is verified with `hack/verify-module-signatures.sh` (`openssl
  cms -verify` against the certificate the kernel embeds, and against
  `certs/module-signing.crt` in the extension build). `make test` runs the
  script tests.
- Rotating the key: `hack/module-signing-key.sh generate <key.pem> certs/module-signing.crt`,
  `gh secret set MODULE_SIGNING_KEY < <key.pem>`, commit the new certificate,
  then rebuild kernel, imager, all extensions and reinstall every node. Kernel
  and modules from different keys never mix.

Consequences: a node must boot the kernel from `imager:<TALOS_VERSION>` of
this repo, and every kernel-module extension on that node must be one of the
`sidero-extensions` rebuilds (or an extension from this repo). Stock
`ghcr.io/siderolabs/<driver>` extensions will not load on it. This is the
trade-off for tracking NVIDIA GA releases ahead of `siderolabs/extensions`.
Publishing the images changes no node; wiring them into a self-hosted Image
Factory and upgrading nodes is a separate rollout.

## Compatibility

| Extension version | Talos | Kernel | pkgs | toolkit |
|---|---|---|---|---|
| 610.57.04-v1.14.0 | v1.14.0 | 6.18.48 | v1.14.0-15-g2f03590 | 610.57.04-v1.19.1 |
| 610.57.04-v1.13.8 | v1.13.8 | 6.18.42 | v1.13.0-55-gf677246 | 610.57.04-v1.19.1 |
| 610.43.03-v1.13.6 | v1.13.6 | 6.18.38 | v1.13.0-43-gd8c80cc | n/a |

[siderolabs/extensions]: https://github.com/siderolabs/extensions
[siderolabs/pkgs]: https://github.com/siderolabs/pkgs
[NVIDIA/open-gpu-kernel-modules]: https://github.com/NVIDIA/open-gpu-kernel-modules
