# Multi-monitor Guacamole fork

A maintainable fork of [`abesnier/docker-guacamole`](https://github.com/abesnier/docker-guacamole)
that compiles the **GUACAMOLE-288** multi-monitor RDP feature into a drop-in
image published at `ghcr.io/smdion/guacamole-multimonitor`.

Multi-monitor RDP is not in any released Guacamole build. It lives in two
**unmerged draft PRs**, both by *corentin-soriano* and both **1.6.0-based**:

| Component         | PR | Repo / ref |
|-------------------|----|------------|
| guacamole-server  | [#560](https://github.com/apache/guacamole-server/pull/560)  | `corentin-soriano/guacamole-server` @ `ce23d60` |
| guacamole-client  | [#1061](https://github.com/apache/guacamole-client/pull/1061) | `corentin-soriano/guacamole-client` @ `18d3783` |

They add a `secondary-monitors` RDP connection parameter (integer count of
*extra* monitors beyond the primary; `0` disables).

## Layering strategy (why merges stay clean)

Everything here is **additive** — no upstream file is edited:

```
Dockerfile.multimonitor          # standalone multi-stage build (this fork)
custom/PR_SHAS.env               # single source of truth for versions + PR refs
custom/smoke-test.sh             # publish gate
custom/smoke-compose.yml         # local build/boot convenience
custom/README.multimonitor.md    # this file
.github/workflows/               # upstream has none → no conflicts
```

`Dockerfile.multimonitor` does not `FROM` or patch the stock Dockerfiles; it only
**reuses the upstream `root/` runtime tree** via `COPY root/ /`. So
`git merge upstream/master` rarely conflicts.

## How it differs from the stock noble build

`Dockerfile.github.base.noble` already uses **FreeRDP 3** and already builds
guacamole-server **from git** with `--enable-allow-freerdp-snapshots`, so the
multi-monitor fork stays as close to it as possible and changes only what is
strictly required:

1. **guacamole-server built from PR #560** (`corentin-soriano`) instead of
   `apache/guacamole-server` `main`.
2. **guacamole-client war + extension jars built from PR #1061** via maven
   (stage 1), instead of the externally-prebuilt release war/extensions the stock
   build COPYs from its build context.
3. **PostgreSQL folded into this image** (stock keeps it in a separate
   `Dockerfile.ubuntugithub.pg` layer), so the single image is a drop-in for an
   embedded-Postgres deployment.

Everything else — s6-overlay, LibVNCServer, the FreeRDP symlink, the JDBC
driver, the `/app/guacamole` → `/config` runtime copy, and the `root/` tree —
mirrors the stock noble build.

`GUAC_VER` is **1.6.0** — both PRs are 1.6.0-based (`pom`/`AC_INIT` = 1.6.0), so
the maven-built war and extension jars (`guacamole-auth-sso-openid-1.6.0.jar`, …)
match what `50-extensions` selects.

## CI

- **`build-multimonitor`** — builds from `custom/PR_SHAS.env`, loads the image,
  runs `custom/smoke-test.sh`, and **only on a green smoke** pushes
  `:1.6.0-mm` and `:latest` to GHCR (login via the workflow `GITHUB_TOKEN`).
  The smoke gate boots the container, waits for Tomcat, checks `guacd`, and
  greps the compiled `libguac-client-rdp.so` for `secondary-monitors` — so a
  build that lost the PR fails instead of publishing.
- **`upstream-sync`** — weekly merge of `upstream/master` into `sync/upstream`,
  opening a PR. A merge **conflict fails loudly** (red run); `build-multimonitor`
  re-tests the merged result before it can land.
- **`bump-shas`** — manual dispatch to advance the (force-pushed) PR SHAs; edits
  `PR_SHAS.env` and opens a PR behind the same gate.

## Using the image (separate test — NOT a production repoint)

This image is for **testing multi-monitor separately**; the production
`guacamole` container in homelab-ops stays on `abesnier/guacamole:latest`.

Run it standalone with a throwaway config:

```bash
docker run -d --name guac-mm -p 8085:8080 \
  -e EXTENSIONS=auth-sso-openid \
  ghcr.io/smdion/guacamole-multimonitor:1.6.0-mm
```

The homelab-ops connection sync (`tasks/sync_guacamole_connections.yaml`) already
understands `protocol: rdp` + `secondary_monitors: N` on `host_definitions` /
`container_definitions` / `guacamole_extra_connections`, so once this image is
validated you can point a test deployment at it. `secondary_monitors` is ignored
by the stock build, so the definitions remain safe even before adopting this image.

When you are ready to adopt it in a deployment, repoint that deployment's
`guacamole` entry to `ghcr.io/smdion/guacamole-multimonitor:1.6.0-mm` — but only
after testing, and not the production container unless you explicitly choose to.

## ⚠️ Warning

PRs #560 and #1061 are **unmerged drafts that get force-pushed**. An upstream
sync or a SHA bump can break the build at any time — which is exactly why the
smoke-test gate must block publishing a broken tag.
