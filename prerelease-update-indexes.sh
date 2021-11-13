#!/usr/bin/env bash

version="${1}"

# Update all the various entries in the PHP headers
for platform in $( find "/srv/repository/releases/server" -mindepth 1 -maxdepth 1 -type d ); do
    pushd ${platform}
    pre_index_file="stable-pre/index.php"
    current_array="$( grep '$directories = array' $file | awk -F '[()]' '{ print $2 }' )"
    rtypes="$( find "stable-pre/${version}" -mindepth 1 -maxdepth 1 -type l -exec basename {} \; )"

    new_array_paths=()
    for rtype in ${rtypes}; do
        new_array_paths+=("'${version}/${rtype}'")
    done
    new_array="$( IFS=, ; echo "${new_array_paths[*]}" )"

    sed "s|${current_array}|${new_array}, ${current_array}|g" ${pre_index_file}
    read
    sed -i "s|${current_array}|${new_array}, ${current_array}|g" ${pre_index_file}
    popd
done
