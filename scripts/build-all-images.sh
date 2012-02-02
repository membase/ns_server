#! /bin/sh
set -e
cd priv/public
images=`find images -name no-preload -prune -o -type f -exec echo {} + | sort | sed -e s/\ /\",\ \"/g`
echo "var AllImages = [\"${images}\"];"
