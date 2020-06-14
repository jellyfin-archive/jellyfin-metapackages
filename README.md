# Jellyfin Metapackages

This repository contains the various Jellyfin metapackage definitions. With the build split for the 10.6.0 release, the [main server](https://github.com/jellyfin/jellyfin) and [web client](https://github.com/jellyfin/jellyfin-web) are build separately in order to ensure that both of them are unique and there is no built-time cross dependencies between the two repositories. This simplifies building for releases, as well as enables per-PR "unstable" builds as opposed to timed "daily" builds.

## Debian

This is a simple `equivs-build` definition which will build a Debian metapackage for the [`jellyfin-server`](https://github.com/jellyfin/jellyfin) and [`jellyfin-web`](https://github.com/jellyfin/jellyfin-web) `.deb` files.

The version indicator in this file is the invalid placeholder `X.Y.Z`. This must be replaced with a real version at build time, e.g. with `sed -i 's/X.Y.Z/10.6.0/g' jellyfin.debian`.

The package is built with the following command: `equivs-build jellyfin.debian`.

## Docker

This is a simple set of Docker images that combine the [`jellyfin-server`](https://github.com/jellyfin/jellyfin) and [`jellyfin-web`](https://github.com/jellyfin/jellyfin-web) Docker images into one final `jellyfin` image for distribution. They are built in response to the main CI when the per-repository builds are completed.

Changes to the Docker dependencies at runtime should go here; only build-specific changes should go in the main repositories.

There is no version indicator in these Dockerfiles; this is only relevant in the naming when run from CI.

The Dockerfiles are built with the following command `docker build -t jellyfin-{version} --build-arg TARGET_RELEASE=stable -f Dockerfile.{arch} .`, replacing `stable` with `unstable` if required.
