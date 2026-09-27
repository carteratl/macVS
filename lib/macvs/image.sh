# shellcheck shell=bash
# image.sh - download and verify official Debian cloud images (arm64 qcow2).
#
# Images come from https://cloud.debian.org/images/cloud/<release>/latest/ and are
# verified against the SHA512SUMS published alongside them. A cached image is kept
# per release under $MACVS_HOME/images/<release>/ with a .sha512 side file.

image_dir()      { printf '%s/images/%s\n' "$MACVS_HOME" "$1"; }
image_url_base() { printf '%s/%s/latest\n' "$MACVS_IMAGE_BASE_URL" "$1"; }

# Refresh SHA512SUMS for a release and resolve the current filename/hash for a
# variant. Sets IMG_FILE, IMG_SHA, IMG_PATH.
image_lookup() {
  local release="$1" variant="$2" dir tmp line re
  dir="$(image_dir "$release")"
  mkdir -p "$dir"
  tmp="$dir/SHA512SUMS.tmp"
  if curl -fsSL --retry 3 --max-time 60 -o "$tmp" "$(image_url_base "$release")/SHA512SUMS"; then
    mv -f "$tmp" "$dir/SHA512SUMS"
  else
    rm -f "$tmp"
    if [ -f "$dir/SHA512SUMS" ]; then
      warn "could not refresh checksum list for '$release'; using cached copy"
    else
      die "could not download $(image_url_base "$release")/SHA512SUMS (is '$release' a valid Debian release?)"
    fi
  fi
  re="^[0-9a-f]{128}[[:space:]]+debian-[0-9]+-${variant}-arm64\\.qcow2\$"
  line="$(grep -E "$re" "$dir/SHA512SUMS" | head -n 1)" || true
  [ -n "$line" ] || die "no '$variant' arm64 image is listed for release '$release'"
  IMG_SHA="${line%% *}"
  IMG_FILE="${line##* }"
  IMG_PATH="$dir/$IMG_FILE"
}

image_verify_file() { # path expected-sha
  local got
  info "verifying SHA-512 of $(basename "$1")"
  got="$(shasum -a 512 "$1" | awk '{print $1}')"
  [ "$got" = "$2" ]
}

# Download (or refresh) the image for release/variant. Third arg "force" re-downloads.
image_pull() {
  local release="$1" variant="$2" force="${3:-}" url attempt
  require_cmd curl; require_cmd shasum
  image_lookup "$release" "$variant"

  if [ -z "$force" ] && [ -f "$IMG_PATH" ] && [ -f "$IMG_PATH.sha512" ] \
     && [ "$(cat "$IMG_PATH.sha512")" = "$IMG_SHA" ]; then
    ok "image is current: $IMG_PATH"
    return 0
  fi
  if [ -f "$IMG_PATH" ] && [ "$(cat "$IMG_PATH.sha512" 2>/dev/null)" != "$IMG_SHA" ]; then
    info "a newer '$release' image is published upstream; replacing the cached copy"
  fi

  url="$(image_url_base "$release")/$IMG_FILE"
  attempt=1
  while :; do
    info "downloading $IMG_FILE ($url)"
    if ! curl -fL --retry 3 -C - --progress-bar -o "$IMG_PATH.part" "$url"; then
      rm -f "$IMG_PATH.part"
      die "download failed"
    fi
    if image_verify_file "$IMG_PATH.part" "$IMG_SHA"; then break; fi
    rm -f "$IMG_PATH.part"
    [ "$attempt" -lt 2 ] || die "checksum mismatch after re-download; refusing to use $IMG_FILE"
    warn "checksum mismatch (stale partial download?); retrying from scratch"
    attempt=$((attempt + 1))
  done
  mv -f "$IMG_PATH.part" "$IMG_PATH"
  printf '%s\n' "$IMG_SHA" > "$IMG_PATH.sha512"
  ok "image ready: $IMG_PATH"
}

# Make sure some verified image for release/variant is cached; only touches the
# network when nothing usable is present. Sets IMG_FILE, IMG_SHA, IMG_PATH.
image_ensure() {
  local release="$1" variant="$2" dir f
  dir="$(image_dir "$release")"
  for f in "$dir"/debian-*-"$variant"-arm64.qcow2; do
    if [ -f "$f" ] && [ -f "$f.sha512" ]; then
      IMG_PATH="$f"; IMG_FILE="$(basename "$f")"; IMG_SHA="$(cat "$f.sha512")"
      return 0
    fi
  done
  image_pull "$release" "$variant"
}

image_list() {
  local d f
  printf '%-10s %-40s %-8s %s\n' RELEASE IMAGE SIZE DOWNLOADED
  for d in "$MACVS_HOME"/images/*/; do
    [ -d "$d" ] || continue
    for f in "$d"debian-*.qcow2; do
      [ -f "$f" ] || continue
      printf '%-10s %-40s %-8s %s\n' "$(basename "$d")" "$(basename "$f")" \
        "$(du -h "$f" | awk '{print $1}')" "$(date -r "$f" +%Y-%m-%d)"
    done
  done
}

image_remove() { # release
  local dir; dir="$(image_dir "$1")"
  [ -d "$dir" ] || die "no cached images for release '$1'"
  rm -rf "$dir"
  ok "removed cached images for '$1'"
}
