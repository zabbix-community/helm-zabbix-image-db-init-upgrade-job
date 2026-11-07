<!-- TOC -->

- [Contributing](#contributing)
  - [For code maintainers only](#for-code-maintainers-only)
- [About Visual Code (VSCode)](#about-visual-code-vscode)

<!-- TOC -->

# Contributing

- Configure authentication on your Github account to use the SSH protocol instead of HTTP. Watch this tutorial to learn how to set up: https://help.github.com/en/github/authenticating-to-github/adding-a-new-ssh-key-to-your-github-account
- Install the [requirements](docs/requirements.md): ``make``, ``docker`` and the tools of the ``mise.toml`` file.
- Create a fork this repository.
- Clone the forked repository to your local system:

```bash
git clone FORKED_REPOSITORY
```

- Add the address for the remote original repository:

```bash
git remote -v
git remote add upstream git@github.com:zabbix-community/helm-zabbix-image-db-init-upgrade-job.git
git remote -v
```

- Create a branch. Example:

```bash
git checkout -b BRANCH_NAME
```

- Make sure you are on the correct branch using the following command. The branch in use contains the '*' before the name.

```bash
git branch
```

- Make your changes and tests to the new branch. Keep in mind:
  - The image supports several Zabbix major versions, whose upstream entrypoints are different: a modular shell entrypoint (6.0, 7.0, 7.4), a monolithic one (6.4, 7.2) and a compiled one (8.0 and newer). Test the major versions affected by your change with ``make build MAJOR_VERSION=X.Y`` and ``make test MAJOR_VERSION=X.Y``.
  - Changes in the behavior in Kubernetes (Kubernetes API, scale down of Zabbix Server) must be tested with the [Helm chart](https://github.com/zabbix-community/helm-zabbix) in kind, with Helm and with Argo CD. See [docs/local-tests.md](docs/local-tests.md).
- Run the lint and the tests:

```bash
make lint
make build
make test
make test-upgrade
```

Run ``make help`` to list all available ``make`` targets with a short description of each.

- Commit the changes to the branch.
- Push files to repository remote with command:

```bash
git push --set-upstream origin BRANCH_NAME
```

- Create Pull Request (PR) to the `main` branch. See this [tutorial](https://help.github.com/en/github/collaborating-with-issues-and-pull-requests/creating-a-pull-request-from-a-fork)
- Update the content with the suggestions of the reviewer (if necessary).
- After your pull request is merged to the `main` branch, update your local clone:

```bash
git checkout main
git pull upstream main
```

- Clean up after your pull request is merged with command:

```bash
git branch -d BRANCH_NAME
```

- Then you can update the ``main`` branch in your forked repository.

```bash
git push origin main
```

- And push the deletion of the feature branch to your GitHub repository with command:

```bash
git push --delete origin BRANCH_NAME
```

- To keep your fork in sync with the original repository, use these commands:

```bash
git pull upstream main
git push origin main
```

References:

- https://blog.scottlowe.org/2015/01/27/using-fork-branch-git-workflow/

## For code maintainers only

There are no releases or git tags in this repository. Each push to the ``main`` branch that changes the image (documentation-only changes are ignored) runs the [docker.build.yml](.github/workflows/docker.build.yml) workflow, which builds the images for ``linux/amd64`` and ``linux/arm64`` and publishes the tags ``<major version>-<timestamp>`` of all the Zabbix major versions of the matrix, with the same timestamp. The workflow can also be started manually (``workflow_dispatch``), e.g. to rebuild the images with the latest base images.

To publish new images:

- Review and merge the pull requests.
- Wait for the ``Docker Build and Push`` workflow and get the timestamp of the new tags in https://github.com/zabbix-community/helm-zabbix-image-db-init-upgrade-job/pkgs/container/zabbix-server-create-upgrade-db
- When a new Zabbix major version is released, add it to the ``major_version`` list of the matrix of the workflow. Use the released image, never a pre-release (trunk) image: their schema versions are different.
- In the [Helm chart](https://github.com/zabbix-community/helm-zabbix), update ``zabbixServer.zabbixServerHA.dbCreateUpgradeJob.image.tagSuffix`` in ``charts/zabbix/values.yaml`` with the new timestamp, test the chart and release a new version of it. The ``lint`` job of the CI of the chart fails if the tag is not published.

# About Visual Code (VSCode)

Use a IDE (Integrated Development Environment) or text editor of your choice. By default, the use of VSCode is recommended.

Plugins to Visual Code:

- docker: https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker (require docker-ce package)
- gitlens: https://marketplace.visualstudio.com/items?itemName=eamodio.gitlens (require git package)
- hadolint: https://marketplace.visualstudio.com/items?itemName=exiasr.hadolint (require hadolint)
- Markdown-all-in-one: https://marketplace.visualstudio.com/items?itemName=yzhang.markdown-all-in-one
- Markdown-lint: https://marketplace.visualstudio.com/items?itemName=DavidAnson.vscode-markdownlint
- shellcheck: https://marketplace.visualstudio.com/items?itemName=timonwong.shellcheck (require shellcheck package)
- YAML: https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml
