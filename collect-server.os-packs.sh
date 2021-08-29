#!/usr/bin/env bash

# Jellyfin OS package builds collection script
# Parses the artifacts uploaded from CI build and puts them into place, as well as building the various meta-packages and meta-archives

logfile="/var/log/build/os-pack.log"
exec 2>>${logfile}

# Ensure we're running as root (i.e. sudo $0)
if [[ $( whoami ) != 'root' ]]; then
    echo "Script must be run as root"
fi

time_start=$( date +%s )

# Static variables
repo_dir="/srv/jellyfin"
metapackages_dir="${repo_dir}/projects/server/jellyfin-metapackages"
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

# Get our input arguments
echo ${0} ${@} 1>&2
in_dir="${1}"
build_id="${2}"
version="${3}"
stage="${4}"
artifact_type="${5}"

if [[ "${stage}" =~ [Uu]nstable ]]; then
    is_unstable='unstable'
else
    is_unstable=''
fi

# Abort if we're missing arguments
if [[ -z ${in_dir} || -z ${build_id} || -z ${version} || -z ${stage} || -z ${artifact_type} ]]; then
  echo "One or more of the required script parameters is missing!"
  exit 1
fi

if [[ ${stage} =~ [Ss]table && ${version} =~ "-rc" ]]; then
    echo "This is an RC"
    is_rc="rc"
else
    is_rc=""
fi

do_deb() {
  if [[ -n ${is_rc} ]]; then
    return
  fi

  platform_arch="${1}"
  platform="${platform_arch%.*}"
  case ${platform} in
    debian)
      releases=( ${releases_debian[@]} )
    ;;
    ubuntu)
      releases=( ${releases_ubuntu[@]} )
    ;;
  esac

  repo_dir="/srv/repository/${platform}"

  if [[ -z ${is_unstable} ]]; then
    component="-C main"
  else
    component="-C unstable"
  fi

  # Reprepro repository
  for release in ${releases[@]}; do
    echo "Importing files into ${release}"
    reprepro -b ${repo_dir} --export=never --keepunreferencedfiles \
      ${component} \
      includedeb \
      ${release} \
      ${in_dir}/${build_id}/${platform_arch}/*.deb
  done
  echo "Cleaning and exporting repository"
  reprepro -b ${repo_dir} deleteunreferenced
  reprepro -b ${repo_dir} export
  chown -R root:adm ${repo_dir}
  chmod -R g+w ${repo_dir}
}

# Static files collection function
do_files() {
  platform_arch="${1}"
  platform="${platform_arch%.*}" # Strip off the architecture
  if [[ ${platform} == 'windows-installer' ]]; then
    platform="windows"
    artifact_type="installer"
  fi
  file_dir="/srv/repository/releases/server/${platform}"

  if [[ -n ${is_unstable} ]]; then
    release_dir="versions/unstable/${artifact_type}/${version}"
    link_dir="unstable"
  elif [[ -n ${is_rc} ]]; then
    release_dir="versions/stable-rc/${artifact_type}/${version}"
    link_dir="stable-rc"
  else
    release_dir="versions/stable/${artifact_type}/${version}"
    link_dir="stable"
  fi

  # Static files
  echo "Creating release directory"
  mkdir -p ${file_dir}/${release_dir}
  mkdir -p ${file_dir}/${link_dir}
  if [[ -L ${file_dir}/${link_dir}/${artifact_type} ]]; then
    rm -f ${file_dir}/${link_dir}/${artifact_type}
  fi
  ln -s ../${release_dir} ${file_dir}/${link_dir}/${artifact_type}
  echo "Copying files"
  mv ${in_dir}/${build_id}/${platform_arch}/* ${file_dir}/${release_dir}/
  echo "Creating sha256sums"
  for file in ${file_dir}/${release_dir}/*; do
    if [[ ${file} =~ ".sha256sum" ]]; then
      continue
    fi
    sha256sum ${file} | sed 's, .*/, ,' > ${file}.sha256sum
  done
  echo "Cleaning repository"
  chown -R root:adm ${file_dir}
  chmod -R g+w ${file_dir}
}

# Portable archive combination function
do_combine_portable() {
  platform_arch="${1}"
  platform="${platform_arch%.*}"
  case ${artifact_type} in
    server)
      partner_type="web"
      file_dir="/srv/repository/releases/server/${platform}"
    ;;
    web)
      partner_type="server"
      file_dir="/srv/repository/releases/server/${platform}"
    ;;
  esac

  if [[ ${platform} == "windows" ]]; then
    filetype="zip"
  else
    filetype="tar.gz"
  fi

  if [[ -n ${is_unstable} ]]; then
    stability="unstable"
    pkg_suffix="-unstable"
  elif [[ -n ${is_rc} ]]; then
    stability="stable-rc"
    pkg_suffix=""
  else
    stability="stable"
    pkg_suffix=""
  fi
  release_dir="versions/${stability}/${artifact_type}"
  partner_release_dir="versions/${stability}/${partner_type}"
  link_dir="${stability}/combined"

  our_archive="$( find ${file_dir}/${release_dir}/${version} -type f -name "jellyfin-${artifact_type}*.${filetype}" | head -1 )"
  if [[ -z ${is_unstable} ]]; then
    partner_archive="$( find ${file_dir}/${partner_release_dir} -type f -name "*${version}*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
  else
    partner_archive="$( find ${file_dir}/${partner_release_dir} -type f -name "*.${filetype}" -printf "%T@ %Tc %p\n" | sort -rn | head -1 | awk '{ print $NF }' )"
  fi

  if [[ ! -f ${partner_archive} ]]; then
    return
  fi

  temp_dir=$( mktemp -d )
  case ${artifact_type} in
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
    unzip ${server_archive} -d ${temp_dir}/ &>/dev/null
  else
    tar -xzf ${server_archive} -C ${temp_dir}/
  fi

  echo "Correcting root directory naming"
  pushd ${temp_dir} 1>&2
  server_dir="$( find . -maxdepth 1 -type d -name "jellyfin-server_*" | head -1 )"
  mv ${server_dir} ./jellyfin_${version}
  popd 1>&2

  echo "Unarchiving web archive"
  if [[ ${filetype} == "zip" ]]; then
    unzip ${web_archive} -d ${temp_dir}/jellyfin_${version}/ &>/dev/null
  else
    tar -xzf ${web_archive} -C ${temp_dir}/jellyfin_${version}/
  fi

  echo "Correcting web directory naming"
  pushd ${temp_dir}/jellyfin_${version}/ 1>&2
  web_dir="$( find . -maxdepth 1 -type d -name "jellyfin-web_*" | head -1 )"
  mv ${web_dir} jellyfin-web
  popd 1>&2

  pushd ${temp_dir} 1>&2
  mkdir -p ${file_dir}/versions/${stability}/combined/${version}
  if [[ ${filetype} == "zip" ]]; then
    echo "Creating combined zip archive"
    chown -R root:root ./
    zip -r ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.zip ./* &>/dev/null
    echo "Creating sha256sums"
    sha256sum ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.zip | sed 's, .*/, ,' > ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.zip.sha256sum
  else
    echo "Creating combined tar archive"
    chown -R root:root ./
    tar -czf ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.tar.gz ./
    echo "Creating sha256sums"
    sha256sum ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.tar.gz | sed 's, .*/, ,' > ${file_dir}/versions/${stability}/combined/${version}/jellyfin_${version}${pkg_suffix}.tar.gz.sha256sum
  fi
  popd 1>&2

  echo "Creating links"
  if [[ -L ${file_dir}/${link_dir} ]]; then
    rm -f ${file_dir}/${link_dir}
  fi
  ln -s ../versions/${stability}/combined/${version} ${file_dir}/${link_dir}

  echo "Cleaning up"
  rm -rf ${temp_dir}
}

# Debian Metapackage function
do_deb_meta() {
  platform_arch="${1}"
  platform="${platform_arch%.*}"
  pushd ${metapackages_dir} 1>&2

  case ${platform} in
    debian)
      codename="buster"
    ;;
    ubuntu)
      codename="bionic"
    ;;
  esac

  file_dir="/srv/repository/releases/server/${platform}"

  if [[ -n ${is_unstable} ]]; then
    release_dir="versions/unstable/meta/${version}"
    link_dir="unstable"
    version_suffix="-unstable"
  elif [[ -n ${is_rc} ]]; then
    release_dir="versions/stable-rc/meta/${version}"
    link_dir="stable-rc"
    version_suffix=""
  else
    release_dir="versions/stable/meta/${version}"
    link_dir="stable"
    version_suffix="-1"
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

  sed -i "s/X.Y.Z/${version}${version_suffix}/g" jellyfin.debian

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

  repo_dir="/srv/repository/${platform}"

  if [[ -z ${is_rc} ]]; then
    if [[ -z ${is_unstable} ]]; then
      component="-C main"
    else
      component="-C unstable"
    fi

    # Reprepro repository
    for release in ${releases[@]}; do
      echo "Importing files into ${release}"
      reprepro -b ${repo_dir} --export=never --keepunreferencedfiles \
        ${component} \
        includedeb \
        ${release} \
        ./*.deb
    done
    echo "Cleaning and exporting repository"
    reprepro -b ${repo_dir} deleteunreferenced
    reprepro -b ${repo_dir} export
    chown -R root:adm ${repo_dir}
    chmod -R g+w ${repo_dir}
  fi

  # Static files
  echo "Creating release directory"
  mkdir -p ${file_dir}/${release_dir}
  mkdir -p ${file_dir}/${link_dir}
  if [[ -L ${file_dir}/${link_dir}/meta ]]; then
      rm -f ${file_dir}/${link_dir}/meta
  fi
  ln -s ../${release_dir} ${file_dir}/${link_dir}/meta
  echo "Copying files"
  mv ./*.deb ${file_dir}/${release_dir}/
  echo "Creating sha256sums"
  for file in ${file_dir}/${release_dir}/*.deb; do
    if [[ ${file} =~ "*.sha256sum" ]]; then
      continue
    fi
    sha256sum ${file} | sed 's, .*/, ,' > ${file}.sha256sum
  done
  echo "Cleaning repository"
  chown -R root:adm ${file_dir}
  chmod -R g+w ${file_dir}

  # Clean up our changes
  git checkout jellyfin.debian

  popd 1>&2
}

cleanup_unstable() {
  platform_arch="${1}"
  platform="${platform_arch%.*}"
  if [[ ${stage} =~ [Ss]table ]]; then
    return
  fi
  file_dir="/srv/repository/releases/server/${platform}/versions/unstable"
  find ${file_dir} -mindepth 2 -maxdepth 2 -type d -mtime +3 -exec rm -r {} \;
}

(
  # Acquire an exclusive lock so multiple simultaneous builds do not override each other
  flock -x 300

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

  # Main loop
  for directory in ${in_dir}/${build_id}/*; do
    platform_arch="$( awk -F'/' '{ print $NF }' <<<"${directory}" )"
    echo "> Processing ${platform_arch}"
    case ${platform_arch} in
      debian*)
        do_deb ${platform_arch}
        do_deb_meta ${platform_arch}
        do_files ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      ubuntu*)
        do_deb ${platform_arch}
        do_deb_meta ${platform_arch}
        do_files ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      fedora*)
        do_files ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      centos*)
        do_files ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      portable)
        do_files ${platform_arch}
        do_combine_portable ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      linux*)
        do_files ${platform_arch}
        do_combine_portable ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      windows-installer*)
        # Modify the version info of the package if unstable
        if [[ -n ${is_unstable} ]]; then
          echo "Renaming Windows installer file to unstable version name"
          pushd ${in_dir}/${build_id}/${platform_arch} 1>&2
          # Correct the version
          mmv "jellyfin_*_windows-x64.exe" "jellyfin_${build_id}-unstable_x64.exe" 1>&2
          # Redo the version
          version="${build_id}"
          popd 1>&2
        fi

        do_files ${platform_arch}
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

        do_files ${platform_arch}
        do_combine_portable ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
      macos*)
        do_files ${platform_arch}
        do_combine_portable ${platform_arch}
        cleanup_unstable ${platform_arch}
      ;;
    esac
  done

  # Cleanup
  rm -r ${in_dir}/${build_id}

  # Run mirrorbits refresh
  mirrorbits refresh

  time_end=$( date +%s )
  time_total=$( echo "${time_end} - ${time_start}" | bc )

  echo "Finished at $( date ) in ${time_total} seconds" 1>&1
  echo "Finished at $( date ) in ${time_total} seconds" 1>&2

) 300>/var/log/os-pack.lock

rm /var/log/os-pack.lock
exit 0
