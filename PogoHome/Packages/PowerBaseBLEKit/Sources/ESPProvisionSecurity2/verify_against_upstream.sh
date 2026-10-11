#!/bin/sh
# Shows exactly how Upstream/ differs from Espressif's repository at the pinned commit.
#
#   git clone https://github.com/espressif/esp-idf-provisioning-ios.git /tmp/espprov
#   git -C /tmp/espprov checkout 78e58f010f8539f800bce063a26d3e4c4ac596b9
#   sh verify_against_upstream.sh /tmp/espprov
#
# Every file here is the upstream file itself -- no wrapper line before or after it (until
# 2026-10-05 each file was inside "#if DEBUG ... #endif"; the package is now compiled into Release
# builds too, see VENDORED.md). The only files that may differ are the three patched ones listed
# in VENDORED.md; their diffs are printed. Exit status 0 = as documented.
set -eu
upstream="${1:?path to a checkout of esp-idf-provisioning-ios at the pinned commit}/ESPProvision"
here="$(cd "$(dirname "$0")" && pwd)/Upstream"
expected="Security2/ESPSecurity2.swift
Security2/SRP/Client.swift
Utility/ESPLogging.swift"
status=0
changed=""
cd "$here"
for file in $(find . -name '*.swift' | sed 's|^\./||' | tr ' ' '?' | sort); do
    file="$(printf '%s' "$file" | tr '?' ' ')"
    if [ ! -f "$upstream/$file" ]; then
        echo "NOT IN UPSTREAM: $file"; status=1; continue
    fi
    [ "$(head -n 1 "$file" | cut -c1-9)" != "#if DEBUG" ] || { echo "DEBUG WRAPPER: $file"; status=1; }
    if ! cmp -s "$file" "$upstream/$file"; then
        changed="$changed$file
"
        echo "=== $file"
        diff "$upstream/$file" "$file" || true
    fi
done
if [ "$(printf '%s' "$changed" | sort)" != "$(printf '%s\n' "$expected" | sort)" ]; then
    echo "UNEXPECTED SET OF CHANGED FILES:"; printf '%s' "$changed"; status=1
fi
[ "$status" -eq 0 ] && echo "OK: $(find . -name '*.swift' | wc -l | tr -d ' ') files; only the three documented files differ."
exit "$status"
