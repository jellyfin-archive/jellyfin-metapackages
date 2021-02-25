#!/bin/bash
# One time script to repush docker images from DockerHub to ghcr.io
username="jellyfin"
# Github package registry. You need to be logged in first
target_repo="ghcr.io"
img_file="image_list.txt"
tag_file="tag_list.txt"
rm -rf $img_file

wget -q https://hub.docker.com/v2/repositories/$username/ -O - | jq -r '.results[] | . | .namespace + "/" + .name' >> $img_file

while read -r line; do
    original_image="$line"
    new_image="$original_image"
    rm -rf $tag_file
    wget -q https://hub.docker.com/v1/repositories/$original_image/tags -O - | jq -r '.[] | .name' >> $tag_file

    while read -r line2; do
        tag="$line2"
        docker pull $original_image:$tag
        docker tag $original_image:$tag $target_repo/$new_image:$tag
        docker push $target_repo/$new_image:$tag
    done < "$tag_file"

    while read -r line3; do
        tag="$line3"
        # Delete already pushed images
        docker image rm $original_image:$tag
        docker image rm $target_repo/$new_image:$tag
    done < "$tag_file"
done < "$img_file"

rm -rf $img_file
