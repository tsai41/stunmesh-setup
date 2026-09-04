#!/usr/bin/env bash
# launchd-install.sh — install/manage the macOS-only boot-time LaunchDaemon.
set -euo pipefail

LABEL="com.stunmesh.setup"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

_usage() {
  echo "Usage: $0 {install <repo-root> <state-owner>|uninstall|status|restart}" >&2
  exit 2
}

_require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "✗ launchd integration is for macOS only" >&2; exit 1; }
}

_require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "✗ run this via the matching make launchd-* target" >&2; exit 1; }
}

_xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

_install() {
  local repo_root="$1" state_owner="$2" template tmp escaped_root escaped_owner
  [[ -d "$repo_root" && -x "$repo_root/scripts/launchd.sh" ]] || {
    echo "✗ Invalid repo root: $repo_root" >&2
    return 1
  }
  id "$state_owner" >/dev/null 2>&1 || { echo "✗ Unknown state owner: $state_owner" >&2; return 1; }
  template="$repo_root/launchd/macos/${LABEL}.plist.in"
  [[ -f "$template" ]] || { echo "✗ Missing plist template: $template" >&2; return 1; }
  escaped_root="$(printf '%s' "$repo_root" | _xml_escape)"
  escaped_owner="$(printf '%s' "$state_owner" | _xml_escape)"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  STUNMESH_XML_ROOT="$escaped_root" STUNMESH_XML_OWNER="$escaped_owner" \
    perl -pe 's/\@REPO_ROOT\@/$ENV{STUNMESH_XML_ROOT}/g; s/\@STATE_OWNER\@/$ENV{STUNMESH_XML_OWNER}/g' \
    "$template" > "$tmp"
  plutil -lint "$tmp" >/dev/null
  launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  install -o root -g wheel -m 644 "$tmp" "$PLIST"
  launchctl bootstrap system "$PLIST"
  echo "✓ Installed ${LABEL}; it will start at boot and restart after a failure."
}

_uninstall() {
  launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  echo "✓ Removed ${LABEL}."
}

_status() {
  launchctl print "system/${LABEL}" 2>/dev/null || echo "${LABEL}: not loaded"
}

case "${1:-}" in
  install) _require_macos; _require_root; [[ $# -eq 3 ]] || _usage; _install "$2" "$3" ;;
  uninstall) _require_macos; _require_root; _uninstall ;;
  status) _require_macos; _status ;;
  restart) _require_macos; _require_root; launchctl kickstart -k "system/${LABEL}" ;;
  *) _usage ;;
esac
