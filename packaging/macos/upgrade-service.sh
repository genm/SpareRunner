#!/bin/bash
set -euo pipefail

# Upgrades an installed SpareRunner LaunchDaemon to this package. The operator
# publishes the new agent binary at /usr/local/libexec/sparerunner-agent
# first, exactly like the initial install; this script then unloads the
# daemon, replaces the property list only when it can prove SpareRunner
# published it, and bootstraps the daemon again so launchd runs the new
# binary. It never downloads, builds, or relocates an executable, and never
# touches node state, the package cache, or the dedicated runner account.
#
# Provenance is proven the same way uninstall-service.sh proves it: the
# installed property list is replaced only when it is byte-identical to a
# plist this project shipped. An installed plist that already matches this
# package needs no replacement, so a binary-only upgrade requires nothing but
# this package. A plist from an older release must match the previous
# release's plist passed with `--previous`; release archives are reproducible
# and checksummed, so the old plist can always be re-downloaded to supply
# that proof. A plist that matches neither is an operator edit this script
# must not discard.

readonly label="com.genm.sparerunner.agent"
readonly marker_name=".sparerunner-install-ownership-v1"
readonly marker_version="1"
readonly binary_path="/usr/local/libexec/sparerunner-agent"
readonly plist_target_path="/Library/LaunchDaemons/${label}.plist"
readonly state_root_path="/Library/Application Support/SpareRunner"
readonly cache_parent_path="/Library/Caches/com.genm.sparerunner"

plist_source_arg=""
previous_source_arg=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --previous)
      [[ "$#" -ge 2 ]] || {
        echo "--previous requires the previous release's property list path" >&2
        exit 1
      }
      previous_source_arg="$2"
      shift 2
      ;;
    --*)
      echo "unknown upgrade option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$plist_source_arg" ]]; then
        echo "upgrade-service.sh accepts one property list path" >&2
        exit 1
      fi
      plist_source_arg="$1"
      shift
      ;;
  esac
done
if [[ -z "$plist_source_arg" ]]; then
  plist_source_arg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/launchd/${label}.plist"
fi
readonly plist_source_arg previous_source_arg

# The test indirection is accepted only with an explicit marker under a
# canonical alternate root, exactly like the installer's contract.
readonly test_root="${SPARERUNNER_MACOS_INSTALL_TEST_ROOT:-}"
readonly test_tools="${SPARERUNNER_MACOS_INSTALL_TEST_TOOLS:-}"
readonly test_enabled="${SPARERUNNER_MACOS_INSTALL_TESTING:-}"
if [[ -n "$test_root" || -n "$test_tools" || -n "$test_enabled" ]]; then
  if [[ "$test_enabled" != "1" ||
        "$EUID" -eq 0 ||
        "$test_root" != /* ||
        "$test_root" == "/" ||
        "$test_root" == */ ||
        "$test_root" == *"/../"* ||
        "$test_root" == *"/./"* ||
        ! -d "$test_root" ||
        -L "$test_root" ||
        ! -f "${test_root}/.sparerunner-installer-test-root" ||
        "$test_tools" != /* ||
        ! -d "$test_tools" ||
        -L "$test_tools" ]]; then
    echo "invalid macOS installer test boundary; root never accepts test indirection" >&2
    exit 1
  fi
fi

fail() {
  echo "$1" >&2
  exit 1
}

run_tool() {
  local name="$1"
  shift
  if [[ "$test_enabled" == "1" ]]; then
    "${test_tools}/${name}" "$@"
    local rc=$?
    # Preserve the helper's exit status explicitly so test indirection has the
    # same fail-closed behavior as the production command surface.
    return "$rc"
  fi
  case "$name" in
    cmp) /usr/bin/cmp "$@" ;;
    id) /usr/bin/id "$@" ;;
    install) /usr/bin/install "$@" ;;
    launchctl) /bin/launchctl "$@" ;;
    ln) /bin/ln "$@" ;;
    plutil) /usr/bin/plutil "$@" ;;
    rm) /bin/rm "$@" ;;
    stat) /usr/bin/stat "$@" ;;
    *)
      echo "unknown upgrade tool: $name" >&2
      return 1
      ;;
  esac
}

rooted_path() {
  local logical_path="$1"
  if [[ "$test_enabled" == "1" ]]; then
    printf '%s%s' "$test_root" "$logical_path"
    return
  fi
  printf '%s' "$logical_path"
}

binary="$(rooted_path "$binary_path")"
plist_target="$(rooted_path "$plist_target_path")"
state_root="$(rooted_path "$state_root_path")"
cache_parent="$(rooted_path "$cache_parent_path")"
readonly binary plist_target state_root cache_parent
readonly state_marker="${state_root}/${marker_name}"
readonly cache_marker="${cache_parent}/${marker_name}"
readonly previous_staged="${plist_target}.sparerunner-upgrade-prev"
readonly temporary_staged="${plist_target}.sparerunner-install-tmp"

if [[ "$(run_tool id -u)" != "0" || "$(run_tool id -g)" != "0" ]]; then
  fail "upgrade-service.sh must run as root:wheel"
fi

resolve_package_plist() {
  local argument="$1"
  local description="$2"
  if [[ "$argument" != /* ||
        "$argument" == *"//"* ||
        "$argument" == *"/../"* ||
        "$argument" == *"/.." ||
        "$argument" == *"/./"* ||
        "$argument" == *"/." ||
        "$argument" == */ ]]; then
    fail "${description} must be canonical and absolute"
  fi
  local parent="${argument%/*}"
  [[ -n "$parent" ]] || parent="/"
  local name="${argument##*/}"
  local resolved_parent
  resolved_parent="$(cd "$parent" 2>/dev/null && pwd -P)" ||
    fail "${description} parent is unavailable"
  if [[ "${resolved_parent%/}/${name}" != "$argument" ]]; then
    fail "${description} crosses a symlinked ancestor"
  fi
  if [[ ! -f "$argument" || -L "$argument" ]]; then
    fail "missing or unsafe package file: $argument"
  fi
  printf '%s' "$argument"
}

plist_source="$(resolve_package_plist "$plist_source_arg" "launchd property list path")"
readonly plist_source
previous_source=""
if [[ -n "$previous_source_arg" ]]; then
  previous_source="$(resolve_package_plist "$previous_source_arg" "previous property list path")"
fi
readonly previous_source

stat_contract() {
  run_tool stat -f '%u:%g:%p' "$1"
}

require_regular_contract() {
  local path="$1"
  local expected="$2"
  if [[ ! -f "$path" || -L "$path" ]]; then
    fail "unsafe or missing regular file: $path"
  fi
  local actual
  actual="$(stat_contract "$path")" ||
    fail "cannot inspect regular file: $path"
  if [[ "$actual" != "$expected" ||
        "$(run_tool stat -f '%l' "$path")" != "1" ]]; then
    fail "regular file does not match its ownership contract: $path"
  fi
}

require_directory_contract() {
  local path="$1"
  local expected="$2"
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "unsafe or missing service directory: $path"
  fi
  local actual
  actual="$(stat_contract "$path")" ||
    fail "cannot inspect service directory: $path"
  if [[ "$actual" != "$expected" ]]; then
    fail "service directory does not match its ownership contract: $path"
  fi
}

require_safe_ancestor() {
  local logical_path="$1"
  local path
  path="$(rooted_path "$logical_path")"
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "unsafe or missing installer ancestor: $logical_path"
  fi
  local actual uid_gid mode numeric_mode
  actual="$(stat_contract "$path")" ||
    fail "cannot inspect installer ancestor: $logical_path"
  uid_gid="${actual%:*}"
  mode="${actual##*:}"
  if [[ "${uid_gid%%:*}" != "0" ||
        ! "$mode" =~ ^[0-7]{5,6}$ ]]; then
    fail "installer ancestor is not root-owned and write-safe: $logical_path"
  fi
  numeric_mode="$((8#$mode))"
  if [[ $((numeric_mode & 8#170000)) -ne $((8#040000)) ]]; then
    fail "installer ancestor is not root-owned and write-safe: $logical_path"
  fi
  if [[ $((numeric_mode & 8#022)) -ne 0 ]]; then
    if [[ "$logical_path" != "/Library/Caches" ||
          $((numeric_mode & 8#01000)) -eq 0 ]]; then
      fail "installer ancestor is not root-owned and write-safe: $logical_path"
    fi
  fi
}

require_safe_ancestor_chain() {
  local logical_path="$1"
  local remainder="${logical_path#/}"
  local current=""
  local component
  local components=()
  local old_ifs="$IFS"
  require_safe_ancestor "/"
  IFS='/'
  read -r -a components <<< "$remainder"
  IFS="$old_ifs"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] ||
      fail "installer path is not canonical: $logical_path"
    current="${current}/${component}"
    require_safe_ancestor "$current"
  done
}

valid_install_id() {
  [[ "$1" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]
}

read_marker_install_id() {
  local marker="$1"
  local expected_role="$2"
  local expected_path="$3"
  require_regular_contract "$marker" "0:0:100600"
  local line count=0 install_id=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    count=$((count + 1))
    case "$count" in
      1) [[ "$line" == "version=${marker_version}" ]] || return 1 ;;
      2)
        [[ "$line" == install_id=* ]] || return 1
        install_id="${line#install_id=}"
        valid_install_id "$install_id" || return 1
        ;;
      3) [[ "$line" == "role=${expected_role}" ]] || return 1 ;;
      4) [[ "$line" == "path=${expected_path}" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$marker"
  [[ "$count" -eq 4 ]] || return 1
  printf '%s' "$install_id"
}

plist_matches() {
  local path="$1"
  local source="$2"
  local maximum_links="${3:-1}"
  local actual links
  [[ -f "$path" && ! -L "$path" ]] || return 1
  actual="$(stat_contract "$path" 2>/dev/null)" || return 1
  links="$(run_tool stat -f '%l' "$path" 2>/dev/null)" || return 1
  [[ "$actual" == "0:0:100600" &&
    "$links" =~ ^[0-9]+$ &&
    "$links" -ge 1 &&
    "$links" -le "$maximum_links" ]] || return 1
  run_tool cmp -s "$source" "$path"
}

daemon_is_loaded() {
  run_tool launchctl print "system/${label}" > /dev/null 2>&1
}

upgrade_committed=0
transaction_active=0
stopped_service=0
staged_previous=0
staged_temporary=0
published_new=0
bootstrap_attempted=0

rollback_upgrade() {
  local original_exit="$?"
  local rollback_failed=0
  trap - EXIT
  if [[ "$upgrade_committed" -eq 1 || "$transaction_active" -eq 0 ]]; then
    return "$original_exit"
  fi
  set +e

  if [[ "$bootstrap_attempted" -eq 1 ]] && daemon_is_loaded; then
    if plist_matches "$plist_target" "$plist_source" 2; then
      run_tool launchctl bootout "system/${label}" || rollback_failed=1
    else
      rollback_failed=1
    fi
  fi
  if [[ "$published_new" -eq 1 && ( -e "$plist_target" || -L "$plist_target" ) ]]; then
    if plist_matches "$plist_target" "$plist_source" 2; then
      run_tool rm "$plist_target" || rollback_failed=1
    else
      rollback_failed=1
    fi
  fi
  if [[ "$staged_temporary" -eq 1 && ( -e "$temporary_staged" || -L "$temporary_staged" ) ]]; then
    run_tool rm "$temporary_staged" || rollback_failed=1
  fi
  if [[ "$staged_previous" -eq 1 && ( -e "$previous_staged" || -L "$previous_staged" ) ]]; then
    if [[ ! -e "$plist_target" && ! -L "$plist_target" ]]; then
      if plist_matches "$previous_staged" "$previous_source" 2; then
        run_tool ln "$previous_staged" "$plist_target" || rollback_failed=1
      else
        rollback_failed=1
      fi
    fi
    if [[ -e "$plist_target" && ! -L "$plist_target" ]] &&
      run_tool cmp -s "$previous_staged" "$plist_target"; then
      run_tool rm "$previous_staged" || rollback_failed=1
    else
      rollback_failed=1
    fi
  fi
  if [[ "$stopped_service" -eq 1 ]]; then
    # The daemon was loaded before this upgrade began; a failed upgrade must
    # hand back a running previous installation, not an unloaded machine.
    if run_tool launchctl bootstrap system "$plist_target"; then
      daemon_is_loaded || rollback_failed=1
    else
      rollback_failed=1
    fi
  fi

  if [[ "$rollback_failed" -ne 0 ]]; then
    echo "macOS upgrade failed and verified rollback was incomplete; inspect the staged .sparerunner-upgrade-prev file before retrying" >&2
  else
    echo "macOS upgrade failed; the previous installation was restored and restarted" >&2
  fi
  if [[ "$original_exit" -eq 0 ]]; then
    original_exit=1
  fi
  exit "$original_exit"
}

# Validate every authority and target before the first filesystem or launchd
# mutation.
run_tool plutil -lint "$plist_source" > /dev/null
require_safe_ancestor_chain "/usr/local/libexec"
require_safe_ancestor_chain "/Library/LaunchDaemons"
require_safe_ancestor_chain "/Library/Application Support"
require_safe_ancestor_chain "/Library/Caches"
require_regular_contract "$binary" "0:0:100755"

# An upgrade requires the owned installation the installer left behind. Only
# the roots and their markers are verified: an enrolled node legitimately has
# state under them, so the installer's empty-layout check must not run here.
if [[ ! -d "$state_root" || -L "$state_root" ||
      ! -d "$cache_parent" || -L "$cache_parent" ]]; then
  fail "no owned SpareRunner installation to upgrade; run install-service.sh first"
fi
require_directory_contract "$state_root" "0:0:40711"
require_directory_contract "$cache_parent" "0:0:40700"
install_id="$(
  read_marker_install_id "$state_marker" "agent-state" "$state_root_path"
)" || fail "state root has no valid SpareRunner ownership marker"
cache_install_id="$(
  read_marker_install_id "$cache_marker" "agent-cache" "$cache_parent_path"
)" || fail "cache root has no valid SpareRunner ownership marker"
[[ "$cache_install_id" == "$install_id" ]] ||
  fail "SpareRunner ownership markers do not share one install identity"

# The installed property list must be provably a SpareRunner package file
# before the daemon is unloaded: byte-identical to this package (no
# replacement needed), or byte-identical to the explicit previous release
# (replaced). Anything else is an operator edit or a broken installation this
# script must not touch.
if [[ ! -e "$plist_target" && ! -L "$plist_target" ]]; then
  fail "installed launchd property list is missing; repair with install-service.sh: $plist_target"
fi
needs_replacement=0
if ! plist_matches "$plist_target" "$plist_source"; then
  if [[ -z "$previous_source" ]]; then
    fail "installed property list differs from this package; pass --previous <previous-release-plist> to prove its provenance: $plist_target"
  fi
  plist_matches "$plist_target" "$previous_source" ||
    fail "installed property list matches neither this package nor the previous package and is not replaced: $plist_target"
  needs_replacement=1
fi
readonly needs_replacement

if [[ -e "$previous_staged" || -L "$previous_staged" ||
      -e "$temporary_staged" || -L "$temporary_staged" ]]; then
  fail "refusing to replace upgrade staging state: $plist_target"
fi

transaction_active=1
trap rollback_upgrade EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if daemon_is_loaded; then
  stopped_service=1
  run_tool launchctl bootout "system/${label}"
fi

if [[ "$needs_replacement" -eq 1 ]]; then
  staged_previous=1
  run_tool ln "$plist_target" "$previous_staged"
  run_tool cmp -s "$previous_source" "$previous_staged" ||
    fail "staged previous property list changed during upgrade: $plist_target"
  staged_temporary=1
  run_tool install -o root -g wheel -m 0600 "$plist_source" "$temporary_staged"
  run_tool cmp -s "$plist_source" "$temporary_staged" ||
    fail "staged property list changed during publication: $plist_target"
  run_tool rm "$plist_target"
  published_new=1
  run_tool ln "$temporary_staged" "$plist_target"
  run_tool rm "$temporary_staged"
  staged_temporary=0
  plist_matches "$plist_target" "$plist_source" 2 ||
    fail "installed property list changed during publication: $plist_target"
fi

bootstrap_attempted=1
run_tool launchctl bootstrap system "$plist_target"
daemon_is_loaded ||
  fail "${label} is not loaded after bootstrap; inspect launchctl print system/${label}"

# Past this point the new installation is verified and loaded; the staged
# previous plist is recovery material that no longer describes the machine,
# so its removal must not trigger a rollback.
upgrade_committed=1
trap - EXIT
staging_retained=0
if [[ "$staged_previous" -eq 1 ]]; then
  run_tool rm "$previous_staged" || staging_retained=1
fi

if [[ "$needs_replacement" -eq 1 ]]; then
  echo "upgraded; replaced ${label}.plist and restarted the daemon"
else
  echo "upgraded; the property list already matches this package, daemon restarted"
fi
if [[ "$staging_retained" -eq 1 ]]; then
  echo "upgrade succeeded but staging cleanup was incomplete; remove ${previous_staged} before the next upgrade" >&2
  exit 1
fi
