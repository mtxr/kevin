#!/bin/sh
# Installs the latest kevin release (or $KEVIN_VERSION, e.g. v0.1.0) for macOS or Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/mtxr/kevin/main/install.sh | sh
#
# Environment: KEVIN_VERSION (default: latest), KEVIN_INSTALL_DIR (default: ~/.local/bin).
set -eu

# Everything lives in a function that is only called on the last line, so a
# download truncated halfway through a `curl | sh` never runs a partial script.
main() {
  repo="mtxr/kevin"
  dir="${KEVIN_INSTALL_DIR:-$HOME/.local/bin}"

  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) echo "install.sh: unsupported OS $(uname -s); see https://github.com/$repo/releases" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) echo "install.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  target="$arch-$os"

  version="${KEVIN_VERSION:-}"
  if [ -z "$version" ]; then
    # the redirect of /releases/latest carries the tag, so no API token or JSON parsing is needed
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")
    version="${version##*/}"
  fi
  case "$version" in v[0-9]*) ;; *) echo "install.sh: could not determine the latest version" >&2; exit 1 ;; esac

  name="kevin-$version-$target"
  base="https://github.com/$repo/releases/download/$version"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading kevin $version for $target"
  curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

  expected=$(grep " $name.tar.gz\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
  else
    actual=$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d' ' -f1)
  fi
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "install.sh: checksum mismatch for $name.tar.gz" >&2
    exit 1
  fi

  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  mkdir -p "$dir"
  install -m 0755 "$tmp/$name/kevin" "$dir/kevin"
  echo "Installed $dir/kevin"
  case ":$PATH:" in *":$dir:"*) ;; *) echo "Add $dir to your PATH to run 'kevin'." ;; esac
}

main "$@"
