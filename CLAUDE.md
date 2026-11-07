# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo builds the image `ghcr.io/zabbix-community/zabbix-server-create-upgrade-db`, the database initialization/upgrade job of the Zabbix Helm chart (`zabbix-community/helm-zabbix`, `charts/zabbix/templates/job-create-upgrade-db.yaml`) when `zabbixServer.zabbixServerHA.enabled=true`. Zabbix Server refuses to create/upgrade the schema in HA mode, so the chart runs this image as a `pre-install,pre-upgrade` hook (Argo CD: `PreSync`) before the Zabbix Server pods. There is no release/tag process: each push to `main` publishes `<major>-<timestamp>` tags.

## Common commands

```bash
make help            # lists all targets
make check-os / check-deps / install-deps
make lint            # shellcheck (scripts) + hadolint (Dockerfile), tools pinned in mise.toml
make build           # zabbix-server-create-upgrade-db:8.0-local (MAJOR_VERSION, BASE_IMAGE, IMAGE_TAG)
make test            # tests/docker-test.sh: Docker + temporary PostgreSQL, no Kubernetes (TEST_SCENARIOS)
make test-upgrade    # upgrade of a schema created by UPGRADE_FROM_IMAGE (default: published 7.4 image)
make kind-load       # loads the local image into the kind cluster of the chart (KIND_CLUSTER_NAME=helm-zabbix)
```

The Kubernetes behavior (install/upgrade detection, scale down, RBAC) can only be tested with the chart in kind, with Helm and with Argo CD: see `docs/local-tests.md` and `charts/zabbix/docs/example/ha/README.md` in the chart repository (`values-local-images.yaml` + `make kind-load` there).

## Architecture

- `Dockerfile`: `FROM zabbix/zabbix-server-pgsql:alpine-<MAJOR_VERSION>-latest` (`BASE_IMAGE` overrides). It keeps the upstream entrypoint up to the `#####...` line (its functions) and appends `docker-entrypoint-run-replace.sh`, then fails the build if a required function is missing.
- Three upstream entrypoint generations must keep working: modular shell (`/usr/lib/docker-entrypoint/*.sh`: 6.0, 7.0, 7.4 → `prepare_database`/`update_config`), monolithic shell (6.4, 7.2 → `prepare_db`/`update_zbx_config`) and compiled Go binary `/usr/bin/docker-entrypoint` (8.0+, no shell entrypoint and no psql). For 8.0+, `docker-entrypoint-compat-binary.sh` provides the shell functions (`psql_query`, `prepare_database` delegating schema creation to `docker-entrypoint init_db_only`, `update_config`) and runs with `set -euo pipefail`, so the appended script must be safe under it (e.g. `|| true` on pipelines closed early by `head`).
- `docker-entrypoint-run-replace.sh` (`init_and_upgrade_db`): compares `dbversion.mandatory` with the version in the image's `create.sql.gz` (8.0+: `/usr/share/doc/zabbix-server-postgresql/postgresql/create.sql.gz`; older: `.../create.sql.gz`). Newer image → scale the deployment down (upgrade mode), run `zabbix_server` until `starting HA manager`, clean standalone rows. Equal → if a standalone node (`name=''`, `status=3`) was seen in the last 60s: scale down + delete rows (upgrade mode) or wait (install mode). See the Mermaid flow in README.md.
- `HELM_HOOK_TYPE=auto` (chart default) detects upgrade mode by the existence of `ZBX_SERVER_DEPLOYMENT_NAME`. Never rely on Helm's `.Release.IsUpgrade`: it is always false under Argo CD (`helm template`), which caused zabbix-community/helm-zabbix#231. Pod selector comes from the deployment's `spec.selector.matchLabels` (`ZBX_SERVER_POD_SELECTOR` overrides). Every wait goes through `wait_for`, bounded by `JOB_WAIT_TIMEOUT` (default 900s); never add an unbounded loop.
- Required RBAC (created by the chart as hooks, `<fullname>-create-upgrade-db`): `deployments` get/list, `deployments/scale` get/update/patch, `pods` get/list. If you need a new API call, update the chart's `templates/role-create-upgrade-db.yaml` too.

## Rules

- Never build a published major version from a pre-release (trunk) image: the schema versions differ (the `8.0-trunk-*` tags are 8.0.0rc2, incompatible with 8.0.0).
- After new images are published, the chart's `zabbixServer.zabbixServerHA.dbCreateUpgradeJob.image.tagSuffix` must be updated to the new timestamp (the chart's CI checks the tag exists).
- Keep README.md (repository structure, Mermaid diagrams, environment variables, RBAC table), CONTRIBUTING.md and this file consistent when changing behavior, files or the build matrix.
- Tool versions live only in `mise.toml`.
