#!/bin/bash
cd "$(dirname "$0")"
curl -s https://api.github.com/repos/Kabuto58/lboxdump/releases/latest \
| grep "browser_download_url" \
| cut -d '"' -f 4 \
| while read url; do
    echo "Downloading $url"
    curl -L -O "$url"
  done
