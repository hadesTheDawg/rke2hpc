#!/usr/bin/env bash
# Runs as root on the RPM fetch host (internet-connected EL host of the target arch).
# Env: RPM_PACKAGES RKE2_RPM_VERSION EL_MAJOR RPM_ARCH
# Downloads the packages with their complete dependency closure and builds a
# dnf repository under /var/tmp/hpc-rpm-fetch/repo.
set -euo pipefail
W=/var/tmp/hpc-rpm-fetch
mkdir -p "$W/repo"
rpm -q dnf-plugins-core createrepo_c >/dev/null 2>&1 || dnf -y -q install dnf-plugins-core createrepo_c
kube_minor=$(sed -E 's/^([0-9]+\.[0-9]+).*/\1/' <<<"$RKE2_RPM_VERSION")
cat >/etc/yum.repos.d/hpc-fetch.repo <<REPO
[hpc-fetch-rke2-common]
name=RKE2 common
baseurl=https://rpm.rancher.io/rke2/latest/common/centos/$EL_MAJOR/noarch
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
[hpc-fetch-rke2]
name=RKE2 $kube_minor
baseurl=https://rpm.rancher.io/rke2/latest/$kube_minor/centos/$EL_MAJOR/$RPM_ARCH
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
REPO
trap 'rm -f /etc/yum.repos.d/hpc-fetch.repo' EXIT
pkgs=()
for p in $RPM_PACKAGES; do
  case "$p" in rke2-server|rke2-agent) pkgs+=("$p-$RKE2_RPM_VERSION") ;; *) pkgs+=("$p") ;; esac
done
# --alldeps: take the whole closure, not just what this host happens to lack.
dnf -y -q download --resolve --alldeps --arch "$RPM_ARCH" --arch noarch --destdir "$W/repo" "${pkgs[@]}"
curl -fsSL -o "$W/repo/RPM-GPG-KEY-rancher" https://rpm.rancher.io/public.key
cp -f "/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$EL_MAJOR" "$W/repo/RPM-GPG-KEY-distro" 2>/dev/null \
  || cp -f "/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release" "$W/repo/RPM-GPG-KEY-distro" 2>/dev/null \
  || cp -f "$(ls /etc/pki/rpm-gpg/RPM-GPG-KEY-* | head -1)" "$W/repo/RPM-GPG-KEY-distro"
createrepo_c -q --update "$W/repo"
chmod -R a+rX "$W"
echo "repo: $(find "$W/repo" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ') rpms, $(du -sh "$W/repo" | awk '{print $1}')"
