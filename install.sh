#!/bin/sh
# Installs the host packages the API needs at runtime on a clean Debian minimal install.
# Firecracker, umoci and the Alpine rootfs are downloaded by the API itself on first start.
# Supported: Debian 12 and 13 (the ASP.NET Core runtime comes from packages.microsoft.com).

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

PACKAGES="
    bash
    ca-certificates
    openssl
    iproute2
    nftables
    iptables
    kmod
    procps
    util-linux
    mount
    e2fsprogs
    squashfs-tools
    tar
    gzip
    skopeo
    curl
"

DOTNET_RUNTIME=aspnetcore-runtime-10.0

echo "Installing packages..."
apt-get update
apt-get install -y --no-install-recommends $PACKAGES

# The API is a framework-dependent executable: it needs the ASP.NET Core runtime from Microsoft's Debian repository
if ! dpkg -s "$DOTNET_RUNTIME" > /dev/null 2>&1; then
    echo "Installing $DOTNET_RUNTIME..."
    DEBIAN_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    curl -fsSL -o /tmp/packages-microsoft-prod.deb "https://packages.microsoft.com/config/debian/$DEBIAN_VERSION/packages-microsoft-prod.deb"
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    apt-get update
    apt-get install -y --no-install-recommends "$DOTNET_RUNTIME"
fi
dotnet --list-runtimes

echo "Loading kernel modules..."
# tun: tap devices for the VMs, br_netfilter: iptables physdev rules on the bridges, loop: mount -o loop
for module in tun br_netfilter loop; do
    modprobe "$module"
    echo "$module" > "/etc/modules-load.d/vm-orchestrator-$module.conf"
done

echo "Checking KVM..."
if [ ! -e /dev/kvm ]; then
    echo "WARNING: /dev/kvm not found. Enable virtualization (VT-x/AMD-V or nested virtualization) or Firecracker will not start"
elif ! [ -r /dev/kvm ] || ! [ -w /dev/kvm ]; then
    echo "WARNING: /dev/kvm is not readable/writable by root"
fi

echo "Downloading vm-orchestrator-api..."
# The repository is private: a GitHub personal access token with read access to it is required
if [ -z "$GITHUB_TOKEN" ]; then
    # Read from the terminal with echo off so the token is not shown, even when the script is piped into sh
    printf "GitHub personal access token: "
    stty -echo < /dev/tty
    trap 'stty echo < /dev/tty' EXIT
    read -r GITHUB_TOKEN < /dev/tty
    stty echo < /dev/tty
    trap - EXIT
    echo ""
fi
if [ -z "$GITHUB_TOKEN" ]; then
    echo "A GitHub token is required to download vm-orchestrator-api"
    exit 1
fi
curl -fsSL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -o vm-orchestrator-api \
    "https://raw.githubusercontent.com/jsancarl/vm-orchestrator/main/vm-orchestrator-api/publish/vm-orchestrator-api"
chmod +x vm-orchestrator-api

echo "Downloading vm-orchestrator-ui..."
mkdir -p runtime/resources/ui
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" https://api.github.com/repos/OWNER/REPO/tarball/main | tar -xz -C runtime/resources/ui --strip-components=2 '*/dist'

echo ""
echo "Done. Run the API as root from the directory it is installed in: ./vm-orchestrator-api"
