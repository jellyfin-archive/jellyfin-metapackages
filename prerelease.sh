#!/usr/bin/env bash

# Jellyfin Azure builds collection script
# Parses the artifacts uploaded from an Azure build and puts them into place, as well as building the various metapackages, metaarchives, and Docker metaimages.

#logfile="/var/log/build/collect-server.log"
#exec 2>>${logfile}

# Ensure we're running as root (i.e. sudo $0)
if [[ $( whoami ) != 'root' ]]; then
    echo "Script must be run as root"
fi

# Get our input arguments
echo ${0} ${@} 1>&2
indir="${1}"
build_id="${2}"
version="${3}"

# Abort if we're missing arguments
if [[ -z ${indir} || -z ${build_id} || -z ${version} ]]; then
    exit 1
fi

(

# Acquire an exclusive lock so multiple simultaneous builds do not override each other
flock -x 300

time_start=$( date +%s )

# Static variables
repo_dir="/srv/jellyfin"
metapackages_dir="${repo_dir}/projects/server/jellyfin-metapackages"
plugins_dir="${repo_dir}/projects/plugin/"
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
releases_debian=(
    "stretch"
    "buster"
    "bullseye"
)
releases_ubuntu=(
    "xenial"
    "bionic"
    "focal"
    "groovy"
)

echo "**********" 1>&2
date 1>&2
echo "**********" 1>&2

set -o xtrace

examplefile="$( find ${indir}/${build_id} -type f \( -name "jellyfin-*.deb" -o -name "jellyfin_*.exe" \) | head -1 )"
servertype="$( awk -F '[_-]' '{ print $2 }' <<<"${examplefile}" )"
echo "Servertype: ${servertype}"

# Static files collection function
do_files() {
    typename="${1}"
    platform="${typename%.*}" # Strip off the architecture
    if [[ ${platform} == 'windows-installer' ]]; then
        platform="windows"
        servertype="installer"
    fi
    filedir="/srv/repository/releases/server/${platform}"

    releasedir="versions/stable-pre/${servertype}/${version}"
    linkdir="stable-pre"

    # Static files
    echo "Creating release directory"
    mkdir -p ${filedir}/${releasedir}
    mkdir -p ${filedir}/${linkdir}/${version}
    if [[ -L ${filedir}/${linkdir}/${version}/${servertype} ]]; then
        rm -f ${filedir}/${linkdir}/${version}/${servertype}
    fi
    ln -s ../../${releasedir} ${filedir}/${linkdir}/${version}/${servertype}
    echo "Copying files"
    mv ${indir}/${build_id}/${typename}/* ${filedir}/${releasedir}/
    echo "Creating sha256sums"
    for file in ${filedir}/${releasedir}/*; do
        if [[ ${file} =~ ".sha256sum" ]]; then
            continue
        fi
        sha256sum ${file} | sed 's, .*/, ,' > ${file}.sha256sum
    done
    echo "Cleaning repository"
    chown -R root:adm ${filedir}
    chmod -R g+w ${filedir}
}

# Portable Linux (multi-arch) combination function
# Static due to the requirement to do 4 architectures
do_combine_portable_linux() {
    platform="linux"
    case ${servertype} in
        server)
            partnertype="web"
            filedir="/srv/repository/releases/server/${platform}"
        ;;
        web)
            partnertype="server"
            filedir="/srv/repository/releases/server/${platform}"
        ;;
    esac

    filetype="tar.gz"

    stability="stable-pre"
    pkgend=""

    releasedir="versions/${stability}/${servertype}"
    partnerreleasedir="versions/${stability}/${partnertype}"
    linkdir="${stability}/${version}/combined"

    mkdir -p ${filedir}/versions/${stability}/combined/${version}

    # We must work through all 4 types in linux_static_arches[@]
    for arch in ${linux_static_arches[@]}; do
        case ${servertype} in
            server)
                server_archive="$( find ${filedir}/${releasedir}/${version} -type f -name "jellyfin-server*-${arch}.${filetype}" | head -1 )"
                web_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "jellyfin-web*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                if [[ ! -f ${web_archive} ]]; then
                    continue
                fi
            ;;
            web)
                server_archive="$( find ${filedir}/${partnerreleasedir}/${version} -type f -name "jellyfin-server*-${arch}.${filetype}" | head -1 )"
                web_archive="$( find ${filedir}/${releasedir} -type f -name "jellyfin-web*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                if [[ ! -f ${server_archive} ]]; then
                    continue
                fi
            ;;
        esac

        tempdir=$( mktemp -d )

        echo "Unarchiving server archive"
        tar -xzf ${server_archive} -C ${tempdir}/

        echo "Correcting root directory naming"
        pushd ${tempdir} 1>&2
        server_dir="$( find . -maxdepth 1 -type d -name "jellyfin-server_*" | head -1 )"
        mv ${server_dir} ./jellyfin_${version}
        popd 1>&2

        echo "Unarchiving web archive"
        tar -xzf ${web_archive} -C ${tempdir}/jellyfin_${version}/

        echo "Correcting web directory naming"
        pushd ${tempdir}/jellyfin_${version}/ 1>&2
        web_dir="$( find . -maxdepth 1 -type d -name "jellyfin-web_*" | head -1 )"
        mv ${web_dir} jellyfin-web
        popd 1>&2

        echo "Creating combined tar archive"
        pushd ${tempdir} 1>&2
        chown -R root:root ./
        tar -czf ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz ./
        echo "Creating sha256sums"
        sha256sum ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz | sed 's, .*/, ,' > ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz.sha256sum
        popd 1>&2

        rm -rf ${tempdir}
    done

    echo "Creating links"
    if [[ -e ${filedir}/${linkdir} ]]; then
        rm -rf ${filedir}/${linkdir}
    fi
    ln -s ../../versions/${stability}/combined/${version} ${filedir}/${linkdir}
}

# Portable archive combination function
do_combine_portable() {
    typename="${1}"
    platform="${typename%.*}"
    case ${servertype} in
        server)
            partnertype="web"
            filedir="/srv/repository/releases/server/${platform}"
        ;;
        web)
            partnertype="server"
            filedir="/srv/repository/releases/server/${platform}"
        ;;
    esac

    if [[ ${platform} == "windows" ]]; then
        filetype="zip"
    else
        filetype="tar.gz"
    fi

    stability="stable-pre"
    pkgend=""

    releasedir="versions/${stability}/${servertype}"
    partnerreleasedir="versions/${stability}/${partnertype}"
    linkdir="${stability}/${version}/combined"

    our_archive="$( find ${filedir}/${releasedir}/${version} -type f -name "jellyfin-${servertype}*.${filetype}" | head -1 )"
    partner_archive="$( find ${filedir}/${partnerreleasedir}/${version} -type f -name "jellyfin-*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"

    if [[ ! -f ${partner_archive} ]]; then
        return
    fi

    tempdir=$( mktemp -d )
    case ${servertype} in
        server)
            server_archive="${our_archive}"
            web_archive="${partner_archive}"
        ;;
        web)
            server_archive="${partner_archive}"
            web_archive="${our_archive}"
        ;;
    esac

    echo "Unarchiving server archive"
    if [[ ${filetype} == "zip" ]]; then
        unzip ${server_archive} -d ${tempdir}/ &>/dev/null
    else
        tar -xzf ${server_archive} -C ${tempdir}/
    fi

    echo "Correcting root directory naming"
    pushd ${tempdir} 1>&2
    server_dir="$( find . -maxdepth 1 -type d -name "jellyfin-server_*" | head -1 )"
    mv ${server_dir} ./jellyfin_${version}
    popd 1>&2

    echo "Unarchiving web archive"
    if [[ ${filetype} == "zip" ]]; then
        unzip ${web_archive} -d ${tempdir}/jellyfin_${version}/ &>/dev/null
    else
        tar -xzf ${web_archive} -C ${tempdir}/jellyfin_${version}/
    fi

    echo "Correcting web directory naming"
    pushd ${tempdir}/jellyfin_${version}/ 1>&2
    web_dir="$( find . -maxdepth 1 -type d -name "jellyfin-web_*" | head -1 )"
    mv ${web_dir} jellyfin-web
    popd 1>&2

    pushd ${tempdir} 1>&2
    mkdir -p ${filedir}/versions/${stability}/combined/${version}
    if [[ ${filetype} == "zip" ]]; then
        echo "Creating combined zip archive"
        chown -R root:root ./
        zip -r ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.zip ./* &>/dev/null
        echo "Creating sha256sums"
        sha256sum ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.zip | sed 's, .*/, ,' > ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.zip.sha256sum
    else
        echo "Creating combined tar archive"
        chown -R root:root ./
        tar -czf ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.tar.gz ./
        echo "Creating sha256sums"
        sha256sum ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.tar.gz | sed 's, .*/, ,' > ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}.tar.gz.sha256sum
    fi
    popd 1>&2
    
    echo "Creating links"
    if [[ -e ${filedir}/${linkdir} ]]; then
        rm -rf ${filedir}/${linkdir}
    fi
    ln -s ../../versions/${stability}/combined/${version} ${filedir}/${linkdir}

    echo "Cleaning up"
    rm -rf ${tempdir}
}

# Debian Metapackage function
do_deb_meta() {
    typename="${1}"
    platform="${typename%.*}"
    pushd ${metapackages_dir} 1>&2

    case ${platform} in
        debian)
            codename="buster"
        ;;
        ubuntu)
            codename="bionic"
        ;;
    esac
    
    filedir="/srv/repository/releases/server/${platform}"

    releasedir="versions/stable-pre/meta/${version}"
    linkdir="stable-pre"
    versend=""

    sed -i "s/X.Y.Z/${version}${versend}/g" jellyfin.debian

    echo "Building metapackage"
    equivs-build jellyfin.debian 1>&2

    case ${platform} in
        debian)
            release=( ${releases_debian[@]} )
        ;;
        ubuntu)
            release=( ${releases_ubuntu[@]} )
        ;;
    esac

    repodir="/srv/repository/${platform}"

    # Static files
    echo "Creating release directory"
    mkdir -p ${filedir}/${releasedir}
    mkdir -p ${filedir}/${linkdir}/${version}
    if [[ -L ${filedir}/${linkdir}/${version}/meta ]]; then
        rm -f ${filedir}/${linkdir}/${version}/meta
    fi
    ln -s ../../${releasedir} ${filedir}/${linkdir}/${version}/meta

    echo "Copying files"
    mv ./*.deb ${filedir}/${releasedir}/
    echo "Creating sha256sums"
    for file in ${filedir}/${releasedir}/*.deb; do
        if [[ ${file} =~ "*.sha256sum" ]]; then
            continue
        fi
        sha256sum ${file} | sed 's, .*/, ,' > ${file}.sha256sum
    done
    echo "Cleaning repository"
    chown -R root:adm ${filedir}
    chmod -R g+w ${filedir}

    # Clean up our changes
    git checkout jellyfin.debian

    popd 1>&2
}

# Docker Metaimage function
do_docker_meta() {
    pushd ${metapackages_dir} 1>&2

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

    # We're in a stable or rc build, and this image already exists, so abort
    if curl --silent -f -lSL https://index.docker.io/v1/repositories/jellyfin/jellyfin/tags/${version} >/dev/null; then
        return
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
        docker build --no-cache --pull -f Dockerfile.${arch} -t "${docker_image}":"${version}-${arch}" --build-arg TARGET_RELEASE=${version} . &>/var/log/build/docker-combined/${version}.${arch}.log &
    done

    # All images build in parallel in the background; wait for them to finish
    # This minimizes the amount of time that an alternative Docker image could be uploaded,
    # thus resulting in inconsistencies with these images. By doing these in parallel they
    # grap upstream as soon as possible then can take as long as they need.
    echo -n "Waiting for docker builds..."
    wait

    # Push the images
    for arch in ${docker_arches[@]}; do
        echo "Pushing Docker image for ${arch}"
        docker push "${docker_image}":"${version}-${arch}" 1>&2
    done

    # Create the manifests
    echo "Creating Docker image manifests"
    for arch in ${docker_arches[@]}; do
        image_list_version="${image_list_version} ${docker_image}:${version}-${arch}"
        image_list_grouptag="${image_list_grouptag} ${docker_image}:${version}-${arch}"
    done

    docker manifest create --amend "${docker_image}":"${version}" ${image_list_version} 1>&2

    # Push the manifests
    echo "Pushing Docker image manifests"
    docker manifest push --purge "${docker_image}":"${version}" 1>&2

    # Remove images
    for arch in ${docker_arches[@]}; do
        echo "Removing pushed docker image for ${arch}"
        docker image rm "${docker_image}":"${version}-${arch}" 1>&2
    done
    docker image prune --force 1>&2

    find /var/log/build/docker-combined -mtime +7 -exec rm {} \;

    popd 1>&2

    if [[ -n ${is_rc} ]]; then
        # Restore the original version variable
        version="${oversion}"
    fi
}


# For web, which does not build every platform, make copies so we parse sanely later
if [[ ${servertype} == 'web' ]]; then
    if [[ ! -d ${indir}/${build_id}/ubuntu ]]; then
        cp -a ${indir}/${build_id}/debian ${indir}/${build_id}/ubuntu
        rmdir ${indir}/${build_id}/ubuntu/portable
    fi
    if [[ ! -d ${indir}/${build_id}/macos ]]; then
        cp -a ${indir}/${build_id}/portable ${indir}/${build_id}/macos
        rmdir ${indir}/${build_id}/macos/portable
    fi
    if [[ ! -d ${indir}/${build_id}/linux ]]; then
        cp -a ${indir}/${build_id}/portable ${indir}/${build_id}/linux
        rmdir ${indir}/${build_id}/linux/portable
    fi
    if [[ ! -d ${indir}/${build_id}/windows ]]; then
        cp -a ${indir}/${build_id}/portable ${indir}/${build_id}/windows
        rmdir ${indir}/${build_id}/windows/portable
        # Convert the .tar.gz archive to a .zip archive for consistency
        for filename in $( find ${indir}/${build_id}/windows/ -name "*.tar.gz" ); do
            archive_tempdir=$( mktemp -d )
            fbasename="$( basename ${filename} .tar.gz )"
            pushd ${archive_tempdir} 1>&2
            tar -xzf ${filename} -C ./
            chown -R root:root ./
            zip -r ${indir}/${build_id}/windows/${fbasename}.zip ./* &>/dev/null
            popd 1>&2
            rm -r ${archive_tempdir}
            rm ${filename}
        done
    fi
fi

# Main loop
for directory in ${indir}/${build_id}/*; do
    typename="$( awk -F'/' '{ print $NF }' <<<"${directory}" )"
    echo "> Processing $typename"
    case ${typename} in
        debian*)
            do_files ${typename}
            do_deb_meta ${typename}
        ;;
        ubuntu*)
            do_files ${typename}
            do_deb_meta ${typename}
        ;;
        fedora*)
            do_files ${typename}
        ;;
        centos*)
            do_files ${typename}
        ;;
        portable)
            do_files ${typename}
            do_combine_portable ${typename}
        ;;
        linux*)
            do_files ${typename}
        ;;
        windows-installer*)
            # Modify the version info of the package if unstable
            if [[ -n ${is_unstable} ]]; then
                echo "Renaming Windows installer file to unstable version name"
                pushd ${indir}/${build_id}/${typename} 1>&2
                # Correct the version
                mmv "jellyfin_*_windows-x64.exe" "jellyfin_${build_id}-unstable_x64.exe" 1>&2
                # Redo the version
                version="${build_id}"
                popd 1>&2
            fi

            do_files ${typename}

            # Skip Docker, since this is not a real build
            skip_docker="true"
        ;;
        windows*)
            do_files ${typename}
            do_combine_portable ${typename}
        ;;
        macos*)
            do_files ${typename}
            do_combine_portable ${typename}
        ;;
    esac
done

echo "> Processing portable Linux"
do_combine_portable_linux

echo "> Processing docker"
do_docker_meta

if [[ -f ${indir}/${build_id}/openapi.json ]]; then
    echo "> Processing OpenAPI spec"
    api_root="/srv/repository/releases/openapi"

    api_dir="${api_root}/stable-pre"
    api_version="${version}"
    link_name="jellyfin-openapi-stable-pre"

    mkdir -p ${api_dir}
    if ! diff -q ${indir}/${build_id}/openapi.json ${api_root}/${link_name}.json &>/dev/null; then
        # Only replace the OpenAPI spec if they differ
        mv ${indir}/${build_id}/openapi.json ${api_dir}/jellyfin-openapi-${api_version}.json
        if [[ -L ${api_root}/${link_name}.json ]]; then
            rm -f ${api_root}/${link_name}_previous.json
            mv ${api_root}/${link_name}.json ${api_root}/${link_name}_previous.json
        fi
        ln -s ${api_dir}/jellyfin-openapi-${api_version}.json ${api_root}/${link_name}.json
    fi
fi

# Cleanup
rm -r ${indir}/${build_id}

# Run mirrorbits refresh
mirrorbits refresh

time_end=$( date +%s )
time_total=$( echo "${time_end} - ${time_start}" | bc )

echo "Finished at $( date ) in ${time_total} seconds" 1>&1
echo "Finished at $( date ) in ${time_total} seconds" 1>&2

) 300>/var/log/collect-server.lock

rm /var/log/collect-server.lock
exit 0
