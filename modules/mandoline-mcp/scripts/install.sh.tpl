#!/bin/sh
# Download Mandoline via gh and place it on the agent PATH for `mandoline mcp`.
set -eu
umask 077

install_dir="/usr/local/bin"
version_file="$install_dir/mandoline.version"
selector='${mandoline_version}'
asset='mandoline-linux-x86_64.tar.gz'
repo='semgrep/mandoline'

fail() {
  echo "Mandoline MCP: $1" >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || fail 'GitHub CLI (gh) is required to download Mandoline.'
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
  release="$(gh release list --repo "$repo" --exclude-drafts --exclude-pre-releases --limit 1 --json name --jq '.[0].name')" \
    || fail "Could not list Mandoline releases from $repo."
  [ -n "$release" ] && [ "$release" != null ] \
    || fail "No Mandoline releases found in $repo."
else
  release="v$${selector}"
fi

mkdir -p "$install_dir"

if [ ! -x "$install_dir/mandoline" ] || [ "$(cat "$version_file" 2>/dev/null || true)" != "$release" ]; then
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT HUP INT TERM
  echo "Downloading Mandoline ($release)…"
  (
    cd "$staging"
    gh release download "$release" --repo "$repo" --pattern "$asset" \
      || fail "Could not download Mandoline release $release from $repo."
    tar -xf "$asset" \
      || fail 'Could not extract the Mandoline archive.'
    [ -f mandoline ] || fail 'Mandoline archive did not contain a mandoline binary.'
    chmod 0755 mandoline
    mv mandoline "$install_dir/mandoline"
    rm -f "$asset"
  )
  printf '%s\n' "$release" > "$version_file"
  chmod 600 "$version_file"
  rm -rf "$staging"
  trap - EXIT HUP INT TERM
fi

[ -x "$install_dir/mandoline" ] || fail 'Mandoline installation finished without an executable binary.'

echo "Installing Mandoline skill…"
"$install_dir/mandoline" install-skill \
  || fail 'Could not install the Mandoline skill.'

echo "Mandoline MCP installed ($release); use \`mandoline mcp\`."
