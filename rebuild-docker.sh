#!/usr/bin/env bash

# Jellyfin Azure builds collection script
# Parses the artifacts uploaded from an Azure build and puts them into place, as well as building the various metapackages, metaarchives, and Docker metaimages.

logfile="/var/log/build/collect-server.log"
exec 2>>${logfile}
#exec 1>>${logfile}
#exec 3>&1

# Ensure we're running as root (i.e. sudo $0)
if [[ $( whoami ) != 'root' ]]; then
    echo "Script must be run as root"
fi

# Get our input arguments
echo ${0} ${@} 1>&2
version="${1}"
posttag="${2}"

# Abort if we're missing arguments
if [[ -z ${version} || -z ${posttag} ]]; then
    echo "Usage: $0 [current version e.g. 10.8.4] [supplemental post tag e.g. 1, 2, etc.]"
    exit 1
fi

(

# Acquire an exclusive lock so multiple simultaneous builds do not override each other
flock -x 300

time_start=$( date +%s )

# Static variables
repo_dir="/srv/jellyfin"
linux_static_arches=(
    "amd64"
    "amd64-musl"
    "arm64"
    "armhf"
)
docker_arches=(
    "amd64"
    "arm64"
    "armhf"
)

echo "**********" 1>&2
date 1>&2
echo "**********" 1>&2

set -o xtrace

# Ensure Metapackages repo is cloned and up-to-date
echo "Ensuring metapackages repo is up to date"
pushd ${repo_dir} 1>&2
./build.py --clone-only jellyfin-metapackages 1>&2
popd 1>&2
pushd ${metapackages_dir} 1>&2
git checkout master 1>&2
git fetch --all 1>&2
git stash 1>&2
git pull --rebase 1>&2
popd 1>&2

# Docker Metaimage function
do_docker_meta() {
    pushd ${metapackages_dir} 1>&2

    group_tag="latest"
    release_tag="${version}"
    cversion="${version}-${posttag}"

    # During a real release, we must check that both builder images are up; if one isn't, we're the first one done (or it failed), so return
    if [[ -z ${is_unstable} ]]; then
        server_ok=""
        web_ok=""
        for arch in ${docker_arches[@]}; do
            curl --silent -f -lSL https://index.docker.io/v1/repositories/jellyfin/jellyfin-server/tags/${version}-${arch} >/dev/null && server_ok="${server_ok}y"
        done
        curl --silent -f -lSL https://index.docker.io/v1/repositories/jellyfin/jellyfin-web/tags/${version} >/dev/null && web_ok="y"
        if [[ ${server_ok} != "yyy" || ${web_ok} != "y" ]]; then
            return
        fi
    fi


    # Enable Docker experimental features (manifests)
    export DOCKER_CLI_EXPERIMENTAL=enabled

    echo "Building combined Docker images"

    docker_image="jellyfin/jellyfin"

    docker login 1>&2

    # Prepare the QEMU image
    docker run --rm --privileged multiarch/qemu-user-static:register --reset 1>&2

    # Prepare log dir
    mkdir -p /var/log/build/docker-combined

    for arch in ${docker_arches[@]}; do
        echo "Building Docker image for ${arch}"
        # Build the image
        docker build --no-cache --pull -f Dockerfile.${arch} -t "${docker_image}":"${cversion}-${arch}" --build-arg TARGET_RELEASE=${release_tag} . &>/var/log/build/docker-combined/${cversion}.${arch}.log || return &
    done
    # All images build in parallel in the background; wait for them to finish
    # This minimizes the amount of time that an alternative Docker image could be uploaded,
    # thus resulting in inconsistencies with these images. By doing these in parallel they
    # grap upstream as soon as possible then can take as long as they need.
    echo -n "Waiting for docker builds..."
    while [[ $( ps aux | grep '[d]ocker build' | wc -l ) -gt 0 ]]; do
        sleep 15
        echo -n "."
    done
    echo " done."

    # Push the images
    for arch in ${docker_arches[@]}; do
        echo "Pushing Docker image for ${arch}"
        docker push "${docker_image}":"${cversion}-${arch}" 1>&2
    done

    # Create the manifests
    echo "Creating Docker image manifests"
    for arch in ${docker_arches[@]}; do
        image_list_cversion="${image_list_cversion} ${docker_image}:${cversion}-${arch}"
        image_list_grouptag="${image_list_grouptag} ${docker_image}:${cversion}-${arch}"
    done

    docker manifest create --amend "${docker_image}":"${cversion}" ${image_list_cversion} 1>&2
    docker manifest create --amend "${docker_image}":"${group_tag}" ${image_list_grouptag} 1>&2

    # Push the manifests
    echo "Pushing Docker image manifests"
    docker manifest push --purge "${docker_image}":"${cversion}" 1>&2
    docker manifest push --purge "${docker_image}":"${group_tag}" 1>&2

    # Remove images
    for arch in ${docker_arches[@]}; do
        echo "Removing pushed docker image for ${arch}"
        docker image rm "${docker_image}":"${cversion}-${arch}" 1>&2
    done
    docker image prune --force 1>&2

    find /var/log/build/docker-combined -mtime +7 -exec rm {} \;

    popd 1>&2

    if [[ -n ${is_rc} ]]; then
        # Restore the original version variable
        version="${oversion}"
    fi
}

echo "> Processing docker"
do_docker_meta

time_end=$( date +%s )
time_total=$( echo "${time_end} - ${time_start}" | bc )

echo "Finished at $( date ) in ${time_total} seconds" 1>&1
echo "Finished at $( date ) in ${time_total} seconds" 1>&2

) 300>/var/log/collect-server.lock

rm /var/log/collect-server.lock
exit 0
