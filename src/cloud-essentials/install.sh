#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# This script conditionally installs krew, teller, and k9s based on environment variables.
# It also installs specified krew plugins.
# Environment Variables to control the installations:
# - KREW_INSTALL: Set to "true" to install Krew and its plugins.
# - TELLER_INSTALL: Set to "true" to install Teller.
# - K9S_INSTALL: Set to "true" to install k9s.
# - KREW_PLUGINS: A space-separated list of krew plugins to install. Example: "ctx ns".
#-------------------------------------------------------------------------------------------------------------


set -e

# Clean up
rm -rf /var/lib/apt/lists/*

KUBECTL_VERSION="${VERSION:-"latest"}"
HELM_VERSION="${HELM:-"latest"}"
MINIKUBE_VERSION="${MINIKUBE:-"latest"}" # latest is also valid

KUBECTL_SHA256="${KUBECTL_SHA256:-"automatic"}"
HELM_SHA256="${HELM_SHA256:-"automatic"}"
MINIKUBE_SHA256="${MINIKUBE_SHA256:-"automatic"}"
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"

HELM_GPG_KEYS_URI="https://raw.githubusercontent.com/helm/helm/main/KEYS"
GPG_KEY_SERVERS="keyserver hkp://keyserver.ubuntu.com
keyserver hkp://keyserver.ubuntu.com:80
keyserver hkps://keys.openpgp.org
keyserver hkp://keyserver.pgp.com"

# Installation flags and default parameters
KREW_INSTALL="${KREW_INSTALL:-"true"}"
KREW_PLUGINS="${KREW_PLUGINS:-ctx ns}"
TELLER_INSTALL="${TELLER_INSTALL:-"true"}"
K9S_INSTALL="${K9S_INSTALL:-"true"}"
CILIUM_CLI_INSTALL="${CILIUM_CLI_INSTALL:-"true"}"
NATS_INSTALL="${NATS_INSTALL:-"true"}"
TASK_INSTALL="${TASK_INSTALL:-"true"}"
PULUMI_INSTALL="${PULUMI_INSTALL:-"true"}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

USERHOME="/home/$USERNAME"
if [ "$USERNAME" = "root" ]; then
    USERHOME="/root"
fi

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}    
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

apt_get_update()
{
    if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -y
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"
    fi
}

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install dependencies
check_packages curl ca-certificates coreutils gnupg2 dirmngr bash-completion vim iputils-ping dnsutils
if ! type git > /dev/null 2>&1; then
    check_packages git
fi

architecture="$(uname -m)"
case $architecture in
    x86_64) architecture="amd64";;
    aarch64 | armv8*) architecture="arm64";;
    aarch32 | armv7* | armvhf*) architecture="arm";;
    i?86) architecture="386";;
    *) echo "(!) Architecture $architecture unsupported"; exit 1 ;;
esac

if [ ${KUBECTL_VERSION} != "none" ]; then
    # Install the kubectl, verify checksum
    echo "Downloading kubectl..."
    if [ "${KUBECTL_VERSION}" = "latest" ] || [ "${KUBECTL_VERSION}" = "lts" ] || [ "${KUBECTL_VERSION}" = "current" ] || [ "${KUBECTL_VERSION}" = "stable" ]; then
        KUBECTL_VERSION="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
    else
        find_version_from_git_tags KUBECTL_VERSION https://github.com/kubernetes/kubernetes
    fi
    if [ "${KUBECTL_VERSION::1}" != 'v' ]; then
        KUBECTL_VERSION="v${KUBECTL_VERSION}"
    fi
    curl -sSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl"
    chmod 0755 /usr/local/bin/kubectl
    if [ "$KUBECTL_SHA256" = "automatic" ]; then
        KUBECTL_SHA256="$(curl -sSL "https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl.sha256")"
    fi
    ([ "${KUBECTL_SHA256}" = "dev-mode" ] || (echo "${KUBECTL_SHA256} */usr/local/bin/kubectl" | sha256sum -c -))
    if ! type kubectl > /dev/null 2>&1; then
        echo '(!) kubectl installation failed!'
        exit 1
    fi

    # kubectl bash completion
    kubectl completion bash > /etc/bash_completion.d/kubectl

    # kubectl zsh completion
    if [ -e "${USERHOME}/.oh-my-zsh" ]; then
        mkdir -p "${USERHOME}/.oh-my-zsh/completions"
        kubectl completion zsh > "${USERHOME}/.oh-my-zsh/completions/_kubectl"
        chown -R "${USERNAME}" "${USERHOME}/.oh-my-zsh"
    fi

    # Krew installation and plugin setup
    if [ "${KREW_INSTALL}" = "true" ]; then

        echo "Installing Krew..."

        sudo -u ${USERNAME} /bin/bash -c '(
        set -x; cd "$(mktemp -d)" &&
        OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
        ARCH="$(uname -m | sed -e "s/x86_64/amd64/" -e "s/\(arm\)\(64\)\?.*/\1\2/" -e "s/aarch64$/arm64/")" &&
        KREW="krew-${OS}_${ARCH}" &&
        curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
        tar zxvf "${KREW}.tar.gz" &&
        ./"${KREW}" install krew
        )'
        # echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' | sudo -u ${USERNAME} tee -a ~${USERNAME}/.zshrc
        echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' | sudo -u ${USERNAME} tee -a /home/${USERNAME}/.zshrc
        echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' | sudo -u ${USERNAME} tee -a /home/${USERNAME}/.bashrc

        echo "Krew installed successfully."
        echo "Installing Krew plugins"
        sudo -u "${USERNAME}" /bin/bash -c '(
            export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH" && kubectl krew install ctx && kubectl krew install ns
            )'

        echo "Krew installed successfully."
    fi

    # Install Krew plugins
    if [ ! -z "${KREW_PLUGINS}" ]; then
        echo "Installing specified Krew plugins: ${KREW_PLUGINS}"
        for plugin in ${KREW_PLUGINS}; do
            sudo -u "${USERNAME}" /bin/bash -c '(
            export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH" && kubectl krew install ${plugin} 
            )'
            # sudo -u ${USERNAME} bash -c "kubectl krew install ${plugin}"
        done
    fi

fi


if [ ${HELM_VERSION} != "none" ]; then
    # Install Helm, verify signature and checksum
    echo "Downloading Helm..."
    find_version_from_git_tags HELM_VERSION "https://github.com/helm/helm"
    if [ "${HELM_VERSION::1}" != 'v' ]; then
        HELM_VERSION="v${HELM_VERSION}"
    fi
    mkdir -p /tmp/helm
    helm_filename="helm-${HELM_VERSION}-linux-${architecture}.tar.gz"
    tmp_helm_filename="/tmp/helm/${helm_filename}"
    curl -sSL "https://get.helm.sh/${helm_filename}" -o "${tmp_helm_filename}"
    curl -sSL "https://github.com/helm/helm/releases/download/${HELM_VERSION}/${helm_filename}.asc" -o "${tmp_helm_filename}.asc"
    export GNUPGHOME="/tmp/helm/gnupg"
    mkdir -p "${GNUPGHOME}"
    chmod 700 ${GNUPGHOME}
    curl -sSL "${HELM_GPG_KEYS_URI}" -o /tmp/helm/KEYS
    echo -e "disable-ipv6\n${GPG_KEY_SERVERS}" > ${GNUPGHOME}/dirmngr.conf
    gpg -q --import "/tmp/helm/KEYS"
    if ! gpg --verify "${tmp_helm_filename}.asc" > ${GNUPGHOME}/verify.log 2>&1; then
        echo "Verification failed!"
        cat /tmp/helm/gnupg/verify.log
        exit 1
    fi

    if [ "${HELM_SHA256}" = "automatic" ]; then
        curl -sSL "https://get.helm.sh/${helm_filename}.sha256" -o "${tmp_helm_filename}.sha256"
        curl -sSL "https://github.com/helm/helm/releases/download/${HELM_VERSION}/${helm_filename}.sha256.asc" -o "${tmp_helm_filename}.sha256.asc"
        if ! gpg --verify "${tmp_helm_filename}.sha256.asc" > /tmp/helm/gnupg/verify.log 2>&1; then
            echo "Verification failed!"
            cat /tmp/helm/gnupg/verify.log
            exit 1
        fi
        HELM_SHA256="$(cat "${tmp_helm_filename}.sha256")"
    fi

    ([ "${HELM_SHA256}" = "dev-mode" ] || (echo "${HELM_SHA256} *${tmp_helm_filename}" | sha256sum -c -))
    tar xf "${tmp_helm_filename}" -C /tmp/helm
    mv -f "/tmp/helm/linux-${architecture}/helm" /usr/local/bin/
    chmod 0755 /usr/local/bin/helm
    rm -rf /tmp/helm
    if ! type helm > /dev/null 2>&1; then
        echo '(!) Helm installation failed!'
        exit 1
    fi
fi

# Install Minikube, verify checksum
if [ "${MINIKUBE_VERSION}" != "none" ]; then
    echo "Downloading minikube..."
    if [ "${MINIKUBE_VERSION}" = "latest" ] || [ "${MINIKUBE_VERSION}" = "lts" ] || [ "${MINIKUBE_VERSION}" = "current" ] || [ "${MINIKUBE_VERSION}" = "stable" ]; then
        MINIKUBE_VERSION="latest"
    else
        find_version_from_git_tags MINIKUBE_VERSION https://github.com/kubernetes/minikube
        if [ "${MINIKUBE_VERSION::1}" != "v" ]; then
            MINIKUBE_VERSION="v${MINIKUBE_VERSION}"
        fi
    fi
    # latest is also valid in the download URLs 
    curl -sSL -o /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}"    
    chmod 0755 /usr/local/bin/minikube
    if [ "$MINIKUBE_SHA256" = "automatic" ]; then
        MINIKUBE_SHA256="$(curl -sSL "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}.sha256")"
    fi
    ([ "${MINIKUBE_SHA256}" = "dev-mode" ] || (echo "${MINIKUBE_SHA256} */usr/local/bin/minikube" | sha256sum -c -))
    if ! type minikube > /dev/null 2>&1; then
        echo '(!) minikube installation failed!'
        exit 1
    fi
    # Create minkube folder with correct privs in case a volume is mounted here
    mkdir -p "${USERHOME}/.minikube"
    chown -R $USERNAME "${USERHOME}/.minikube"
    chmod -R u+wrx "${USERHOME}/.minikube"
fi

# k9s installation
if [ "${K9S_INSTALL}" = "true" ]; then

    echo "Installing k9s..."

    # Use sudo to switch to the USER and run the commands in a subshell
    sudo -u "$USERNAME" /bin/bash -c '(
    RELEASE_INFO=$(curl -s "https://api.github.com/repos/derailed/k9s/releases/latest")

    # Use jq to extract the download URL for the Linux AMD64 tarball directly,
    # ensuring we exclude any .sbom URLs
    TARBALL_URL=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name | endswith(\"_Linux_amd64.tar.gz\")) | .browser_download_url")

    if [ -z "$TARBALL_URL" ]; then
        echo "Failed to find k9s Linux_x86_64 release tarball."
        exit 1
    else
        echo "Found k9s release tarball: $TARBALL_URL"
    fi

    # Define a temporary location for the tarball
    TMP_TARBALL=$(mktemp)

    # Download the tarball
    echo "Downloading tarball..."
    curl -sL "$TARBALL_URL" --output "$TMP_TARBALL"

    # Extract k9s binary from the tarball
    echo "Extracting binary..."
    tar -xzf "$TMP_TARBALL" -C /tmp k9s

    # Check extraction result and proceed if successful
    if [ ! -f "/tmp/k9s" ]; then
        echo "k9s binary not found after extraction. Installation failed."
        # Clean up temporary file
        rm -f "$TMP_TARBALL"
        exit 1
    fi

    echo "Installing k9s..."
    # Use absolute sudo to move and set permissions, no need to switch user context again
    sudo mv /tmp/k9s /usr/local/bin/k9s
    sudo chmod +x /usr/local/bin/k9s
    sudo chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.local
    echo "k9s has been installed successfully!"


    # Setup Auto-completion
    echo "Setting up shell auto-completion for k9s..."

    # Bash
    k9s completion bash > /etc/bash_completion.d/k9s
    # Zsh: assuming .oh-my-zsh is installed for the user
    if [ -d "/home/${USERNAME}/.oh-my-zsh" ]; then
        k9s completion zsh > "/home/${USERNAME}/.oh-my-zsh/completions/_k9s"
    fi

    # Clean up the temporary file
    rm -f "$TMP_TARBALL"

    # Verify installation
    k9s version
    )'
fi

# Fetch the latest sealed-secrets version using GitHub API
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/tags | jq -r '.[0].name' | cut -c 2-)

# Check if the version was fetched successfully
if [ -z "$KUBESEAL_VERSION" ]; then
    echo "Failed to fetch the latest KUBESEAL_VERSION"
    exit 1
fi

wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal



# Cilium cli installation
if [ "${CILIUM_CLI_INSTALL}" = "true" ]; then

    echo "Installing Cilium cli ..."

    sudo -u "${USERNAME}" /bin/bash -c '(
        CILIUM_CLI_VERSION=$(sudo curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        CLI_ARCH=amd64
        if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
        sudo curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        sudo sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
        sudo chmod +x /usr/local/bin/cilium
        sudo chown -R ${USERNAME}:${USERNAME} /usr/local/bin/cilium
        sudo rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

        HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
        HUBBLE_ARCH=amd64
        if [ "$(uname -m)" = "aarch64" ]; then HUBBLE_ARCH=arm64; fi
        sudo curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
        sudo sha256sum --check hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC hubble-linux-${HUBBLE_ARCH}.tar.gz /usr/local/bin
        sudo chmod +x /usr/local/bin/hubble
        sudo chown -R ${USERNAME}:${USERNAME} /usr/local/bin/hubble
        sudo rm hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}
    )'

    echo "Cilium cli has been installed successfully."

fi

# Teller installation
if [ "${TELLER_INSTALL}" = "true" ]; then
    
    sudo -u "${USERNAME}" /bin/bash -c '(
    TARGET_DIR="/usr/local/bin"

    # Ensure the TARGET_DIR directory exists
    if [ ! -d "$TARGET_DIR" ]; then
        echo "The target directory $TARGET_DIR does not exist."
        exit 1
    fi

    echo "Fetching the latest Teller release..."
    RELEASE_INFO=$(curl -s https://api.github.com/repos/tellerops/teller/releases/latest)

    # Extract the download URL for the Linux x86_64 tarball
    RELEASE_URL=$(echo "$RELEASE_INFO" | grep "browser_download_url.*_Linux_x86_64.tar.gz" | awk -F\" '"'"'{print $4}'"'"')

    if [ -z "$RELEASE_URL" ]; then
        echo "Failed to find the latest Teller release."
        exit 1
    fi

    echo "Latest Teller release URL: $RELEASE_URL"

    # Define temporary download file
    TEMP_DOWNLOAD=$(mktemp)

    echo "Downloading Teller..."
    curl -L "$RELEASE_URL" --output "$TEMP_DOWNLOAD"

    # Ensure the download was successful
    if [ $? -ne 0 ]; then
        echo "Failed to download Teller."
        rm "$TEMP_DOWNLOAD"
        exit 1
    fi

    # Create a temporary directory for extraction
    TEMP_EXTRACT_DIR=$(mktemp -d)

    # Extract Teller
    tar -xzf "$TEMP_DOWNLOAD" -C "$TEMP_EXTRACT_DIR"

    # Find the Teller binary in the extracted directory
    FOUND_BINARY=$(find "$TEMP_EXTRACT_DIR" -type f -name "teller" -executable)

    if [ -z "$FOUND_BINARY" ]; then
        echo "Failed to find the Teller binary after extraction."
        rm -f "$TEMP_DOWNLOAD"
        rm -rf "$TEMP_EXTRACT_DIR"
        exit 1
    fi

    chmod +x "$FOUND_BINARY"

    # Install the binary using sudo to move it to the target directory
    echo "Installing Teller to $TARGET_DIR..."
    sudo mv "$FOUND_BINARY" "$TARGET_DIR/teller"

    # Validate the move operation
    if [ $? -ne 0 ]; then
        echo "Failed to install Teller."
        exit 1
    fi

    # Cleanup temporary files
    rm -f "$TEMP_DOWNLOAD"
    rm -rf "$TEMP_EXTRACT_DIR"

    echo "Teller has been installed successfully."

    # Confirm Teller installation by checking its version
    if [ -x "$TARGET_DIR/teller" ]; then
        "$TARGET_DIR/teller" version
    else
        echo "Teller command is not available. Check your PATH or installation."
    fi
    )'
fi

# NATS | NK | NSC | NATS-TOP installation
if [ "${NATS_INSTALL}" = "true" ]; then

    sudo -u "${USERNAME}" /bin/bash -c '(
        export GOROOT="/usr/local/go"
        export GOPATH="/go"
        export PATH="/usr/local/go/bin:/go/bin:${PATH}"
        
        echo "Installing nats cli..."
        go install github.com/nats-io/natscli/nats@latest
        
        echo "Installing nats nk..."
        go install github.com/nats-io/nkeys/nk@latest
        
        echo "Installing nats nsc..."
        curl -L https://raw.githubusercontent.com/nats-io/nsc/master/install.py | python3
        
        echo "Installing nats top..."
        go install github.com/nats-io/nats-top@latest
    )'

    echo "Updating PATH in .bashrc and .zshrc..."
    echo 'export PATH="$PATH:${HOME}/.nsccli/bin"' >> ${USERHOME}/.bashrc
    echo 'export PATH="$PATH:${HOME}/.nsccli/bin"' >> ${USERHOME}/.zshrc
    
    # Bash
    /home/${USERNAME}/.nsccli/bin/nsc completion bash > /etc/bash_completion.d/nsc
    # Zsh: assuming .oh-my-zsh is installed for the user
    if [ -d "/home/${USERNAME}/.oh-my-zsh" ]; then
        /home/${USERNAME}/.nsccli/bin/nsc completion zsh > "/home/${USERNAME}/.oh-my-zsh/completions/_nsc"
    fi

    echo "Successfully installed nats tools..."

fi


# Taskfile.dev installation
if [ "${TASK_INSTALL}" = "true" ]; then

    sudo -u "${USERNAME}" /bin/bash -c '(
        export GOROOT="/usr/local/go"
        export GOPATH="/go"
        export PATH="/usr/local/go/bin:/go/bin:${PATH}"
        
        echo "Installing task automation.."
        go install github.com/go-task/task/v3/cmd/task@latest
        
        sudo curl -L https://raw.githubusercontent.com/go-task/task/main/completion/zsh/_task -o /usr/local/share/zsh/site-functions/_task

         echo "Successfully installed task automation.."

    )'

fi


# Install Pulumi tools
if [ "${PULUMI_INSTALL}" = "true" ]; then

    sudo -u "${USERNAME}" /bin/bash -c '(

        echo "Installing pulumi cli..."
        curl -fsSL https://get.pulumi.com | sh
        
        echo "Installing nats esc..."
        curl -fsSL https://get.pulumi.com/esc/install.sh | sh
    )'

    echo "Updating PATH in .bashrc and .zshrc..."
    echo 'export PATH="$PATH:${HOME}/.pulumi/bin"' >> ${USERHOME}/.bashrc
    echo 'export PATH="$PATH:${HOME}/.pulumi/bin"' >> ${USERHOME}/.zshrc
    

    # Zsh: assuming .oh-my-zsh is installed for the user
    if [ -d "/home/${USERNAME}/.oh-my-zsh" ]; then
        /home/${USERNAME}/.pulumi/bin/pulumi gen-completion zsh --color always -e > "/home/${USERNAME}/.oh-my-zsh/completions/_pulumi"
        /home/${USERNAME}/.pulumi/bin/esc completion zsh > "/home/${USERNAME}/.oh-my-zsh/completions/_esc"

    fi

    echo "Successfully installed pulumi tools..."

fi



if ! type docker > /dev/null 2>&1; then
    echo -e '\n(*) Warning: The docker command was not found.\n\nYou can use one of the following scripts to install it:\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker-in-docker.md\n\nor\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker.md'
fi

# Clean up
rm -rf /var/lib/apt/lists/*

echo -e "\nDone!"