<!-- TOC -->

- [Requirements to develop and test the image](#requirements-to-develop-and-test-the-image)
- [General packages](#general-packages)
- [Docker](#docker)
- [mise](#mise)
- [Hadolint, ShellCheck, Kind and Kubectl](#hadolint-shellcheck-kind-and-kubectl)
- [Checking the requirements](#checking-the-requirements)

<!-- TOC -->

# Requirements to develop and test the image

These instructions work on Ubuntu 22.04, 24.04 and 26.04 (amd64) and on macOS (arm64 and amd64). Check it with:

```bash
make check-os
```

# General packages

Install ``git``, ``make`` and ``curl`` in your operating system.

# Docker

Docker builds and tests the image and is not installed by ``mise``. Install it according to your operating system:

- Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- macOS: [Colima](https://github.com/abiosoft/colima) or Docker Desktop

See more details, including the post-installation steps on Linux and the use of Colima on macOS, in the [requirements of the Helm chart](https://github.com/zabbix-community/helm-zabbix/blob/main/charts/zabbix/docs/requirements.md#docker).

# mise

[mise](https://mise.jdx.dev) installs the tools used in this repository, in the versions defined in the [mise.toml](../mise.toml) file:

```bash
curl -fsSL https://mise.run | sh

# bash (default on Ubuntu)
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# zsh (default on macOS)
echo 'eval "$($HOME/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

Documentation: https://mise.jdx.dev/getting-started.html

# Hadolint, ShellCheck, Kind and Kubectl

Run the following commands in the root directory of this repository:

```bash
mise trust
mise install
mise list --current
```

Or install ``mise`` (if needed) and the tools with a single command:

```bash
make install-deps
```

| Tool | Used by | Documentation |
|---|---|---|
| ``hadolint`` | ``make lint`` (Dockerfile) | https://github.com/hadolint/hadolint |
| ``shellcheck`` | ``make lint`` (shell scripts) | https://www.shellcheck.net |
| ``kind`` | ``make kind-load`` | https://kind.sigs.k8s.io |
| ``kubectl`` | tests with the Helm chart | https://kubernetes.io/docs/reference/kubectl/ |

To change a version, edit the ``mise.toml`` file or run ``mise use TOOL@VERSION``.

# Checking the requirements

```bash
make check-deps
```
