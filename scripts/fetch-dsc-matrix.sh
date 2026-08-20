#!/bin/zsh

set -u
setopt NO_NOMATCH

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly SCRIPT_PATH="${0:A}"
readonly REPO_ROOT="${SCRIPT_PATH:h:h}"
readonly VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-dsc-patterns.py"
readonly DSC_ROOT="${DSC_ROOT:-/Users/82flex/Desktop/dyld}"
readonly DEVICE="${DSC_DEVICE:-iPhone15,2}"
readonly ARCH="${DSC_ARCH:-arm64e}"
readonly RETRY_DELAY="${DSC_RETRY_DELAY:-30}"
readonly RETRY_LIMIT="${DSC_RETRY_LIMIT:-0}"
readonly LOG_FILE="$DSC_ROOT/.dsc-matrix-fetch.log"
readonly PID_FILE="$DSC_ROOT/.dsc-matrix-fetch.pid"

readonly -a DEFAULT_VERSIONS=(
  16.0
  16.4
  17.4
  17.7
  18.0
  18.2
)

usage() {
  print -r -- "Usage: ${SCRIPT_PATH:t} {run|fetch|status|stop} [iOS versions...]"
  print -r -- ""
  print -r -- "With no versions, run/fetch uses the sparse matrix: ${DEFAULT_VERSIONS[*]}"
  print -r -- "fetch downloads and extracts caches but defers pattern verification."
  print -r -- "Supported additions: 16.1 16.2 16.3 18.1"
  print -r -- ""
  print -r -- "Environment overrides:"
  print -r -- "  DSC_ROOT         output root (default: /Users/82flex/Desktop/dyld)"
  print -r -- "  DSC_DEVICE       device identifier (default: iPhone15,2)"
  print -r -- "  DSC_ARCH         DSC architecture (default: arm64e)"
  print -r -- "  DSC_RETRY_DELAY  seconds between retries (default: 30)"
  print -r -- "  DSC_RETRY_LIMIT  attempts per download, 0 means unlimited (default: 0)"
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  print -r -- "[$(timestamp)] $*"
}

build_for_version() {
  case "$1" in
    16.0) print -r -- 20A362 ;;
    16.1) print -r -- 20B82 ;;
    16.2) print -r -- 20C65 ;;
    16.3) print -r -- 20D47 ;;
    16.4) print -r -- 20E247 ;;
    17.4) print -r -- 21E219 ;;
    17.7) print -r -- 21H16 ;;
    18.0) print -r -- 22A3354 ;;
    18.1) print -r -- 22B83 ;;
    18.2) print -r -- 22C152 ;;
    *)
      log "ERROR unsupported iOS version: $1"
      return 1
      ;;
  esac
}

pid_is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  local command
  pid="$(<"$PID_FILE")"
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null)"
  [[ "$command" == *"${SCRIPT_PATH:t}"* ]]
}

remove_own_pid_file() {
  [[ -f "$PID_FILE" ]] || return 0
  local recorded_pid
  recorded_pid="$(<"$PID_FILE")"
  if [[ "$recorded_pid" == "$$" ]]; then
    rm -f -- "$PID_FILE"
  fi
}

handle_termination() {
  log "Matrix interrupted; partial downloads remain resumable"
  remove_own_pid_file
  exit 143
}

safe_remove_staging() {
  local staging="$1"
  case "$staging" in
    "$DSC_ROOT"/.extract_*) rm -rf -- "$staging" ;;
    *)
      log "ERROR refusing to remove unexpected staging path: $staging"
      return 1
      ;;
  esac
}

download_ipsw() {
  local version="$1"
  local build="$2"
  local ipsw="$3"
  local attempt=1

  while true; do
    log "Downloading iOS $version ($build), attempt $attempt"
    if ipsw download ipsw \
      --device "$DEVICE" \
      --build "$build" \
      --output "$DSC_ROOT" \
      --confirm \
      --resume-all \
      --no-color; then
      if [[ -f "$ipsw" ]]; then
        log "Download complete: ${ipsw:t}"
        return 0
      fi
      log "WARN downloader exited successfully but ${ipsw:t} is absent"
    else
      log "WARN download interrupted for iOS $version ($build)"
    fi

    if (( RETRY_LIMIT > 0 && attempt >= RETRY_LIMIT )); then
      log "ERROR retry limit reached for iOS $version ($build)"
      return 1
    fi
    attempt=$((attempt + 1))
    log "Retrying in ${RETRY_DELAY}s; the .download file will be resumed"
    sleep "$RETRY_DELAY"
  done
}

extract_dsc() {
  local version="$1"
  local build="$2"
  local ipsw="$3"
  local final_dir="$4"
  local staging
  local cache
  local cache_parent

  staging="$(mktemp -d "$DSC_ROOT/.extract_${version}_${build}_${DEVICE//,/_}.XXXXXX")" || return 1
  log "Extracting $ARCH DSC from ${ipsw:t}"
  if ! ipsw extract \
    --dyld \
    --dyld-arch "$ARCH" \
    --output "$staging" \
    --no-color \
    "$ipsw"; then
    log "ERROR extraction failed; preserving IPSW and staging directory: $staging"
    return 1
  fi

  cache="$(find "$staging" -type f -name "dyld_shared_cache_$ARCH" -print -quit)"
  if [[ -z "$cache" ]]; then
    log "ERROR extracted tree contains no dyld_shared_cache_$ARCH: $staging"
    return 1
  fi

  if [[ -d "$final_dir" ]] && [[ -n "$(find "$final_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log "ERROR destination exists and is not empty: $final_dir"
    return 1
  fi

  mkdir -p "$final_dir" || return 1
  cache_parent="${cache:h}"
  find "$cache_parent" -mindepth 1 -maxdepth 1 -exec mv {} "$final_dir/" \;

  if [[ ! -f "$final_dir/dyld_shared_cache_$ARCH" ]]; then
    log "ERROR main cache was not installed into $final_dir"
    return 1
  fi

  safe_remove_staging "$staging" || return 1
  log "DSC ready: $final_dir"
}

verify_dsc() {
  local version="$1"
  local build="$2"
  local cache="$3"

  log "Verifying patterns for iOS $version ($build)"
  if python3 "$VERIFY_SCRIPT" "$cache"; then
    log "PASS iOS $version ($build)"
    return 0
  fi
  log "MISMATCH iOS $version ($build); intermediate versions should be sampled"
  return 1
}

process_version() {
  local version="$1"
  local should_verify="$2"
  local build
  local final_dir
  local cache
  local ipsw
  local result=0

  build="$(build_for_version "$version")" || return 1
  final_dir="$DSC_ROOT/iOS_${version}__${build}__${DEVICE}"
  cache="$final_dir/dyld_shared_cache_$ARCH"
  ipsw="$DSC_ROOT/${DEVICE}_${version}_${build}_Restore.ipsw"

  if [[ ! -f "$cache" ]]; then
    download_ipsw "$version" "$build" "$ipsw" || return 1
    extract_dsc "$version" "$build" "$ipsw" "$final_dir" || return 1
  else
    log "DSC already exists; skipping download: $final_dir"
  fi

  if [[ "$should_verify" == true ]]; then
    verify_dsc "$version" "$build" "$cache" || result=1
  else
    log "Verification deferred for iOS $version ($build)"
  fi

  if [[ -f "$ipsw" ]]; then
    rm -f -- "$ipsw"
    log "Removed extracted IPSW: ${ipsw:t}"
  fi
  return "$result"
}

run_matrix() {
  local should_verify="$1"
  shift
  local -a versions
  local -a failures=()
  local version

  mkdir -p "$DSC_ROOT" || return 1
  if (( $# == 0 )); then
    versions=("${DEFAULT_VERSIONS[@]}")
  else
    versions=("$@")
  fi

  print -r -- "$$" >| "$PID_FILE"
  trap remove_own_pid_file EXIT
  trap handle_termination INT TERM
  exec >> "$LOG_FILE" 2>&1

  log "Matrix started: device=$DEVICE arch=$ARCH versions=${versions[*]}"
  for version in "${versions[@]}"; do
    if ! process_version "$version" "$should_verify"; then
      failures+=("$version")
      log "Continuing after failure/mismatch: iOS $version"
    fi
  done

  if (( ${#failures[@]} > 0 )); then
    log "Matrix completed with failures/mismatches: ${failures[*]}"
    return 1
  fi
  log "Matrix completed successfully: ${versions[*]}"
}

show_status() {
  if pid_is_running; then
    print -r -- "running (PID $(<"$PID_FILE"))"
  else
    print -r -- "not running"
  fi
  if [[ -f "$LOG_FILE" ]]; then
    print -r -- ""
    tail -n 20 "$LOG_FILE"
  fi
}

stop_background() {
  if ! pid_is_running; then
    print -r -- "DSC matrix fetch is not running."
    return 0
  fi
  local pid
  pid="$(<"$PID_FILE")"
  kill "$pid"
  print -r -- "Sent TERM to DSC matrix fetch (PID $pid); partial downloads are resumable."
}

main() {
  local action="${1:-}"
  if (( $# > 0 )); then
    shift
  fi

  case "$action" in
    run) run_matrix true "$@" ;;
    fetch) run_matrix false "$@" ;;
    status) show_status ;;
    stop) stop_background ;;
    -h|--help|help|'') usage ;;
    *)
      print -r -- "Unknown action: $action"
      usage
      return 2
      ;;
  esac
}

main "$@"
