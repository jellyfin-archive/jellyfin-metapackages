#!/bin/bash
set -e
# Simple script that pushes missing/outdated tags from an image in DockerHub to GHCR, skipping up-to-date tags 
# GitHub package registry. You need to be logged in using 'docker login' first: https://docs.github.com/es/packages/working-with-a-github-packages-registry/working-with-the-container-registry
target_repo="ghcr.io"
tag_file="tag_list.txt"
original_image="$1"
rm -rf $tag_file
url="https://hub.docker.com/v2/repositories/${original_image}/tags"
tag_count=$(wget -q "$url" -O - | jq -r '.count')

echo "Fetching tags from DockerHub..."
while true; do
	results=$(wget -q "$url" -O - | jq -r '.')
	url=$(echo "$results" | jq -r '.next')
	echo "$results" | jq -r '.results[] | {name: .name, last_pushed: .tag_last_pushed, digests: [.images[].digest]}' >> $tag_file
	if [ "${url}" = "null" ]
	then
		break
	else
		continue
	fi
done;
unset results, url

sorted=$(cat "$tag_file" | jq -s 'sort_by(.last_pushed)')
echo "$sorted" > $tag_file
file_tag_count=$(jq length "$tag_file")

if [ $tag_count = $file_tag_count ]
then
	echo -e "All the data was retrieved correctly. Pushing missing/modified tags to DockerHub...\n"
else
	echo "The retrieved data doesn't match the amount of tags expected by Docker API. Exiting script..."
	exit 1
fi

unset sorted, file_tag_count, tag_count

## This token is that GitHub provides is used to access the registry in read-only, so users are able to
## use GHCR without signing up to GitHub. By using this token for checking for the published images, we don't consume
## our own API quota.
dest_token=$(wget -q https://${target_repo}/token\?scope\="repository:${original_image}:pull" -O - | jq -r '.token')
tag_names=$(cat "$tag_file" | jq -r '.[] | .name')

while read -r line; do
	tag="$line"
	source_digests=$(cat "$tag_file" | jq -r --arg TAG_NAME "$tag" '.[] | select(.name == $TAG_NAME) | .digests | sort | .[]' | cat)
	target_manifest=$(wget --header="Authorization: Bearer ${dest_token}" -q https://${target_repo}/v2/${original_image}/manifests/${tag} -O - | cat)
	target_digests=$(echo "$target_manifest" | jq '.manifests | .[] | .digest' | jq -s '. | sort' | jq -r '.[]' | cat)
	if [ "$source_digests" = "$target_digests" ]
	then
		echo The tag $tag is fully updated in $target_repo
		continue
	else
		echo Updating $tag in $target_repo
		docker pull $original_image:$tag
		docker tag $original_image:$tag $target_repo/$original_image:$tag
		docker push $target_repo/$original_image:$tag

		# Delete pushed images from local system
		docker image rm $original_image:$tag
		docker image rm $target_repo/$original_image:$tag
	fi
done <<< $tag_names

rm -rf $tag_file
echo -e "\nAll the tags have been updated successfully"
exit 0
