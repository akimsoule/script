#!/bin/bash

source="/Volumes/dev/projects/native/trade.app.cli/src"
destination="/Volumes/dev/projects/native/trade-app/netlify/trade.app/src"

if [ "$1" == "reverse" ]; then
    rsync -av --delete "$destination/" "$source/"
    rsync -av --delete "$destination/../../../prisma/schema.prisma" "$source/../prisma"
else
    rsync -av --delete "$source/" "$destination/"
    rsync -av --delete "$source/../prisma/schema.prisma" "$destination/../../../prisma/schema.prisma"
fi