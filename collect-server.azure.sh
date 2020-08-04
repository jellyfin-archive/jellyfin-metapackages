#!/usr/bin/env bash

# Jellyfin Azure builds collection wrapper script
# Because Azure is a fail

nohup /srv/jellyfin/projects/server/jellyfin-metapackages/collect-server.sh $1 $2 $3 & disown
