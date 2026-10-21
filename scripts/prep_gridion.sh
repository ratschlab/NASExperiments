#!/bin/bash
#
# Prepare a GridION (Ubuntu 24.04 + MinKNOW) for setup.sh without touching
# MinKNOW, dorado or the GPU driver.
#
#   scripts/prep_gridion.sh [--install] [--hold] [--env <name>]
#
# Without options it only reports, changing nothing:
#   - records installed ONT/MinKNOW/NVIDIA package versions to
#     ~/gridion_packages_<date>.txt
#   - system info (cores, RAM, free disk, cmake), dorado server version,
#     basecall socket access, unattended-upgrades configuration
#   - a dry run (apt-get install -s) of the build prerequisites, flagging any
#     ONT/MinKNOW/NVIDIA/CUDA/kernel package apt would install or upgrade
# Options:
#   --hold        apt-mark hold all installed ont-*/minknow*/nvidia packages
#   --install     install the build prerequisites, only if the dry run
#                 touches none of the protected packages
#   --env <name>  create conda env <name> from env.yml if it does not exist
#
set -uo pipefail

PACKAGES="build-essential git cmake make pkg-config autoconf automake libtool gettext-base
  libboost-all-dev libdeflate-dev libbz2-dev liblzma-dev libzstd-dev libjemalloc-dev
  libssl-dev libcurl4-openssl-dev zlib1g-dev"
# packages that must not change as a side effect
PROTECTED='^(ont-|minknow|nvidia|libnvidia|cuda|linux-image|linux-headers|linux-modules)'
SOCKET=/var/lib/minknow/data/.dorado/dorado-basecall-server.sock
DORADO=/opt/ont/dorado/bin/dorado_basecall_server

usage() {
    echo "Usage: $0 [--install] [--hold] [--env <name>]"
    echo ""
    echo "Without options, only reports and changes nothing."
    echo "  --install     install the build prerequisites (only if the apt dry run is safe)"
    echo "  --hold        apt-mark hold installed ont-*/minknow*/nvidia packages"
    echo "  --env <name>  create conda env <name> from env.yml if missing"
    echo "  -h, --help    Display this help message."
    exit 1
}

EXPDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )
INSTALL=0
HOLD=0
ENV_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install) INSTALL=1; shift ;;
        --hold) HOLD=1; shift ;;
        --env) ENV_NAME=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: Unknown argument '$1'" >&2; usage ;;
    esac
done

section() { echo; echo "=== $1"; }
warn() { echo "WARNING: $*" >&2; }

# --- Record package versions ---
section "Installed ONT / MinKNOW / NVIDIA packages"
RECORD=~/gridion_packages_$(date +%F).txt
dpkg -l | awk -v p="$PROTECTED" '/^(ii|hi)/ && $2 ~ p {print $1, $2, $3}' | tee "$RECORD"
echo "-> saved to $RECORD"
held=$(apt-mark showhold | grep -E "$PROTECTED" || true)
echo "held: ${held:-none}"

# --- System ---
section "System"
. /etc/os-release && echo "OS: $PRETTY_NAME"
echo "cores: $(nproc)   RAM: $(free -g | awk '/^Mem:/{print $2}') GB"
echo "free disk in $EXPDIR: $(df -h --output=avail "$EXPDIR" | tail -1 | tr -d ' ') (plan for ~15 GB)"
if command -v cmake > /dev/null; then
    echo "cmake: $(cmake --version 2>/dev/null | head -1) (need >= 3.19)"
else
    echo "cmake: not installed"
fi
if command -v conda > /dev/null; then
    echo "conda: $(conda --version)"
else
    warn "conda not found on PATH"
fi

# --- Basecaller ---
section "Dorado basecall server"
if [ -x "$DORADO" ]; then
    "$DORADO" --version 2>&1 | grep -m1 -i "version" | sed "s/^[: ]*//" || true
    echo "  (env.yml pins ont-pybasecall-client-lib==7.13.6; the versions must match)"
else
    warn "$DORADO not found"
fi
if [ -S "$SOCKET" ]; then
    ls -la "$SOCKET"
    if [ -w "$SOCKET" ]; then
        echo "socket writable by $(whoami): yes"
    else
        warn "socket not writable by $(whoami) (groups: $(id -nG))"
    fi
else
    warn "basecall socket $SOCKET not found (is MinKNOW running?)"
fi

# --- Automatic updates ---
section "Automatic updates"
echo "unattended-upgrades: $(systemctl is-enabled unattended-upgrades 2>/dev/null || echo 'not installed')"
grep -h "APT::Periodic" /etc/apt/apt.conf.d/*auto-upgrades 2>/dev/null || true
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    echo "allowed origins:"
    sed -n '/Allowed-Origins\|Origins-Pattern/,/};/p' /etc/apt/apt.conf.d/50unattended-upgrades \
        | grep -v '^\s*//' | grep '"' || true
fi

# --- Dry run ---
section "apt dry run of the build prerequisites"
dry=$(apt-get install -s $PACKAGES 2>&1)
changes=$(grep '^Inst' <<< "$dry" || true)
if [ -z "$changes" ]; then
    echo "nothing to install, all prerequisites present"
else
    echo "$changes"
fi
risky=$(awk '/^Inst/ {print $2}' <<< "$dry" | grep -E "$PROTECTED" || true)
if [ -n "$risky" ]; then
    warn "the install would change protected packages:"
    echo "$risky" | sed 's/^/  /' >&2
fi
if grep -q '^E:' <<< "$dry"; then
    warn "apt reports errors:"
    grep '^E:' <<< "$dry" >&2
fi

# --- Hold ---
if [ "$HOLD" = 1 ]; then
    section "Holding ONT / MinKNOW / NVIDIA packages"
    to_hold=$(dpkg -l | awk -v p="$PROTECTED" '/^ii/ && $2 ~ p && $2 !~ /^linux-/ {print $2}')
    if [ -n "$to_hold" ]; then
        sudo apt-mark hold $to_hold
        echo "undo later with: sudo apt-mark unhold \$(apt-mark showhold)"
    fi
fi

# --- Install ---
if [ "$INSTALL" = 1 ]; then
    section "Installing build prerequisites"
    if [ -n "$risky" ] || grep -q '^E:' <<< "$dry"; then
        warn "not installing: the dry run would change protected packages or failed (see above)"
        exit 1
    fi
    if [ -n "$changes" ]; then
        sudo apt-get install -y $PACKAGES
    fi
fi

# --- Conda env ---
if [ -n "$ENV_NAME" ]; then
    section "Conda env $ENV_NAME"
    if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
        echo "exists, skipping (remove it with: conda env remove -n $ENV_NAME)"
    else
        conda env create -f "$EXPDIR/env.yml" -n "$ENV_NAME"
    fi
fi

section "Next steps"
[ "$INSTALL" = 1 ] || echo "- review the dry run, then: $0 --install [--hold]"
[ -n "$ENV_NAME" ] || echo "- create the env: $0 --env selectiveseq_v2"
echo "- move an old code/ aside (setup.sh does not update existing checkouts)"
echo "- conda activate <env> && ./setup.sh"
echo "- put the reference, tmp/<dataset>/ indices and data/check/ samples in place"
echo "- scripts/check_tools.sh --sample data/check/hxb2.blow5"
