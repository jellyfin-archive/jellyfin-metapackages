#!/usr/bin/env bash

set -o xtrace

version="${1}"

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
releases_debian=( $( grep Codename /srv/repository/debian/conf/distributions | awk '{ print $NF }' ) )
releases_ubuntu=( $( grep Codename /srv/repository/ubuntu/conf/distributions | awk '{ print $NF }' ) )

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
                web_archive="$( find ${filedir}/${releasedir}/${version} -type f -name "jellyfin-${servertype}*.${filetype}" | head -1 )"
                if [[ -z ${is_unstable} ]]; then
                    server_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*${version}*${arch}.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
                else
                    server_archive="$( find ${filedir}/${partnerreleasedir} -type f -name "*${arch}.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
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
        mkdir -p ${filedir}/versions/${stability}/combined/${version}/
        tar -czf ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz ./
        echo "Creating sha256sums"
        sha256sum ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz | sed 's, .*/, ,' > ${filedir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkgend}_${arch}.tar.gz.sha256sum
        popd 1>&2

        rm -rf ${tempdir}
    done

}

servertype=server
do_combine_portable_linux
