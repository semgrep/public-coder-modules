#!/bin/sh
# Download Mandoline and place it on the agent PATH for `mandoline mcp`.
set -eu
umask 077

install_dir="/opt/bin"
version_file="$install_dir/mandoline.version"
selector='${mandoline_version}'
asset='mandoline-linux-x86_64.tar.gz'

fail() {
  echo "Mandoline MCP: $1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required to download Mandoline.'
command -v tar >/dev/null 2>&1 || fail 'tar is required to extract Mandoline.'

case "$(uname -s)" in
  Linux) ;;
  *) fail "Unsupported operating system for Mandoline MCP: $(uname -s)." ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) fail "Unsupported architecture for Mandoline MCP: $(uname -m). Expected x86_64." ;;
esac

if [ "$selector" = latest ]; then
  download_url="https://github.com/semgrep/mandoline/releases/latest/download/$asset"
else
  download_url="https://github.com/semgrep/mandoline/releases/download/v$${selector}/$asset"
fi

mkdir -p "$install_dir"

if [ ! -x "$install_dir/mandoline" ] || [ "$(cat "$version_file" 2>/dev/null || true)" != "$selector" ]; then
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT HUP INT TERM
  echo "Downloading Mandoline ($selector)…"
  curl --fail --silent --show-error --location --proto '=https' \
    "$download_url" -o "$staging/$asset" \
    || fail "Could not download Mandoline from $download_url."
  tar -xzf "$staging/$asset" -C "$staging" \
    || fail 'Could not extract the Mandoline archive.'
  binary="$(find "$staging" -type f -name mandoline | head -n 1)"
  [ -n "$binary" ] || fail 'Mandoline archive did not contain a mandoline binary.'
  cp "$binary" "$install_dir/mandoline"
  chmod 0755 "$install_dir/mandoline"
  printf '%s\n' "$selector" > "$version_file"
  chmod 600 "$version_file"
  rm -rf "$staging"
  trap - EXIT HUP INT TERM
fi

[ -x "$install_dir/mandoline" ] || fail 'Mandoline installation finished without an executable binary.'
echo "Mandoline MCP installed ($selector); use \`mandoline mcp\`."
