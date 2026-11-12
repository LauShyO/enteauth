#!/bin/sh
# Restore the binary files listed in binary-files.txt from upstream.
# Downloads each file from raw.githubusercontent.com at the pinned upstream
# commit and verifies its SHA256. Files already present with a matching hash
# are skipped. Run from the repository root.
set -eu
SHA=6b0003ecee71f3c771c07469f5a145a641f02c9a
BASE="https://raw.githubusercontent.com/ente/ente/$SHA"
MANIFEST="$(dirname "$0")/../binary-files.txt"
ROOT="$(dirname "$0")/.."
ok=0; fetched=0; failed=0
while read -r want path; do
    [ -n "$path" ] || continue
    dest="$ROOT/$path"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
        ok=$((ok+1)); continue
    fi
    mkdir -p "$(dirname "$dest")"
    tmp="$dest.download"
    if curl -fsSL "$BASE/$path" -o "$tmp" && [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$want" ]; then
        mv "$tmp" "$dest"
        fetched=$((fetched+1))
    else
        rm -f "$tmp"
        echo "FAILED: $path" >&2
        failed=$((failed+1))
    fi
done < "$MANIFEST"
echo "already ok: $ok, fetched: $fetched, failed: $failed"
[ "$failed" -eq 0 ]