#!/bin/bash
set -Eeuo pipefail
umask 022

# ============================================================
# Amazon Linux 2023 - DevSecOps Tool Bootstrap
# Tools: Docker, Jenkins, AWS CLI, Snyk, Gitleaks, Trivy,
#        Checkov, K3s, Helm, Falco, SonarQube
# ============================================================

JENKINS_HOME="/var/lib/jenkins"
CHECKOV_VENV="/opt/checkov-venv"
AWS_CLI_ZIP="/tmp/awscliv2.zip"
AWS_CLI_DIR="/tmp/aws"
LOG_FILE="/var/log/devsecops-bootstrap.log"

# Log output to both terminal and file.
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo
    echo "============================================================"
    echo "==> $1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $*"
    exit 1
}

# Display diagnostic logs if any command fails.
on_error() {
    local exit_code=$?
    echo
    echo "ERROR: Script failed at line ${BASH_LINENO[0]:-unknown}"
    echo "Exit code: $exit_code"
    echo "Check the log: $LOG_FILE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl status jenkins --no-pager -l || true
        journalctl -u jenkins -n 50 --no-pager || true
    fi

    exit "$exit_code"
}
trap on_error ERR

# ------------------------------------------------------------
# Step 0: Verify operating system and privileges
# ------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo bash tool.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot identify the operating system."
fi

source /etc/os-release

if [[ "${ID:-}" != "amzn" || "${VERSION_ID:-}" != "2023" ]]; then
    fail "This script is intended for Amazon Linux 2023."
fi

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        AWS_ARCH="x86_64"
        GITLEAKS_ARCH="x64"
        ;;
    aarch64)
        AWS_ARCH="aarch64"
        GITLEAKS_ARCH="arm64"
        ;;
    *)
        fail "Unsupported architecture: $ARCH"
        ;;
esac

# ------------------------------------------------------------
# Step 1: Update the system
# ------------------------------------------------------------
log "Updating system packages"
dnf update -y

# ------------------------------------------------------------
# Step 2: Install base dependencies and Java 21
# ------------------------------------------------------------
log "Installing base packages and Java 21"

dnf install -y \
    git \
    docker \
    java-21-amazon-corretto \
    fontconfig \
    python3.11 \
    python3.11-pip \
    python3.11-devel \
    gcc \
    nodejs \
    npm \
    unzip \
    tar \
    wget \
    curl-minimal \
    gzip \
    shadow-utils

command -v curl >/dev/null 2>&1 ||
    fail "curl is unavailable."

command -v python3.11 >/dev/null 2>&1 ||
    fail "Python 3.11 is unavailable."

java -version
python3.11 --version
node --version
npm --version

# ------------------------------------------------------------
# Step 3: Configure Java 21 for Jenkins
# ------------------------------------------------------------
log "Configuring Java 21"

JAVA21="$(find /usr/lib/jvm \
    -type f \
    -path '*/bin/java' \
    2>/dev/null |
    grep -E 'java-21.*corretto|corretto.*21' |
    head -n 1 || true)"

if [[ -z "$JAVA21" || ! -x "$JAVA21" ]]; then
    fail "Java 21 executable was not found under /usr/lib/jvm."
fi

JAVA_HOME_21="$(dirname "$(dirname "$JAVA21")")"

echo "Java executable: $JAVA21"
echo "Java home: $JAVA_HOME_21"

# Set Java 21 as the default when its alternatives entry exists.
if alternatives --list 2>/dev/null |
    grep -q '^java .*java-21-amazon-corretto'; then

    JAVA_ALT="$(alternatives --list |
        awk '$1 == "java" && $3 ~ /java-21-amazon-corretto/ {
            print $3
            exit
        }')"

    if [[ -n "$JAVA_ALT" ]]; then
        alternatives --set java "$JAVA_ALT"
    fi
fi

# ------------------------------------------------------------
# Step 4: Enable Docker
# ------------------------------------------------------------
log "Enabling and starting Docker"

systemctl enable --now docker

id -u ec2-user >/dev/null 2>&1 &&
    usermod -aG docker ec2-user || true

# ------------------------------------------------------------
# Step 5: Install Jenkins LTS
# ------------------------------------------------------------
log "Installing Jenkins LTS"

wget -q -O /etc/yum.repos.d/jenkins.repo \
    https://pkg.jenkins.io/rpm-stable/jenkins.repo

rpm --import \
    https://pkg.jenkins.io/rpm-stable/jenkins.io-2026.key

dnf install -y jenkins

# Configure the Java executable used by the Jenkins service.
mkdir -p /etc/systemd/system/jenkins.service.d

cat > /etc/systemd/system/jenkins.service.d/java.conf <<EOF
[Service]
Environment="JENKINS_JAVA_CMD=$JAVA21"
Environment="JAVA_HOME=$JAVA_HOME_21"
EOF

# ------------------------------------------------------------
# Step 6: Configure Jenkins Docker access and start Jenkins
# ------------------------------------------------------------
log "Configuring and starting Jenkins"

id jenkins >/dev/null 2>&1 ||
    fail "The Jenkins package did not create the jenkins user."

usermod -aG docker jenkins

systemctl daemon-reload
systemctl enable jenkins
systemctl reset-failed jenkins || true

# Docker must be running before Jenkins starts.
systemctl restart docker

if ! systemctl restart jenkins; then
    journalctl -u jenkins -n 100 --no-pager || true
    fail "Jenkins failed to start. Review the service logs above."
fi

# Wait up to 90 seconds for Jenkins to become active.
for attempt in $(seq 1 30); do
    if systemctl is-active --quiet jenkins; then
        break
    fi
    sleep 3
done

if ! systemctl is-active --quiet jenkins; then
    journalctl -u jenkins -n 100 --no-pager || true
    fail "Jenkins did not become active."
fi

systemctl status jenkins --no-pager -l

# ------------------------------------------------------------
# Step 7: Install Snyk CLI
# ------------------------------------------------------------
log "Installing Snyk CLI"

npm install --global snyk

# ------------------------------------------------------------
# Step 8: Install AWS CLI v2
# ------------------------------------------------------------
log "Installing AWS CLI v2"

rm -f "$AWS_CLI_ZIP"
rm -rf "$AWS_CLI_DIR"

curl -fsSL \
    "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
    -o "$AWS_CLI_ZIP"

unzip -q "$AWS_CLI_ZIP" -d /tmp

/tmp/aws/install --update

ln -sf /usr/local/bin/aws /usr/bin/aws

rm -f "$AWS_CLI_ZIP"
rm -rf "$AWS_CLI_DIR"

# ------------------------------------------------------------
# Step 9: Install Gitleaks
# ------------------------------------------------------------
log "Installing Gitleaks"

GITLEAKS_VERSION="$(
    curl -fsSL \
        https://api.github.com/repos/gitleaks/gitleaks/releases/latest |
    python3.11 -c '
import json, sys
print(json.load(sys.stdin)["tag_name"].lstrip("v"))
'
)"

[[ -n "$GITLEAKS_VERSION" ]] ||
    fail "Unable to determine the Gitleaks release version."

GITLEAKS_FILE="gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz"

curl -fsSL \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_FILE}" \
    -o /tmp/gitleaks.tar.gz

tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks

install -m 0755 /tmp/gitleaks /usr/local/bin/gitleaks

rm -f /tmp/gitleaks /tmp/gitleaks.tar.gz

# ------------------------------------------------------------
# Step 10: Install Trivy
# ------------------------------------------------------------
log "Installing Trivy"

cat > /etc/yum.repos.d/trivy.repo <<'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
enabled=1
gpgcheck=0
EOF

dnf install -y trivy

# ------------------------------------------------------------
# Step 11: Install Checkov
# ------------------------------------------------------------
log "Installing Checkov in a Python 3.11 virtual environment"

if [[ ! -x "$CHECKOV_VENV/bin/python" ]]; then
    python3.11 -m venv "$CHECKOV_VENV"
fi

"$CHECKOV_VENV/bin/python" -m pip install --upgrade pip
"$CHECKOV_VENV/bin/python" -m pip install --upgrade checkov

ln -sf "$CHECKOV_VENV/bin/checkov" /usr/local/bin/checkov

# ------------------------------------------------------------
# Step 12: Install K3s Kubernetes
# ------------------------------------------------------------
log "Installing K3s"

if ! systemctl is-active --quiet k3s; then
    curl -fsSL https://get.k3s.io | sh -
fi

systemctl enable --now k3s

# Wait for the Kubernetes API to become available.
for attempt in $(seq 1 30); do
    if kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
        get nodes >/dev/null 2>&1; then
        break
    fi
    sleep 3
done

kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
    get nodes ||
    fail "K3s did not become ready."

# ------------------------------------------------------------
# Step 13: Configure kubeconfig for root and Jenkins
# ------------------------------------------------------------
log "Configuring Kubernetes access"

mkdir -p /root/.kube "$JENKINS_HOME/.kube"

install -m 0600 \
    /etc/rancher/k3s/k3s.yaml \
    /root/.kube/config

install -o jenkins -g jenkins -m 0600 \
    /etc/rancher/k3s/k3s.yaml \
    "$JENKINS_HOME/.kube/config"

# The K3s kubeconfig may use 127.0.0.1.
# This is appropriate for Jenkins running on the same instance.
export KUBECONFIG=/root/.kube/config

# ------------------------------------------------------------
# Step 14: Install Helm 3
# ------------------------------------------------------------
log "Installing Helm 3"

if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL \
        https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
        bash
fi

helm version

# ------------------------------------------------------------
# Step 15: Install Falco using Helm
# ------------------------------------------------------------
log "Installing Falco"

helm repo add falcosecurity \
    https://falcosecurity.github.io/charts \
    --force-update

helm repo update

helm upgrade --install falco falcosecurity/falco \
    --namespace falco \
    --create-namespace \
    --wait \
    --timeout 5m

# Falco may need compatible kernel headers or a supported
# driver. If this step fails, check the chart and node logs.

# ------------------------------------------------------------
# Step 16: Start SonarQube in Docker
# ------------------------------------------------------------
log "Starting SonarQube"

if docker container inspect sonarqube >/dev/null 2>&1; then
    docker update --restart unless-stopped sonarqube
    docker start sonarqube
else
    docker run -d \
        --name sonarqube \
        --restart unless-stopped \
        -p 9000:9000 \
        sonarqube:lts-community
fi

# ------------------------------------------------------------
# Step 17: Verify installed tools
# ------------------------------------------------------------
log "Verifying installed tools"

docker --version
java -version
node --version
npm --version
aws --version
snyk --version
gitleaks version
trivy --version
checkov --version
helm version
kubectl get nodes

log "Checking Jenkins service"
systemctl is-active jenkins

log "Checking Jenkins Docker access"
if sudo -u jenkins -H bash -c \
    'docker version >/dev/null 2>&1'; then
    echo "Jenkins Docker access: OK"
else
    echo "WARNING: Jenkins Docker access failed."
fi

log "Checking Jenkins Kubernetes access"
if sudo -u jenkins -H bash -c \
    'kubectl --kubeconfig=/var/lib/jenkins/.kube/config get nodes >/dev/null 2>&1'; then
    echo "Jenkins Kubernetes access: OK"
else
    echo "WARNING: Jenkins Kubernetes access failed."
fi

log "Checking SonarQube container"
docker ps --filter name=sonarqube

# ------------------------------------------------------------
# Step 18: Display Jenkins initial administrator password
# ------------------------------------------------------------
log "Jenkins initial administrator password"

if [[ -f "$JENKINS_HOME/secrets/initialAdminPassword" ]]; then
    cat "$JENKINS_HOME/secrets/initialAdminPassword"
else
    echo "Password file not available yet."
    echo "Check Jenkins startup logs before retrying."
fi

log "Bootstrap completed"
echo "Log file: $LOG_FILE"
echo "Jenkins URL: http://<EC2-PUBLIC-IP>:8080"
echo "SonarQube URL: http://<EC2-PUBLIC-IP>:9000"
echo "If group membership changes are needed, start a new login session."
