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
indir="${1}"
build_id="${2}"
if [[ "${3}" =~ [Uu]nstable ]]; then
    is_unstable='unstable'
    tag="none"
else
    is_unstable=''
    tag="${3}"
fi

# Abort if we're missing arguments
if [[ -z ${indir} || -z ${build_id} ]]; then
    exit 1
fi

if grep -- '-alpha\|-beta\|-rc' <<<"${tag}"; then
    echo "THIS IS A PRERELEASE; RUN prerelease.sh MANUALLY passing in these arguments: $@" 1>&2
    exit 0
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

# These rely on the naming format jellyin-{type}[-_]{ver}[-_]junk
examplefile="$( find ${indir}/${build_id} -type f \( -name "jellyfin-*.deb" -o -name "jellyfin_*.exe" \) | head -1 )"
servertype="$( awk -F '[_-]' '{ print $2 }' <<<"${examplefile}" )"
version="$( awk -F'[_-]' '{ print $3 }' <<<"${examplefile}" )"

if [[ -z "${version}" ]]; then
    echo "Found no example package for this version, bailing out!"
    exit 1
fi

if [[ -z ${is_unstable} && ${version} =~ "~rc" ]]; then
    echo "This is an RC"
    is_rc="rc"
else
    is_rc=""
fi

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

skip_docker=""

# Debian collection function
do_deb() {
    if [[ -n ${is_rc} ]]; then
        return
    fi

    typename="${1}"
    platform="${typename%.*}"
    case ${platform} in
        debian)
            releases=( ${releases_debian[@]} )
        ;;
        ubuntu)
            releases=( ${releases_ubuntu[@]} )
        ;;
    esac

    repodir="/srv/repository/${platform}"

    if [[ -z ${is_unstable} ]]; then
        component="-C main"
    else
        component="-C unstable"
    fi

    # Reprepro repository
    for release in ${releases[@]}; do
        echo "Importing files into ${release}"
        reprepro -b ${repodir} --export=never --keepunreferencedfiles \
            ${component} \
            includedeb \
            ${release} \
            ${indir}/${build_id}/${typename}/*.deb
    done
    echo "Cleaning and exporting repository"
    reprepro -b ${repodir} deleteunreferenced
    reprepro -b ${repodir} export
    chown -R root:adm ${repodir}
    chmod -R g+w ${repodir}
}

# Static files collection function
do_files() {
    typename="${1}"
    platform="${typename%.*}" # Strip off the architecture
    if [[ ${platform} == 'windows-installer' ]]; then
        platform="windows"
        servertype="installer"
    fi
    filedir="/srv/repository/releases/server/${platform}"

    if [[ -n ${is_unstable} ]]; then
        releasedir="versions/unstable/${servertype}/${version}"
        linkdir="unstable"
    elif [[ -n ${is_rc} ]]; then
        releasedir="versions/stable-rc/${servertype}/${version}"
        linkdir="stable-rc"
    else
        releasedir="versions/stable/${servertype}/${version}"
        linkdir="stable"
    fi

    # Static files
    echo "Creating release directory"
    mkdir -p ${filedir}/${releasedir}
    mkdir -p ${filedir}/${linkdir}
    if [[ -L ${filedir}/${linkdir}/${servertype} ]]; then
        rm -f ${filedir}/${linkdir}/${servertype}
    fi
    ln -s ../${releasedir} ${filedir}/${linkdir}/${servertype}
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

    if [[ -n ${is_unstable} ]]; then
        stability="unstable"
        pkgend="-unstable"
    elif [[ -n ${is_rc} ]]; then
        stability="stable-rc"
        pkgend=""
    else
        stability="stable"
        pkgend=""
    fi
    releasedir="versions/${stability}/${servertype}"
    partnerreleasedir="versions/${stability}/${partnertype}"
    linkdir="${stability}/combined"

    # We must work through all 4 types in linux_static_arches[@]
    for arch in ${linux_static_arches[@]}; do
        case ${servertype} in
            server)
                server_archive="$( find ${filedir}/${releasedir}/${version} -type f -name "jellyfin-${servertype}*${arch}.${filetype}" | head -1 )"
                if [[ -z ${is_unstable} ]]; then
                    web_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*${version}*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                else
                    web_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                fi
                if [[ ! -f ${web_archive} ]]; then
                    continue
                fi
            ;;
            web)
                server_archive="$( find ${filedir}/${partnerreleasedir}/${version} -type f -name "jellyfin-${servertype}*.${filetype}" | head -1 )"
                if [[ -z ${is_unstable} ]]; then
                    web_archive="$( find ${filedir}/${releasedir} -type f -name "*${version}*${arch}.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                else
                    web_archive="$( find ${filedir}/${releasedir} -type f -name "*${arch}.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                fi
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

    if [[ -n ${is_unstable} ]]; then
        stability="unstable"
        pkgend="-unstable"
    elif [[ -n ${is_rc} ]]; then
        stability="stable-rc"
        pkgend=""
    else
        stability="stable"
        pkgend=""
    fi
    releasedir="versions/${stability}/${servertype}"
    partnerreleasedir="versions/${stability}/${partnertype}"
    linkdir="${stability}/combined"

    our_archive="$( find ${filedir}/${releasedir}/${version} -type f -name "jellyfin-${servertype}*.${filetype}" | head -1 )"
    if [[ -z ${is_unstable} ]]; then
        partner_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*${version}*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
    else
        partner_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
    fi

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
    if [[ -L ${filedir}/${linkdir} ]]; then
        rm -f ${filedir}/${linkdir}
    fi
    ln -s ../versions/${stability}/combined/${version} ${filedir}/${linkdir}

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

    if [[ -n ${is_unstable} ]]; then
        releasedir="versions/unstable/meta/${version}"
        linkdir="unstable"
        versend="-unstable"
    elif [[ -n ${is_rc} ]]; then
        releasedir="versions/stable-rc/meta/${version}"
        linkdir="stable-rc"
        versend=""
    else
        releasedir="versions/stable/meta/${version}"
        linkdir="stable"
        versend="-1"
    fi

    if [[ -z ${is_unstable} && -n ${is_rc} ]]; then
        # Check if we're the first one done and abandon this if so (let the last build trigger the metapackage)
        if [[ 
            $( reprepro -b /srv/repository/${platform} -C main list ${codename} jellyfin-web | awk '{ print $NF }' | sort | uniq | grep -F "${version}" | wc -l ) -lt 1
            &&
            $( reprepro -b /srv/repository/${platform} -C main list ${codename} jellyfin-server | awk '{ print $NF }' | sort | uniq | grep -F "${version}" | wc -l ) -lt 1
        ]]; then
            return
        fi

        # For stable releases, fix our dependency to the version
        server_checkstring="(>=${version}-0)"
        web_checkstring="(>=${version}-0)"
        sed -i "s/Depends: jellyfin-server, jellyfin-web/Depends: jellyfin-server ${server_checkstring}, jellyfin-web ${web_checkstring}/g" jellyfin.debian
    fi

    # Check if there's already a metapackage (e.g. this is the second or later arch for this platform)
    if [[ -n ${is_rc} ]]; then
        if [[ $( reprepro -b /srv/repository/${platform} -C main list ${codename} jellyfin | awk '{ print $NF }' | sort | uniq | grep -F "${version}" | wc -l ) -gt 0 ]]; then
            return
        fi
    fi

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

    if [[ -z ${is_rc} ]]; then
        if [[ -z ${is_unstable} ]]; then
            component="-C main"
        else
            component="-C unstable"
        fi

        # Reprepro repository
        for release in ${releases[@]}; do
            echo "Importing files into ${release}"
            reprepro -b ${repodir} --export=never --keepunreferencedfiles \
                ${component} \
                includedeb \
                ${release} \
                ./*.deb
        done
        echo "Cleaning and exporting repository"
        reprepro -b ${repodir} deleteunreferenced
        reprepro -b ${repodir} export
        chown -R root:adm ${repodir}
        chmod -R g+w ${repodir}
    fi

    # Static files
    echo "Creating release directory"
    mkdir -p ${filedir}/${releasedir}
    mkdir -p ${filedir}/${linkdir}
    if [[ -L ${filedir}/${linkdir}/meta ]]; then
        rm -f ${filedir}/${linkdir}/meta
    fi
    ln -s ../${releasedir} ${filedir}/${linkdir}/meta
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

    if [[ -n ${is_rc} ]]; then
        # We have to fix the tag version name because what we have is wrong
        oversion="${version}"
        version="$( sed 's/~rc/-rc/g' <<<"${version}" )"
    fi

    if [[ -n ${is_unstable} ]]; then
        group_tag="unstable"
        release_tag="unstable"
        cversion="${version}-unstable"
    elif [[ -n ${is_rc} ]]; then
        group_tag="stable-rc"
        release_tag="${version}"
        cversion="${version}"
    else
        group_tag="latest"
        release_tag="${version}"
        cversion="${version}"
    fi

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
        docker build --no-cache --pull -f Dockerfile.${arch} -t "${docker_image}":"${cversion}-${arch}" --build-arg TARGET_RELEASE=${release_tag} . &>/var/log/build/docker-combined/${version}.${arch}.log || return &
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

cleanup_unstable() {
    typename="${1}"
    platform="${typename%.*}"
    if [[ -z ${is_unstable} ]]; then
        return
    fi
    filedir="/srv/repository/releases/server/${platform}/versions/unstable"
    find ${filedir} -mindepth 2 -maxdepth 2 -type d -mtime +2 -exec rm -r {} \;
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
            do_deb ${typename}
            do_deb_meta ${typename}
            do_files ${typename}
            cleanup_unstable ${typename}
        ;;
        ubuntu*)
            do_deb ${typename}
            do_deb_meta ${typename}
            do_files ${typename}
            cleanup_unstable ${typename}
        ;;
        fedora*)
            do_files ${typename}
            cleanup_unstable ${typename}
        ;;
        centos*)
            do_files ${typename}
            cleanup_unstable ${typename}
        ;;
        portable)
            do_files ${typename}
            do_combine_portable ${typename}
            cleanup_unstable ${typename}
        ;;
        linux*)
            do_files ${typename}
            do_combine_portable_linux
            cleanup_unstable ${typename}
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
            cleanup_unstable windows # Manual set to avoid override

            # Skip Docker, since this is not a real build
            skip_docker="true"
        ;;
        windows*)
            # Trigger the installer build; this is done here due to convolutions doing it in the CI itself
            #if [[ -n ${is_unstable} ]]; then
            #    echo "Triggering pipeline build for Windows Installer (unstable)"
            #    #az pipelines build queue --organization https://dev.azure.com/jellyfin-project --project jellyfin --definition-id 30 --branch master --variables Trigger="Unstable" 1>&2
            #else
            #    echo "Triggering pipeline build for Windows Installer (stable v${version})"
            #    #az pipelines build queue --organization https://dev.azure.com/jellyfin-project --project jellyfin --definition-id 30 --branch master --variables Trigger="Stable" TagName="v${version}" 1>&2
            #fi

            do_files ${typename}
            do_combine_portable ${typename}
            cleanup_unstable ${typename}
        ;;
        macos*)
            do_files ${typename}
            do_combine_portable ${typename}
            cleanup_unstable ${typename}
        ;;
    esac
done

if [[ -z ${skip_docker} ]]; then
    echo "> Processing docker"
    do_docker_meta
fi

if [[ -f ${indir}/${build_id}/openapi.json ]]; then
    echo "> Processing OpenAPI spec"
    api_root="/srv/repository/releases/openapi"
    if [[ -z ${is_unstable} ]]; then
        api_dir="${api_root}/stable"
        api_version="${version}"
        link_name="jellyfin-openapi-stable"
    else
        api_dir="${api_root}/unstable"
        api_version="${build_id}"
        link_name="jellyfin-openapi-unstable"
    fi
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

# Build unstable plugins
if [[ -n ${is_unstable} ]]; then
    pushd ${repo_dir}
    export JELLYFIN_REPO="/srv/repository/releases/plugin/manifest-unstable.json"
    for plugin in ${plugins_dir}/jellyfin-plugin-*; do
        /srv/jellyfin/build-plugin.sh ${plugin} unstable
        chown -R build:adm ${plugin}
    done
    popd
fi

time_end=$( date +%s )
time_total=$( echo "${time_end} - ${time_start}" | bc )

echo "Finished at $( date ) in ${time_total} seconds" 1>&1
echo "Finished at $( date ) in ${time_total} seconds" 1>&2

) 300>/var/log/collect-server.lock

rm /var/log/collect-server.lock
exit 0
