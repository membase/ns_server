#! /bin/sh
set -e
cd priv/public
images=`find images -type f -exec echo {} + | sort | sed -e s/\ /\",\ \"/g`
echo "var AllImages = [\"${images}\"];"
