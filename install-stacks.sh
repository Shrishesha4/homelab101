#!/usr/bin/env bash
# install-stacks.sh
# Interactive small TUI to choose which stacks under services/docker to bring up.
# - Checks for docker, installs Docker Desktop on macOS via Homebrew if missing
# - Lists directories under services/docker
# - Prompts user to choose one or many (comma-separated), or 'all'
# - Runs docker compose up -d (prefers `docker compose` then `docker-compose`)

set -o errexit
set -o pipefail
set -o nounset

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$BASE_DIR/services/docker"
TIMEOUT_DOCKER_START=180

usage() {
  cat <<EOF
Usage: $0 [--all|-a] [--yes|-y] [--help|-h]

Options:
  -a, --all    Select and install all stacks automatically (non-interactive)
  -y, --yes    Auto-confirm prompts (useful with --all)
  -h, --help   Show this help and exit

This script will:
  - Ensure Docker is installed (on macOS it will use Homebrew to install Docker Desktop)
  - List folders in services/docker and prompt which ones to start (or start all)
  - Run "docker compose up -d" (or "docker-compose up -d") in each selected folder

Note: Installing Docker Desktop on macOS requires Homebrew and may require user interaction.
EOF
}

# Parse args
AUTO_ALL=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all) AUTO_ALL=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  local prompt="$1"
  read -r -p "$prompt [y/N]: " resp
  case "$resp" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

error() {
  echo "ERROR: $*" >&2
}

info() {
  echo "INFO: $*"
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  error "Homebrew is required to install Docker Desktop on macOS but was not found."
  echo
  echo "Install Homebrew manually then re-run this script. Example (paste in a terminal):"
  echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  echo
  exit 1
}

install_docker_macos() {
  info "Installing Docker Desktop via Homebrew Cask..."
  ensure_brew
  if brew list --cask docker >/dev/null 2>&1; then
    info "brew cask reports Docker already installed."
  else
    if ! confirm "Proceed to install Docker Desktop using Homebrew?"; then
      error "User declined Docker installation. Exiting."
      exit 1
    fi
    brew install --cask docker
  fi
  info "Opening Docker.app to start the Docker engine — you may be prompted for permissions."
  open -a Docker || true
  info "Waiting up to ${TIMEOUT_DOCKER_START}s for Docker to become available..."
  local waited=0
  while ! docker info >/dev/null 2>&1; do
    if (( waited >= TIMEOUT_DOCKER_START )); then
      error "Timed out waiting for Docker to start. Check Docker Desktop and try again."
      exit 1
    fi
    sleep 2
    (( waited += 2 ))
  done
  info "Docker is available."
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker CLI found. Verifying it can talk to the daemon..."
    if docker info >/dev/null 2>&1; then
      info "Docker daemon is running."
      return 0
    else
      info "Docker CLI found but daemon isn't responding."
    fi
  else
    info "Docker CLI not found."
  fi

  # Only implement macOS installer path (user's environment: macOS)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    install_docker_macos
    return 0
  else
    error "This installer currently supports automatic Docker installation only on macOS."
    exit 1
  fi
}

choose_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

list_service_dirs() {
  if [[ ! -d "$SERVICES_DIR" ]]; then
    error "Services directory not found: $SERVICES_DIR"
    exit 1
  fi
  local arr=()
  while IFS= read -r -d $'\0' d; do
    arr+=("$d")
  done < <(find "$SERVICES_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

  echo "${arr[@]}"
}

prompt_selection() {
  local -n _out=$1
  mapfile -t dirs < <(list_service_dirs)
  if [[ ${#dirs[@]} -eq 0 ]]; then
    error "No service directories found in $SERVICES_DIR"
    exit 1
  fi

  echo "Found the following stacks in $SERVICES_DIR:"
  local i=1
  for d in "${dirs[@]}"; do
    printf "  %2d) %s\n" "$i" "$(basename "$d")"
    ((i++))
  done
  echo "   0) All"

  if [[ $AUTO_ALL -eq 1 ]]; then
    _out=("${dirs[@]}")
    return 0
  fi

  echo
  echo "Enter a selection: a single number (e.g. 2), comma-separated (1,3), ranges (1-3), '0' for all, or 'q' to quit."
  read -r -p "Selection: " sel
  if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
    echo "Aborted by user."; exit 0
  fi

  if [[ "$sel" =~ ^[[:space:]]*0[[:space:]]*$ || "$sel" =~ ^[Aa]ll$ || "$sel" =~ ^[Aa]$ ]]; then
    _out=("${dirs[@]}")
    return 0
  fi

  # parse selections
  IFS=',' read -ra parts <<< "$sel"
  local chosen=()
  for p in "${parts[@]}"; do
    p="${p// /}"
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start=${BASH_REMATCH[1]}
      end=${BASH_REMATCH[2]}
      for ((k=start; k<=end; k++)); do
        idx=$((k-1))
        if (( idx >= 0 && idx < ${#dirs[@]} )); then
          chosen+=("${dirs[$idx]}")
        fi
      done
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      idx=$((p-1))
      if (( idx >= 0 && idx < ${#dirs[@]} )); then
        chosen+=("${dirs[$idx]}")
      else
        echo "Warning: ignoring invalid selection: $p"
      fi
    else
      echo "Warning: ignoring unknown token: $p"
    fi
  done

  # deduplicate preserve order
  local -A seen=()
  local final=()
  for d in "${chosen[@]}"; do
    if [[ -z "${seen[$d]:-}" ]]; then
      seen[$d]=1
      final+=("$d")
    fi
  done
  _out=("${final[@]}")
}

run_compose_for() {
  local dir="$1"
  info "Processing: $(basename "$dir")"
  if [[ ! -f "$dir/docker-compose.yml" && ! -f "$dir/docker-compose.yaml" ]]; then
    error "No docker-compose.yml or docker-compose.yaml found in $dir — skipping."
    return 1
  fi

  local compose_cmd
  compose_cmd=$(choose_compose_command)
  if [[ -z "$compose_cmd" ]]; then
    error "No docker compose command found (tried 'docker compose' and 'docker-compose')."
    return 1
  fi

  echo
  echo "--- Running in $dir: $compose_cmd up -d ---"
  (cd "$dir" && $compose_cmd up -d)
  echo "--- Done: $(basename "$dir") ---"
}

main() {
  ensure_docker

  mapfile -t selected_dirs
  prompt_selection selected_dirs

  if [[ ${#selected_dirs[@]} -eq 0 ]]; then
    info "No stacks selected. Exiting."
    exit 0
  fi

  echo
  echo "Selected stacks to start:"
  for s in "${selected_dirs[@]}"; do
    echo "  - $(basename "$s")"
  done

  if ! confirm "Proceed to run docker compose up -d for the above?"; then
    info "Aborted by user."; exit 0
  fi

  local failures=0
  for s in "${selected_dirs[@]}"; do
    if ! run_compose_for "$s"; then
      ((failures++))
    fi
  done

  if (( failures > 0 )); then
    error "Completed with ${failures} failures. Check output above."
    exit 1
  fi

  info "All selected stacks started successfully (or were already running)."
}

main
