# dev-base

The layer every dev container here was building for itself. Debian, a locale, a toolbox of about twenty packages, Docker outside of Docker, the `dev` user with `doas`, and the scripts that were duplicated in each repository.

A repository builds on this rather than on `debian:13`, then adds the toolchain it needs:

```dockerfile
ARG USER="dev"

FROM h3nc4/dev-base:debian-13@sha256:... AS main
USER root
# node, rust, go, the Android SDK, whatever this repository is for

FROM scratch AS final
ARG USER
ENV USER="${USER}"
COPY --from=main / /
USER "${USER}"
```

`USER root` has to come before anything that installs, because this image ends as `dev`.

`ARG USER="dev"` has to keep the name `dev`, because this image already created that user. A final stage that calls the user after the repository instead fails to start, with `unable to find user`.

A toolchain that adds to `PATH` keeps it across the UID remap, so `/usr/local/go/bin` still resolves after the entrypoint re-executes.

## What it provides

| path | what it is |
| --- | --- |
| `/usr/local/bin/entrypoint.sh` | the `ENTRYPOINT`. It remaps the container user onto the host's UID and GID and corrects the docker group, then points `core.hooksPath` at `scripts/hooks` and runs `scripts/dev-init.sh` when the repository has one |
| `/usr/local/bin/switch-user.sh` | the helper that remap re-executes through |
| `/usr/local/bin/sonar` | the SonarQube scan, which a `pre-push` hook and `h3nc4/sonar-action` both call |
| the `dev` user | one name for every repository, since a prebuilt image bakes the user it creates |

## Left in each repository

Its toolchain, its hooks under `scripts/hooks`, and `scripts/dev-init.sh` for the one or two lines of setup that are its own, such as `npm install` or `go mod download`. `devcontainer-init.sh` and `devcontainer-image.sh` also stay, because both run on the host before a container exists. `initializeCommand` calls the first, and CI reads the second to learn which image to pull.

## Run it

```sh
docker run --rm -it \
  -e "HOST_UID_GID=$(id -u):$(id -g)" \
  -v "${PWD}:/workspaces/$(basename "${PWD}")" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  h3nc4/dev-base:debian-13 bash
```

The entrypoint finds the repository under `/workspaces` rather than being told its name, so one image serves every repository. `WORKSPACE` overrides that when more than one is mounted.

## Versioning

The tag is the Debian the image is built on, read out of the `FROM` line, so `debian-13` today. Changing the scripts or the toolbox rebuilds that tag and moves its digest. Consumers pin the digest, so Renovate raises the bump in each repository. Upgrading Debian across a major renames the tag instead, which puts that migration in front of a reader rather than advancing a number quietly. There is no `latest`, because a consumer following it would cross a Debian major without noticing.

GPL-3.0.
