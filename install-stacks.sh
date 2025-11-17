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
  [--dry-run|-n]

Options:
  -a, --all    Select and install all stacks automatically (non-interactive)
  -y, --yes    Auto-confirm prompts (useful with --all)
  -n, --dry-run  Show what would be done but don't execute commands
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
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all) AUTO_ALL=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    # In dry-run mode, auto-confirm but still don't execute actions.
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
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "DRY-RUN: brew install --cask docker"
    else
      brew install --cask docker
    fi
  fi
  info "Opening Docker.app to start the Docker engine — you may be prompted for permissions."
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN: open -a Docker"
  else
    open -a Docker || true
  fi
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

install_docker_linux() {
  info "Installing Docker Engine on Linux (APT/Debian/Ubuntu path)..."
  if ! command -v apt-get >/dev/null 2>&1; then
    error "Automatic Linux install currently only supports apt-based systems (Ubuntu/Debian)."
    exit 1
  fi

  if ! confirm "Proceed to install Docker Engine on this machine?"; then
    error "User declined Docker installation. Exiting."
    exit 1
  fi

  # Commands to run
  cmds=(
    "sudo apt-get update"
    "sudo apt-get install -y ca-certificates curl gnupg lsb-release"
    "curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo \"$ID\")/gpg | sudo gpg --dearmour -o /usr/share/keyrings/docker-archive-keyring.gpg"
    "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo \"$ID\") $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
    "sudo apt-get update"
    "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
    "sudo systemctl enable --now docker"
  )

  for c in "${cmds[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "DRY-RUN: $c"
    else
      eval "$c"
    fi
  done

  # Add user to docker group so they can run without sudo
  target_user="${SUDO_USER:-${USER:-$(whoami)}}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN: sudo groupadd docker || true"
    echo "DRY-RUN: sudo usermod -aG docker $target_user"
  else
    sudo groupadd docker || true
    sudo usermod -aG docker "$target_user" || true
    info "Added $target_user to 'docker' group. You may need to log out and back in for this to take effect."
  fi

  # Wait for docker, but check systemd service status to fail fast with diagnostics
  info "Waiting up to ${TIMEOUT_DOCKER_START}s for Docker to become available..."
  local waited=0
  local tried_start=0
  while true; do
    # Use sudo docker info to bypass group membership propagation delays
    if sudo docker info >/dev/null 2>&1; then
      info "Docker is available."
      break
    fi

    # Check systemd service status if available
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-active --quiet docker; then
        # service active but docker info still failing; keep waiting
        :
      elif systemctl is-failed --quiet docker; then
        error "docker.service has failed. Showing recent logs to help debugging:" 
        if command -v journalctl >/dev/null 2>&1; then
          echo "--- docker.service logs (last 200 lines) ---"
          sudo journalctl -u docker --no-pager -n 200 || true
        fi
        error "docker.service failed to start. Inspect the logs above and run 'sudo systemctl status docker' or check '/var/log/syslog' depending on your distro."
        exit 1
      else
        # service not active; try to start it once
        if (( tried_start == 0 )); then
          info "Attempting to start docker.service..."
          if [[ $DRY_RUN -eq 1 ]]; then
            echo "DRY-RUN: sudo systemctl start docker"
          else
            sudo systemctl start docker || true
          fi
          tried_start=1
        fi
      fi
    fi

    if (( waited >= TIMEOUT_DOCKER_START )); then
      error "Timed out waiting for Docker to start. Check service status and logs."
      if command -v journalctl >/dev/null 2>&1; then
        echo "--- docker.service logs (last 200 lines) ---"
        sudo journalctl -u docker --no-pager -n 200 || true
      fi
      exit 1
    fi

    sleep 2
    (( waited += 2 ))
  done
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker CLI found. Verifying it can talk to the daemon..."
    # Capture output to distinguish permission errors from daemon-not-running
    docker_out=""
    if docker_out=$(docker info 2>&1); then
      info "Docker daemon is running."
      return 0
    else
      # docker info failed; examine output
      if echo "$docker_out" | grep -qi "permission denied" || echo "$docker_out" | grep -qi "connect: permission denied"; then
        error "Docker CLI cannot access the daemon socket: permission denied."
        ls -l /var/run/docker.sock 2>/dev/null || true
        echo
        echo "You can try one of the following:
  - Run the command with sudo (e.g. 'sudo ./install-stacks.sh')
  - Re-login or run 'newgrp docker' to pick up docker group membership
  - Ensure your user is in the 'docker' group (sudo usermod -aG docker <user>) and then re-login
"
        if [[ $ASSUME_YES -eq 1 ]]; then
          info "ASSUME_YES set: attempting 'newgrp docker' to pick up group membership for this run..."
          if command -v newgrp >/dev/null 2>&1; then
            if newgrp docker -c "docker info" >/dev/null 2>&1; then
              info "Succeeded after newgrp."
              return 0
            else
              info "newgrp did not allow access. You may need to re-login or run with sudo."
            fi
          fi
        fi
        exit 1
      else
        info "Docker CLI found but daemon isn't responding."
      fi
    fi
  else
    info "Docker CLI not found."
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN: Docker not available (would install but not executing in dry-run)."
    return 0
  fi

  # At this point docker command is missing or docker daemon not responding.
  case "$(uname -s)" in
    Darwin)
      install_docker_macos
      return 0
      ;;
    Linux)
      # If systemd is present and docker.service exists, try to start it first instead of reinstalling
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q '^docker.service' || systemctl status docker >/dev/null 2>&1 || systemctl status docker 2>&1 | grep -q 'Loaded: not-found'; then
          info "Docker systemd unit appears present. Attempting to start docker.service."
          if ! confirm "Start docker.service now?"; then
            error "User declined to start docker.service. Exiting."
            exit 1
          fi
          if [[ $DRY_RUN -eq 1 ]]; then
            echo "DRY-RUN: sudo systemctl start docker"
            return 0
          else
            sudo systemctl start docker || true
          fi

          # Wait for docker to become available (reuse logic from install path)
          info "Waiting up to ${TIMEOUT_DOCKER_START}s for Docker to become available..."
          waited=0
          while true; do
            if sudo docker info >/dev/null 2>&1; then
              info "Docker is available."
              return 0
            fi
            if systemctl is-failed --quiet docker; then
              error "docker.service failed to start. Showing logs:" 
              sudo journalctl -u docker --no-pager -n 200 || true
              exit 1
            fi
            if (( waited >= TIMEOUT_DOCKER_START )); then
              error "Timed out waiting for Docker to start."
              sudo journalctl -u docker --no-pager -n 200 || true
              exit 1
            fi
            sleep 2
            (( waited += 2 ))
          done
        else
          # systemd present but docker unit not found: fall back to install
          install_docker_linux
          return 0
        fi
      else
        # No systemctl: fall back to install path
        install_docker_linux
        return 0
      fi
      ;;
    *)
      error "This installer supports automatic Docker installation only on macOS and Debian/Ubuntu Linux."
      exit 1
      ;;
  esac
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

  # Print one directory per line to be portable across bash versions
  for d in "${arr[@]}"; do
    printf '%s\n' "$d"
  done
}

prompt_selection() {
  # Prints selected directories (one per line) to stdout.
  # Caller should capture output into an array.
  dirs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    dirs+=("$line")
  done < <(list_service_dirs)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    error "No service directories found in $SERVICES_DIR"
    exit 1
  fi

  if [[ $AUTO_ALL -eq 1 ]]; then
    for d in "${dirs[@]}"; do
      printf '%s\n' "$d"
    done
    return 0
  fi

  # Print interactive menu to stderr so callers can capture stdout safely
  echo "Found the following stacks in $SERVICES_DIR:" >&2
  i=1
  for d in "${dirs[@]}"; do
    printf "  %2d) %s\n" "$i" "$(basename "$d")" >&2
    i=$((i+1))
  done
  echo "   0) All" >&2

  echo >&2
  echo "Enter a selection: a single number (e.g. 2), comma-separated (1,3), ranges (1-3), '0' for all, or 'q' to quit." >&2
  printf "Selection: " >&2
  read -r sel
  if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
    echo "Aborted by user." >&2
    exit 0
  fi

  if [[ "$sel" =~ ^[[:space:]]*0[[:space:]]*$ || "$sel" =~ ^[Aa]ll$ || "$sel" =~ ^[Aa]$ ]]; then
    for d in "${dirs[@]}"; do
      printf '%s\n' "$d"
    done
    return 0
  fi

  # parse selections (comma separated, ranges allowed)
  IFS=',' read -ra parts <<< "$sel"
  chosen=()
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
        echo "Warning: ignoring invalid selection: $p" >&2
      fi
    else
      echo "Warning: ignoring unknown token: $p" >&2
    fi
  done

  # deduplicate while preserving order (portable)
  final=()
  for d in "${chosen[@]}"; do
    skip=0
    for e in "${final[@]}"; do
      if [[ "$e" == "$d" ]]; then
        skip=1
        break
      fi
    done
    if [[ $skip -eq 0 ]]; then
      final+=("$d")
    fi
  done

  for d in "${final[@]}"; do
    printf '%s\n' "$d"
  done
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
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN: (cd '$dir' && $compose_cmd up -d)"
    echo "--- Done: $(basename "$dir") ---"
    return 0
  fi

  # Try running normally and capture output/errors
  out=""
  rc=0
  out=$(cd "$dir" && $compose_cmd up -d 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    echo "--- Done: $(basename "$dir") ---"
    return 0
  fi

  # If permission denied to docker socket, try to recover: show diagnostics and retry with newgrp or sudo
  if echo "$out" | grep -qi "permission denied" || echo "$out" | grep -qi "connect: permission denied"; then
    error "Permission denied talking to the Docker daemon socket. Trying remedies."
    echo "Socket ownership:" >&2
    ls -l /var/run/docker.sock 2>/dev/null || true

    # Try newgrp docker to pick up group membership without requiring logout
    if command -v newgrp >/dev/null 2>&1; then
      info "Retrying using 'newgrp docker' to pick up docker group membership for this session..."
      if newgrp docker -c "cd '$dir' && $compose_cmd up -d" >/dev/null 2>&1; then
        info "Succeeded with newgrp docker."
        echo "--- Done: $(basename "$dir") ---"
        return 0
      else
        info "newgrp attempt failed or still lacked permission."
      fi
    fi

    # Fallback: run with sudo
    info "Retrying with sudo..."
    if sudo bash -c "cd '$dir' && $compose_cmd up -d"; then
      info "Succeeded with sudo."
      echo "--- Done: $(basename "$dir") ---"
      return 0
    else
      error "Retry with sudo also failed. Output from first attempt below:\n$out"
      return 1
    fi
  else
    # Not a permission error; print output and return failure
    echo "$out" >&2
    return $rc
  fi
}

main() {
  ensure_docker

  selected_dirs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    selected_dirs+=("$line")
  done < <(prompt_selection)

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
