#!/usr/bin/env bash
# ProsperoLight - macOS build entry point.
# Copyright (C) 2026 BlackBearReloaded
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The build needs Linux: clang-18 plus the PS5 payload SDK, and Apple Silicon
# cannot nest a hypervisor, so WSL, Docker Desktop and any in-VM hypervisor are
# unavailable. This script runs the documented Linux build inside a Lima guest
# on Apple's Virtualization.framework and copies the result into dist/, so one
# command produces the folder to upload to the console.
#
# The first run downloads the Ubuntu image, the apt toolchain and the pinned
# SDKs (several gigabytes). Later runs reuse the guest and its dependency cache.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

vm=${PROSPEROLIGHT_VM:-prospero}
image=template://ubuntu-24.04

# Mirrors .github/workflows/tooling.yml. libllvmspirvlib is what the PyroWave
# RADV build resolves SPIR-V through; zip and python3-pip serve packaging and
# the Mbed TLS generators.
apt_packages=(
    clang-18 clang-format-18 clang-tidy-18 llvm-18-dev cmake lld-18 make ccache
    pkg-config tar unzip wget zip ninja-build bison flex libclang-18-dev
    libclang-cpp18-dev libclc-18-dev libclc-18 libllvmspirvlib-18-dev
    spirv-tools glslang-tools libegl-dev libgl-dev libgl1-mesa-dri libpng-dev
    libturbojpeg0-dev libwebp-dev python3-pip
)
python_packages=(Jinja2==3.1.6 jsonschema==4.25.1 Mako==1.3.10 PyYAML==6.0.2 meson==1.7.0 packaging==25.0)

step() { printf '\n==> %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ $(uname -s) == Darwin ]] || die "this entry point is only for macOS"
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
for tool in git rsync ssh curl python3; do
    command -v "$tool" >/dev/null || die "$tool is required"
done

step "Installing Lima"
if brew list --versions lima >/dev/null 2>&1; then
    printf '    lima already installed\n' >&2
else
    brew install lima
fi

# Keep the guest inside the host's budget; the build uses make -j$(nproc).
cpus=$(sysctl -n hw.ncpu)
((cpus > 6)) && cpus=6
memory=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024 / 2))
((memory > 12)) && memory=12
((memory < 4)) && memory=4

step "Starting the $vm Ubuntu guest ($cpus CPUs, ${memory} GiB)"
if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    limactl start "$vm" --tty=false >/dev/null
else
    limactl start --name "$vm" --tty=false --cpus "$cpus" --memory "$memory" "$image" >/dev/null
fi
ssh_config="$HOME/.lima/$vm/ssh.config"
[[ -f $ssh_config ]] || die "Lima did not write $ssh_config"
ssh_target="lima-$vm"
guest() { ssh -F "$ssh_config" -o BatchMode=yes "$ssh_target" "$@"; }
push() { rsync -a --checksum -e "ssh -F $ssh_config -o BatchMode=yes" "$@"; }

guest_home=$(guest 'printf %s "$HOME"')
[[ -n $guest_home ]] || die "cannot read the guest home directory"
vm_src="$guest_home/prospero-src"

step "Provisioning the guest"
provision=$(mktemp)
trap 'rm -f -- "$provision"' EXIT
cat >"$provision" <<PROVISION
set -euo pipefail
missing=0
for command in clang-18 llvm-config-18 lld-18 make cmake ninja zip; do
    command -v "\$command" >/dev/null || missing=1
done
if (( missing )); then
    echo "    installing the Ubuntu 24.04 toolchain" >&2
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${apt_packages[*]}
fi
if ! python3 -c 'import jinja2, jsonschema, mako, yaml, mesonbuild, packaging'; then
    echo "    installing the pinned Python modules" >&2
    python3 -m pip install --quiet --break-system-packages ${python_packages[*]}
fi
# The build links libclang_rt.builtins-x86_64.a because the PS5 target is
# x86-64, but arm64 Ubuntu only ships the aarch64 archive. Fetch the matching
# amd64 file from the archive rather than rebuilding compiler-rt.
builtins=/usr/lib/llvm-18/lib/clang/18/lib/linux/libclang_rt.builtins-x86_64.a
if [[ ! -s \$builtins ]]; then
    echo "    installing the x86-64 compiler-rt builtins archive" >&2
    version=\$( (dpkg-query -W -f='\${Version}' libclang-rt-18-dev 2>/dev/null ||
        apt-cache policy libclang-rt-18-dev | awk '/Candidate:/ {print \$2}') | sed 's/^[0-9]*://')
    [[ -n \$version ]] || { echo "cannot resolve the libclang-rt-18-dev version" >&2; exit 1; }
    temporary=\$(mktemp -d)
    trap 'rm -rf -- "\$temporary"' EXIT
    for component in universe main; do
        url="http://archive.ubuntu.com/ubuntu/pool/\$component/l/llvm-toolchain-18/libclang-rt-18-dev_\${version}_amd64.deb"
        curl -sSfL -o "\$temporary/rt.deb" "\$url" 2>/dev/null && break
    done
    [[ -s \$temporary/rt.deb ]] || { echo "the amd64 compiler-rt package was not found" >&2; exit 1; }
    dpkg-deb -x "\$temporary/rt.deb" "\$temporary/root"
    sudo mkdir -p "\$(dirname "\$builtins")"
    sudo cp "\$temporary/root\$builtins" "\$builtins"
fi
echo "    guest ready: \$(clang-18 --version | head -1)"
PROVISION
push "$provision" "$ssh_target:.prosperolight-provision.sh"
guest "bash .prosperolight-provision.sh"

title_id=$(python3 - <<'PY'
import json, pathlib
print(json.loads(pathlib.Path("sce_sys/param.json").read_text())["titleId"])
PY
)
content_version=$(python3 - <<'PY'
import json, pathlib
print(json.loads(pathlib.Path("sce_sys/param.json").read_text())["contentVersion"])
PY
)
[[ -n $title_id && -n $content_version ]] || die "cannot read the app identity from sce_sys/param.json"

step "Copying the working tree into the guest"
# .deps holds the guest's own downloads, build/ and dist/ hold its output, so
# none of them cross the link in either direction.
guest "mkdir -p '$vm_src'"
push --delete \
    --exclude '.deps/' --exclude 'build/' --exclude 'dist/' --exclude '.DS_Store' \
    "$root/" "$ssh_target:$vm_src/"

# Validated streaming releases keep the settings their measurements were taken
# with, exactly as the CI workflow decides it.
app_flags=()
case "$content_version" in
    01.000.062 | 01.000.070 | 01.000.080 | 01.000.090 | 01.000.095 | 01.000.100 | 01.000.110)
        app_flags=(FEC_SIMD=1 OPUS_SIMD=1 PERFORMANCE_DETAIL=1 FLIP_POLL_US=200
            INPUT_POLL_US=2000 VIDEO_SLICES_PER_FRAME=8)
        ;;
esac

step "Building $title_id $content_version in the guest"
build_script=$(mktemp)
trap 'rm -f -- "$provision" "$build_script"' EXIT
cat >"$build_script" <<'BUILD'
set -euo pipefail
source_dir=$1
title_id=$2
shift 2
# meson 1.7.0 lands in ~/.local/bin, which a non-login shell does not read.
export PATH="$HOME/.local/bin:$PATH"
cd "$source_dir"
echo "make deps"
make deps
echo "make libc"
make libc
( cd runtime && sha256sum -c libc.prx.sha256 )
echo "make app $*"
make app "$@" -j"$(nproc)"
cd dist
rm -f "$title_id.zip"
zip -qry "$title_id.zip" "$title_id"
sha256sum "$title_id.zip" >SHA256SUMS
cat SHA256SUMS
BUILD
push "$build_script" "$ssh_target:.prosperolight-build.sh"
guest "bash .prosperolight-build.sh '$vm_src' '$title_id' ${app_flags[*]:-}"

step "Copying the result into $root/dist"
mkdir -p "$root/dist"
rsync -a --delete -e "ssh -F $ssh_config -o BatchMode=yes" "$ssh_target:$vm_src/dist/" "$root/dist/"
[[ -f "$root/dist/$title_id/eboot.bin" ]] || die "the build produced no $title_id/eboot.bin"

step "Done"
cat "$root/dist/SHA256SUMS" >&2
printf '\nApp folder: %s\n' "$root/dist/$title_id" >&2
printf 'Release ZIP: %s\n' "$root/dist/$title_id.zip" >&2
printf 'Upload the %s folder to /data/homebrew on the console.\n' "$title_id" >&2
printf 'The guest stays running; "limactl stop %s" frees its memory.\n' "$vm" >&2
