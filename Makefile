# talos-nvidia-open-extension build orchestration
#
# Two-phase build (see PLAN.md and README.md):
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
TALOS_VERSION ?= v1.13.8
PKGS ?= v1.13.0-55-gf677246
PKGS_PREFIX ?= ghcr.io/siderolabs
TOOLS ?= v1.13.0-8-gc2844e6
TOOLS_PREFIX ?= ghcr.io/siderolabs

# Driver version single source of truth: vars.yaml
NVIDIA_DRIVER_VERSION := $(shell awk '/^NVIDIA_DRIVER_VERSION:/ {print $$2}' vars.yaml)

# Extension/image version convention: <driver-version>-<talos-version>
TAG ?= $(TALOS_VERSION)
VERSION := $(NVIDIA_DRIVER_VERSION)-$(TAG)

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

TARGETS = nvidia-open-modules nvidia-open-firmware

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
KERNEL_VERSION ?= 6.18.42
KERNEL_SRC_URL ?= https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$(KERNEL_VERSION).tar.gz
KERNEL_SRC_SHA256 ?= 20cf040999a4167e0b8e9a86e0f482e9f6b055a94da89fd01fd496bfb2fca04d
KERNEL_SRC_SHA512 ?= ba5be01ff2420e07eff00135e1b5ca5c784584f8f31172adf535d6dceb0ec3a36a407548c38d4b271c659821a1130b8639a82241f7120fb392c0826dea23feec

$(PKGS_DIR):
	git clone --filter=blob:none https://github.com/siderolabs/pkgs $@
	git -C $@ checkout $(PKGS_REF)

.PHONY: overlay-sync
overlay-sync: $(PKGS_DIR) ## Sync overlay/ pkg + vars.yaml into the pkgs checkout.
	git -C $(PKGS_DIR) checkout -- .
	git -C $(PKGS_DIR) checkout $(PKGS_REF)
	rm -rf $(PKGS_DIR)/nvidia-open-latest
	cp -R overlay/nvidia-open-latest $(PKGS_DIR)/nvidia-open-latest
	cp vars.yaml $(PKGS_DIR)/nvidia-open-latest/vars.yaml
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

# --- Phase 2: extension images (this repo's bldr graph) -----------------------

.PHONY: $(TARGETS)
$(TARGETS): ## Build extension image (PUSH=true to push).
	$(BUILD) $(COMMON_ARGS) $(EXT_BUILD_ARGS) \
		--file=Pkgfile \
		--target=$@ \
		--tag=$(REGISTRY)/$(USERNAME)/$@:$(VERSION) \
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
		--tag $(CATALOG_TAG) \
		$(if $(MIRROR_NS),--mirror-namespace $(MIRROR_NS)) \
		$(if $(filter true,$(PUSH)),--push) \
		--out $(DEST)/catalog

.PHONY: update-checksums
update-checksums: ## Refresh NVIDIA archive checksums in vars.yaml.
	hack/update-checksums.sh

.PHONY: talos-pkgs-version
talos-pkgs-version: ## Print the pkgs tag pinned by $(TALOS_VERSION).
	@curl -fsSL https://raw.githubusercontent.com/siderolabs/talos/$(TALOS_VERSION)/pkg/machinery/gendata/data/pkgs

.PHONY: clean
clean: ## Remove build artifacts and the pkgs checkout.
	rm -rf $(BUILD_DIR) _out
