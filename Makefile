# talos-nvidia-open-extension build orchestration
#
# Two-phase build (see README.md):
#
#   1. make nvidia-open-latest-pkg
#      Compiles the NVIDIA open GPU kernel modules against the Talos kernel
#      inside a pinned checkout of siderolabs/pkgs. The `kernel-build` stage is
#      NOT published upstream (only exists inside the pkgs build graph), so we
#      overlay our pkg into that graph and let BuildKit rebuild the chain
#      (tools -> kernel-prepare -> kernel-build -> nvidia modules).
#      Expect 30-60+ min per arch on first build (full kernel compile);
#      subsequent builds hit the BuildKit cache.
#      Result is pushed to $(REGISTRY)/$(USERNAME)/nvidia-open-latest-pkg.
#
#   2. make nvidia-open-modules nvidia-open-firmware
#      Builds the Talos system extension images from this repo's bldr graph,
#      repackaging the pkg image from phase 1 (modules) and the NVIDIA redist
#      archive (GSP firmware).

# Any OCI registry works (docker.io, ghcr.io, a local registry, ...).
# For Docker Hub: REGISTRY=docker.io USERNAME=<your Docker Hub username>,
# after `docker login`. Note: Talos nodes must be able to pull the extension
# images, so the repositories need to be public (or registry auth configured
# in the machine config).
REGISTRY ?= docker.io
USERNAME ?= shrinedogg
PUSH ?= false
PLATFORM ?= linux/amd64
PROGRESS ?= auto
DEST ?= _out

BUILD := docker buildx build

# --- Talos / pkgs pinning ----------------------------------------------------
# PKGS must be the pkgs tag pinned by the target Talos release, from:
#   https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs
# TOOLS must match TOOLS_REV in the pinned siderolabs/pkgs Pkgfile.
TALOS_VERSION ?= v1.14.0
PKGS ?= v1.14.0-15-g2f03590
PKGS_PREFIX ?= ghcr.io/siderolabs
TOOLS ?= v1.14.0-5-g87316ca
TOOLS_PREFIX ?= ghcr.io/siderolabs

# Driver version single source of truth: vars.yaml
NVIDIA_DRIVER_VERSION := $(shell awk '/^NVIDIA_DRIVER_VERSION:/ {print $$2}' vars.yaml)
CONTAINER_TOOLKIT_VERSION := $(shell awk '/^CONTAINER_TOOLKIT_VERSION:/ {print $$2}' vars.yaml)

# Extension/image version convention: <driver-version>-<talos-version>
TAG ?= $(TALOS_VERSION)
VERSION := $(NVIDIA_DRIVER_VERSION)-$(TAG)
# The toolkit is not kernel-bound: <driver-version>-<toolkit-version>
TOOLKIT_VERSION := $(NVIDIA_DRIVER_VERSION)-$(CONTAINER_TOOLKIT_VERSION)

PKG_IMAGE ?= $(REGISTRY)/$(USERNAME)/nvidia-open-latest-pkg:$(VERSION)

COMMON_ARGS := --progress=$(PROGRESS)
COMMON_ARGS += --platform=$(PLATFORM)
COMMON_ARGS += --provenance=false

EXT_BUILD_ARGS := --build-arg=TAG=$(TAG)
EXT_BUILD_ARGS += --build-arg=PKGS=$(PKGS)
EXT_BUILD_ARGS += --build-arg=PKGS_PREFIX=$(PKGS_PREFIX)
EXT_BUILD_ARGS += --build-arg=TOOLS=$(TOOLS)
EXT_BUILD_ARGS += --build-arg=TOOLS_PREFIX=$(TOOLS_PREFIX)
EXT_BUILD_ARGS += --build-arg=NVIDIA_PKG_IMAGE=$(PKG_IMAGE)

TARGETS = nvidia-open-modules nvidia-open-firmware nvidia-open-toolkit

.PHONY: all
all: $(TARGETS)

.PHONY: help
help: ## Show available targets.
	@grep -E '^[a-zA-Z_%-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-28s %s\n", $$1, $$2}'

# --- Phase 1: kernel-module pkg built inside pinned siderolabs/pkgs checkout --

# PKGS is usually a `git describe` string (e.g. v1.13.0-36-g6b315f7); the
# commit to check out is the part after the final -g. If PKGS is a plain tag,
# check out the tag itself.
PKGS_REF := $(shell echo $(PKGS) | sed -n 's/.*-g\([0-9a-f][0-9a-f]*\)$$/\1/p')
ifeq ($(PKGS_REF),)
PKGS_REF := $(PKGS)
endif

# The pkgs checkout must live OUTSIDE this repo: bldr scans the entire build
# context for pkg.yaml files and does not honor .dockerignore, so a checkout
# under the repo root would leak the whole pkgs graph into ours.
BUILD_DIR ?= $(HOME)/.cache/talos-nvidia-open-extension
PKGS_DIR := $(BUILD_DIR)/pkgs
TALOS_DIR := $(BUILD_DIR)/talos
EXTENSIONS_DIR := $(BUILD_DIR)/extensions

# --- kernel module signing -----------------------------------------------------
# The Talos kernel is built with CONFIG_MODULE_SIG_ALL=y and boots with
# module.sig_enforce=1, so a module only loads if the kernel embeds the
# certificate that signed it. Upstream generates certs/signing_key.pem fresh in
# every kernel-build and never publishes it, so modules built here can never
# load on a stock Talos kernel (issue #11). Instead this repo owns the key:
# overlay-sync drops MODULE_SIG_KEY_FILE into the kernel-build pkg and points
# CONFIG_MODULE_SIG_KEY at it, and the `kernel` target publishes the resulting
# kernel so kernel and modules share certs/module-signing.crt.
#
# MODULE_SIG_KEY_FILE: PEM holding private key + certificate (GitHub secret
# MODULE_SIGNING_KEY in CI). Without it a throwaway key is generated, which is
# fine for compile checks; PUSH=true refuses a key that does not match
# certs/module-signing.crt.
MODULE_SIG_KEY_FILE ?= $(BUILD_DIR)/module-signing-key.pem
MODULE_SIG_CERT := certs/module-signing.crt
KERNEL_IMAGE ?= $(REGISTRY)/$(USERNAME)/kernel:$(PKGS)

# --- kernel source fallback ---------------------------------------------------
# cdn.kernel.org is currently functional (verified 2026-09-06), so
# KERNEL_SRC_FALLBACK defaults to 0 and the pkgs build pulls the canonical
# release tarball from cdn.kernel.org with the checksums pinned in the pkgs
# Pkgfile.
#
# KERNEL_SRC_FALLBACK=1 redirects the kernel download to git.kernel.org's
# cgit snapshot service — kept as an escape hatch because kernel.org's tarball
# distribution has gone down before (2026-07-03: path-based 404s across cdn
# AND all rsync mirrors, from multiple egresses including GitHub runners).
# The snapshot is a .tar.gz with its own checksums, pinned below to the kernel
# version of the current PKGS tag.
# NOTE: re-pin KERNEL_SRC_* when bumping PKGS (download the snapshot,
# shasum -a 256/512).
KERNEL_SRC_FALLBACK ?= 0
KERNEL_VERSION ?= 6.18.48
KERNEL_SRC_URL ?= https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$(KERNEL_VERSION).tar.gz
KERNEL_SRC_SHA256 ?= 025478b8674936cd3701233b3343c396c427b8adc615c328fb6aa53a84cb48e6
KERNEL_SRC_SHA512 ?= 7bb36081842daf84a1851d0e70e80779066af8d0d66f3d45a9eb91ce295c177f721bfb6a55a074dfc7509dea78a4de91446567a25ab3c841a98675ee1db8b9f9

$(PKGS_DIR):
	git clone --filter=blob:none https://github.com/siderolabs/pkgs $@
	git -C $@ checkout $(PKGS_REF)

.PHONY: overlay-sync
overlay-sync: $(PKGS_DIR) ## Sync overlay/, vars.yaml, the signature verifier and the module signing key into the pkgs checkout.
	git -C $(PKGS_DIR) checkout -- .
	git -C $(PKGS_DIR) clean -fdq
	git -C $(PKGS_DIR) checkout $(PKGS_REF)
	rm -rf $(PKGS_DIR)/nvidia-open-latest
	cp -R overlay/nvidia-open-latest $(PKGS_DIR)/nvidia-open-latest
	cp vars.yaml $(PKGS_DIR)/nvidia-open-latest/vars.yaml
	cp hack/verify-module-signatures.sh $(PKGS_DIR)/nvidia-open-latest/verify-module-signatures.sh
	hack/module-signing-key.sh ensure $(MODULE_SIG_KEY_FILE)
	cp $(MODULE_SIG_KEY_FILE) $(PKGS_DIR)/kernel/build/certs/module-signing-key.pem
	sed -i.bak 's|^CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/module-signing-key.pem"|' $(PKGS_DIR)/kernel/build/config-amd64
	rm -f $(PKGS_DIR)/kernel/build/config-amd64.bak
	grep -q '^CONFIG_MODULE_SIG_KEY="certs/module-signing-key.pem"$$' $(PKGS_DIR)/kernel/build/config-amd64
	@if hack/module-signing-key.sh matches $(MODULE_SIG_KEY_FILE) $(MODULE_SIG_CERT); then \
		cp $(MODULE_SIG_CERT) $(PKGS_DIR)/nvidia-open-latest/expected-module-signing.crt; \
		echo "==> signing key matches $(MODULE_SIG_CERT) (release key)"; \
	elif [ "$(PUSH)" = "true" ]; then \
		echo "error: refusing PUSH=true with a signing key that does not match $(MODULE_SIG_CERT)" >&2; \
		exit 1; \
	else \
		echo "WARNING: throwaway signing key; the resulting kernel and modules will not match $(MODULE_SIG_CERT)"; \
	fi
ifeq ($(KERNEL_SRC_FALLBACK),1)
	hack/patch-kernel-source.sh $(PKGS_DIR) $(KERNEL_SRC_URL) $(KERNEL_SRC_SHA256) $(KERNEL_SRC_SHA512)
endif

.PHONY: nvidia-open-latest-pkg
nvidia-open-latest-pkg: overlay-sync ## Build (and PUSH=true to push) the kernel-modules pkg image.
	$(BUILD) $(COMMON_ARGS) \
		--file=$(PKGS_DIR)/Pkgfile \
		--target=$@ \
		--tag=$(PKG_IMAGE) \
		--output=type=image,push=$(PUSH) \
		$(PKGS_DIR)

# The kernel that trusts our modules, plus every other kernel-module pkg the
# cluster's extensions need (zfs). Tagged with the pkgs tag, mirroring
# ghcr.io/siderolabs/<name>:$(PKGS), so the same PKGS pin selects our images
# when PKGS_PREFIX is pointed at $(REGISTRY)/$(USERNAME).
.PHONY: kernel zfs-pkg
kernel zfs-pkg: overlay-sync ## Build (PUSH=true to push) a pkgs-graph image signed with our key, tagged $(PKGS).
	$(BUILD) $(COMMON_ARGS) \
		--file=$(PKGS_DIR)/Pkgfile \
		--target=$@ \
		--tag=$(REGISTRY)/$(USERNAME)/$@:$(PKGS) \
		--output=type=image,push=$(PUSH) \
		$(PKGS_DIR)

# --- Phase 2: extension images (this repo's bldr graph) -----------------------

.PHONY: nvidia-open-modules nvidia-open-firmware
nvidia-open-modules nvidia-open-firmware: ## Build kernel-bound extension image (PUSH=true to push).
	$(BUILD) $(COMMON_ARGS) $(EXT_BUILD_ARGS) \
		--file=Pkgfile \
		--target=$@ \
		--tag=$(REGISTRY)/$(USERNAME)/$@:$(VERSION) \
		--output=type=image,push=$(PUSH) \
		.

.PHONY: nvidia-open-toolkit
nvidia-open-toolkit: ## Build userspace/toolkit extension image, tagged <driver>-<toolkit> (PUSH=true to push).
	$(BUILD) $(COMMON_ARGS) $(EXT_BUILD_ARGS) \
		--file=Pkgfile \
		--target=$@ \
		--tag=$(REGISTRY)/$(USERNAME)/$@:$(TOOLKIT_VERSION) \
		--output=type=image,push=$(PUSH) \
		.

local-%: ## Build extension and export rootfs to $(DEST)/<name> for inspection.
	$(BUILD) $(COMMON_ARGS) $(EXT_BUILD_ARGS) \
		--file=Pkgfile \
		--target=$* \
		--output=type=local,dest=$(DEST)/$* \
		.

# --- Maintenance ---------------------------------------------------------------

# For a self-hosted Image Factory in custom-registry mode, override
# CATALOG_TAG to the repo the factory expects (usually
# <mirror-registry>/siderolabs/extensions:<talos-version>) and set
# MIRROR_NS=<mirror-registry>/siderolabs so official refs point at the mirror.
CATALOG_TAG ?= $(REGISTRY)/$(USERNAME)/extensions:$(TALOS_VERSION)

.PHONY: catalog
catalog: ## Build/push extensions catalog (official + ours) for self-hosted Image Factory.
	hack/build-catalog.sh \
		--talos-version $(TALOS_VERSION) \
		--extension $(REGISTRY)/$(USERNAME)/nvidia-open-modules:$(VERSION) \
		--extension $(REGISTRY)/$(USERNAME)/nvidia-open-firmware:$(VERSION) \
		--extension $(REGISTRY)/$(USERNAME)/nvidia-open-toolkit:$(TOOLKIT_VERSION) \
		--tag $(CATALOG_TAG) \
		$(if $(MIRROR_NS),--mirror-namespace $(MIRROR_NS)) \
		$(if $(filter true,$(PUSH)),--push) \
		--out $(DEST)/catalog

.PHONY: update-checksums
update-checksums: ## Refresh NVIDIA archive checksums in vars.yaml.
	hack/update-checksums.sh

.PHONY: test
test: ## Run the shell script tests under hack/test.
	@for t in hack/test/*_test.sh; do bash "$$t" || exit 1; done

.PHONY: talos-pkgs-version
talos-pkgs-version: ## Print the pkgs tag pinned by $(TALOS_VERSION).
	@curl -fsSL https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs

.PHONY: clean
clean: ## Remove build artifacts and the pkgs checkout.
	rm -rf $(BUILD_DIR) _out
