#!/bin/bash
# bootstrap-runner.sh
# Provisions a VPS to run GitHub Actions self-hosted runner jobs.
#
# Run as root on a fresh Ubuntu 20.04+ VPS:
#   sudo bash scripts/bootstrap-runner.sh
#
# After this script completes, manually register the runner:
#   su - github-runner
#   cd ~/actions-runner
#   ./config.sh --url https://github.com/YOUR-ORG/YOUR-REPO --token YOUR_TOKEN
#   exit
#   sudo /home/github-runner/actions-runner/svc.sh install github-runner
#   sudo /home/github-runner/actions-runner/svc.sh start
#
# PACKAGE LOG — update this script each time a new workflow dependency is
# discovered at runtime. This is the authoritative list of what this runner needs.
#
# Discovered packages (in order found):
#   unzip       — hashicorp/setup-terraform extracts Terraform binary with unzip
#   docker.io   — Docker builds, image pulls/pushes from Docker Hub
#   python3     — Workflow step summaries and CI scripts (note: NOT 'python')
#   python3-pip — pip install for workflow tools (e.g. checkov, azure-cli extras)
#   jq          — JSON parsing in shell workflow steps
#   git         — actions/checkout requires git
#   curl        — downloading binaries, connectivity checks, azure API calls
#   nodejs/npm  — npm audit, npm install for Next.js web app builds
#   pipx        — Install Python tools (checkov, etc.) without system conflicts
#   az ext: containerapp — 211 runs `az containerapp job ...` for DB migration +
#                          revision restarts; core az CLI does NOT include it
#   powershell (pwsh) — 330 teardown runs Remove-CnaStaleAiResources.ps1 via pwsh;
#                       not an apt default, installed from Microsoft's package repo
#
# GOTCHAS for self-hosted runners (vs. ubuntu-latest which has these handled):
#   - Workflows must call `python3`, never bare `python` — Ubuntu ships no `python`.
#   - Core `az` does NOT include the `containerapp` command group; it lives in an
#     extension that must be installed (`az extension add --name containerapp`).
#     211 also adds it defensively at runtime, but pre-install avoids a slow first run.
#   - Ubuntu 24.04+ enforces PEP 668: `pip install` system-wide fails with
#     "externally-managed-environment". Use pipx for standalone CLI tools.
#   - pipx installs CLIs to ~/.local/bin, which is NOT on the runner service's
#     (non-login shell) PATH. Workflows resolve the tool via
#     `pipx environment --value PIPX_BIN_DIR` rather than assuming PATH.
#   - The runner user must be in the `docker` group AND the service restarted
#     for group membership to take effect.

set -euo pipefail

RUNNER_VERSION="2.335.1"
RUNNER_SHA="4ef2f252585f8ae477f1fe1e346db76d2f3ebf03824c2ddd1973a2819bf6c8cf"
RUNNER_USER="github-runner"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}==> $1${NC}"; }
ok()    { echo -e "    ${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "    ${YELLOW}[!]${NC}  $1"; }
error() { echo -e "    ${RED}[ERROR]${NC} $1"; exit 1; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root: sudo bash $0"
fi

# ── 1. System packages ────────────────────────────────────────────────────────
step "Installing system packages"

apt-get update -qq

# Core utilities
apt-get install -y \
    curl \
    git \
    unzip \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    nodejs \
    npm

ok "Core utilities installed (npm: $(npm --version))"

# Python (workflows use python3 — NOT bare 'python')
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    pipx

ok "Python3 installed ($(python3 --version))"
ok "pipx installed ($(pipx --version))"

# PowerShell Core (pwsh) — workflow 330 teardown runs Remove-CnaStaleAiResources.ps1
# via `pwsh`. Core `apt` has no powershell package; install from Microsoft's repo.
step "Installing PowerShell (pwsh)"
if ! command -v pwsh &>/dev/null; then
    UBUNTU_VERSION="$(lsb_release -rs 2>/dev/null || echo '24.04')"
    curl -fsSL -o /tmp/packages-microsoft-prod.deb \
        "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/packages-microsoft-prod.deb" \
        || curl -fsSL -o /tmp/packages-microsoft-prod.deb "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb"
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    apt-get update -qq
    apt-get install -y powershell
    ok "PowerShell installed ($(pwsh --version))"
else
    ok "PowerShell already installed ($(pwsh --version))"
fi

# Azure CLI
step "Installing Azure CLI"
if ! command -v az &>/dev/null; then
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    ok "Azure CLI installed ($(az --version | head -1))"
else
    ok "Azure CLI already installed ($(az --version | head -1))"
fi

# Azure CLI extensions used by workflow 211. The `containerapp` extension is
# REQUIRED — 211 runs `az containerapp job ...` for the DB migration and revision
# restarts; without it those commands fail with "unrecognized arguments: job".
step "Installing Azure CLI extensions"
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors 2>/dev/null || true
az extension add --name containerapp --upgrade --only-show-errors 2>/dev/null \
    && ok "Azure CLI extension installed: containerapp" \
    || warn "Could not pre-install the containerapp extension; 211 installs it defensively at runtime"

# Docker
step "Installing Docker"
if ! command -v docker &>/dev/null; then
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker
    ok "Docker installed ($(docker --version))"
else
    ok "Docker already installed ($(docker --version))"
fi

# ── 2. Create runner user ─────────────────────────────────────────────────────
step "Creating runner user: ${RUNNER_USER}"

if id "${RUNNER_USER}" &>/dev/null; then
    ok "User ${RUNNER_USER} already exists"
else
    useradd -m -s /bin/bash "${RUNNER_USER}"
    ok "Created user ${RUNNER_USER}"
fi

# Add to docker group (required to talk to Docker daemon)
usermod -aG docker "${RUNNER_USER}"
ok "Added ${RUNNER_USER} to docker group"

# ── 3. Download runner ────────────────────────────────────────────────────────
step "Downloading GitHub Actions runner v${RUNNER_VERSION}"

mkdir -p "${RUNNER_DIR}"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"

if [[ -f "${RUNNER_DIR}/config.sh" ]]; then
    ok "Runner already downloaded — skipping"
else
    curl -fsSL -o "/tmp/${RUNNER_ARCHIVE}" "${RUNNER_URL}"

    # Verify checksum
    echo "${RUNNER_SHA}  /tmp/${RUNNER_ARCHIVE}" | sha256sum -c - \
        || error "Checksum mismatch — download may be corrupted. Re-run the script."

    tar xzf "/tmp/${RUNNER_ARCHIVE}" -C "${RUNNER_DIR}"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"
    rm -f "/tmp/${RUNNER_ARCHIVE}"
    ok "Runner extracted to ${RUNNER_DIR}"
fi

# ── 4. Connectivity check ─────────────────────────────────────────────────────
step "Checking network connectivity"

check_endpoint() {
    local name="$1"
    local url="$2"
    echo -n "    Checking ${name} ... "
    if curl -s -m 5 -I "${url}" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ OK${NC}"
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        return 1
    fi
}

CONN_FAILED=0
check_endpoint "GitHub API"         "https://api.github.com"            || CONN_FAILED=1
check_endpoint "Azure Management"   "https://management.azure.com"      || CONN_FAILED=1
check_endpoint "Microsoft Entra ID" "https://login.microsoftonline.com" || CONN_FAILED=1
check_endpoint "Docker Hub"         "https://index.docker.io"           || CONN_FAILED=1
check_endpoint "Docker Registry"    "https://registry.hub.docker.com"   || CONN_FAILED=1

if [[ "${CONN_FAILED}" -eq 1 ]]; then
    warn "One or more endpoints unreachable — check firewall rules before registering the runner"
else
    ok "All connectivity checks passed"
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Bootstrap complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Next steps — run these manually (requires a fresh GitHub registration token):"
echo ""
echo -e "  ${CYAN}1. Get a registration token:${NC}"
echo "     GitHub → Settings → Actions → Runners → New self-hosted runner"
echo "     (token expires in 1 hour)"
echo ""
echo -e "  ${CYAN}2. Configure the runner:${NC}"
echo "     su - ${RUNNER_USER}"
echo "     cd ~/actions-runner"
echo "     ./config.sh --url https://github.com/YOUR-ORG/YOUR-REPO --token YOUR_TOKEN"
echo "     exit"
echo ""
echo -e "  ${CYAN}3. Install and start as a systemd service:${NC}"
echo "     sudo ${RUNNER_DIR}/svc.sh install ${RUNNER_USER}"
echo "     sudo ${RUNNER_DIR}/svc.sh start"
echo "     sudo ${RUNNER_DIR}/svc.sh status"
echo ""
echo -e "  ${CYAN}4. Verify Docker access works:${NC}"
echo "     sudo systemctl restart actions.runner.*"
echo "     docker run --rm hello-world  # run as github-runner to verify"
echo ""
echo -e "${YELLOW}Remember:${NC} if you add packages later, update the PACKAGE LOG"
echo "at the top of this script so the next VPS onboards in one shot."
echo ""
