#!/usr/bin/env bash

# ==============================================================================
# Shipyard - Laravel Sail Project Setup Script
# ==============================================================================
# Sets up Laravel Sail projects with automatic port assignment, SSL certificates,
# and local domain configuration. Manages a shared registry to prevent port
# conflicts across multiple projects.
#
# Usage: shipyard [options]
# ==============================================================================

set -euo pipefail

# ==============================================================================
# VERSION
# ==============================================================================

readonly VERSION="0.2.3"

# ==============================================================================
# CONSTANTS & CONFIGURATION
# ==============================================================================

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_COMPOSE_NOT_FOUND=1
readonly EXIT_ENV_NOT_FOUND=2
readonly EXIT_ENV_HAS_PORTS=3
readonly EXIT_LOCK_TIMEOUT=4
readonly EXIT_REGISTRY_WRITE_FAILED=5
readonly EXIT_ENV_WRITE_FAILED=6
readonly EXIT_NO_PORTS_AVAILABLE=7
readonly EXIT_ALREADY_REGISTERED=8
readonly EXIT_REGISTRY_CORRUPTED=9
readonly EXIT_DOCKER_NOT_INSTALLED=10
readonly EXIT_DOCKER_NOT_RUNNING=11
readonly EXIT_USER_CANCELLED=130

# File paths
readonly REGISTRY_DIR="$HOME/.config/shipyard"
readonly REGISTRY_FILE="$REGISTRY_DIR/projects.conf"
readonly LOCK_FILE="$REGISTRY_DIR/projects.conf.lock"
readonly LOCK_TIMEOUT=10
readonly COMPOSE_FILE="docker-compose.yml"
readonly ENV_FILE=".env"

# Valet/Herd configuration
readonly VALET_CERT_DIR="$HOME/.config/valet/Certificates"
readonly HERD_CERT_DIR="$HOME/Library/Application Support/Herd/config/valet/Certificates"
readonly PROJECT_CERT_DIR="certificates"
readonly DOMAIN_TLD="test"

# Lock state
readonly LOCK_FD=200
LOCK_ACQUIRED=false

# Registry storage (associative arrays simulated with naming convention)
declare -a REGISTRY_PROJECTS=()
declare -a REGISTRY_ALL_PORTS=()

# Port assignments for current project
declare -A PORT_ASSIGNMENTS=()

# Project state
PROJECT_NAME=""

# Domain registration state
DOMAIN_REGISTERED=false
REGISTERED_DOMAIN=""
SELECTED_DEV_TOOL=""  # "valet" or "herd"
VALET_AVAILABLE=false
HERD_AVAILABLE=false

# User input collection (collected upfront)
declare -a COMPOSER_REPO_USERNAMES=()
declare -a COMPOSER_REPO_PASSWORDS=()
REGISTER_DOMAIN=false
USER_DOMAIN_NAME=""
RUN_POST_SETUP=""

# ==============================================================================
# COLORS & STYLING
# ==============================================================================

# Check if colors should be disabled
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    # Color codes
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly GREEN='\033[0;32m'
    readonly RED='\033[0;31m'
    readonly YELLOW='\033[1;33m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m' # No Color
else
    # No colors
    readonly BLUE=""
    readonly CYAN=""
    readonly GREEN=""
    readonly RED=""
    readonly YELLOW=""
    readonly BOLD=""
    readonly DIM=""
    readonly NC=""
fi

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

log_info() {
    echo "$1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

exit_with_error() {
    local exit_code=$1
    shift
    log_error "$*"
    exit "$exit_code"
}

# ==============================================================================
# HELP & VERSION FUNCTIONS
# ==============================================================================

show_version() {
    echo "Shipyard v$VERSION"
}

show_help() {
    show_title
    echo ""

    cat << EOF
Usage:
  shipyard init         Initialize a Laravel Sail project
  shipyard list         List all registered projects
  shipyard cleanup      Clean up Docker resources and stale projects
  shipyard [options]

Commands:
  init                  Set up the Laravel Sail project in current directory
                        (automatic port assignment, domain configuration, etc.)
  list                  Show all registered projects from config file
  cleanup               Clean up stale projects from registry

Options:
  --version, -v         Show version
  --update              Update to latest version
  --help, -h            Show this help

Examples:
  shipyard init         # Set up project in current directory
  shipyard list         # Show all registered projects
  shipyard cleanup      # Clean up Docker resources and stale projects
  shipyard --update     # Update Shipyard to latest version

Features:
  • Automatic port assignment with conflict detection
  • Local domain registration (Valet/Herd)
  • SSL certificate management
  • Composer installation with private repo support
  • Interactive setup wizard

Documentation: https://github.com/wotzebra/shipyard
EOF
}

show_title() {
    echo -e "${CYAN}"
    cat << 'EOF'
   _____ __    _                             _
  / ___// /_  (_)___  __  ______ ___________//
  \__ \/ __ \/ / __ \/ / / / __ `/ ___/ __  /
 ___/ / / / / / /_/ / /_/ / /_/ / /  / /_/ /
/____/_/ /_/_/ .___/\__, /\__,_/_/   \__,_/
            /_/    /____/
EOF
    echo -e "${NC}"
    echo -e "⚓ ${DIM}v${VERSION} - Laravel Sail Project Setup${NC}"
    echo ""
}

# ==============================================================================
# UPDATE FUNCTIONS
# ==============================================================================

fetch_latest_version() {
    # Fetch latest version from GitHub API
    # Args:
    #   $1 - timeout in seconds (optional, default: no timeout)
    # Returns:
    #   0 if successful (sets LATEST_VERSION variable)
    #   1 if failed

    local timeout_args=""
    if [ -n "${1:-}" ]; then
        timeout_args="--connect-timeout $1 --max-time $1"
    fi

    local API_RESPONSE
    API_RESPONSE=$(curl -fsSL $timeout_args https://api.github.com/repos/wotzebra/shipyard/releases/latest 2>/dev/null)

    if [ -z "$API_RESPONSE" ]; then
        return 1
    fi

    # Extract version tag (remove 'v' prefix)
    LATEST_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        return 1
    fi

    return 0
}

perform_update() {
    # Perform the actual update download and installation
    # Args:
    #   $1 - latest version string

    local latest_version="$1"

    log_info "Updating to v$latest_version..."

    # Get script path
    local SCRIPT_PATH
    SCRIPT_PATH=$(realpath "$0")
    local TEMP_FILE="${SCRIPT_PATH}.tmp"

    # Download latest release
    local DOWNLOAD_URL="https://github.com/wotzebra/shipyard/releases/download/v${latest_version}/shipyard.sh"

    if ! curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_FILE"; then
        log_error "Failed to download update"
        rm -f "$TEMP_FILE"
        echo ""
        echo "Download URL: $DOWNLOAD_URL"
        echo ""
        echo "Please try again or download manually from:"
        echo "https://github.com/wotzebra/shipyard/releases"
        exit 1
    fi

    # Verify download is not empty
    if [ ! -s "$TEMP_FILE" ]; then
        log_error "Downloaded file is empty"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    # Replace current script atomically
    chmod +x "$TEMP_FILE"
    if ! mv "$TEMP_FILE" "$SCRIPT_PATH"; then
        log_error "Failed to replace script"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    echo ""
    log_success "Successfully updated to v$latest_version"
}

update_self() {
    log_info "Checking for updates..."

    if ! fetch_latest_version; then
        log_error "Could not fetch latest version from GitHub"
        echo ""
        echo "This might be due to:"
        echo "  • Network connectivity issues"
        echo "  • GitHub API rate limiting"
        echo ""
        echo "Try again later or check: https://github.com/wotzebra/shipyard/releases"
        exit 1
    fi

    # Compare versions
    if [ "$VERSION" = "$LATEST_VERSION" ]; then
        log_success "Already at latest version (v$VERSION)"
        return 0
    fi

    echo ""
    log_info "Current version: v$VERSION"
    log_info "Latest version:  v$LATEST_VERSION"
    echo ""

    perform_update "$LATEST_VERSION"

    echo ""
    echo "Run 'shipyard --version' to verify"
}

check_for_updates() {
    # Silently check for updates (don't block on failure)
    # Uses 5-second timeout to avoid hanging

    if ! fetch_latest_version 5; then
        # Silently continue if check fails
        return 0
    fi

    # If we're on the latest version, continue silently
    if [ "$VERSION" = "$LATEST_VERSION" ]; then
        return 0
    fi

    # Show update warning
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  UPDATE AVAILABLE${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}Current version:${NC} v$VERSION"
    echo -e "  ${BOLD}Latest version:${NC}  ${GREEN}v$LATEST_VERSION${NC}"
    echo ""
    echo "  It's recommended to update before continuing."
    echo ""

    # Prompt user
    read -r -p "Do you want to update now? [y/N] " response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo ""
        perform_update "$LATEST_VERSION"
        echo ""
        echo "Please run 'shipyard' again to continue with the updated version."
        exit 0
    fi

    echo ""
    echo "Continuing with current version..."
    echo ""
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

parse_arguments() {
    case "${1:-}" in
        init)
            # Run main setup
            return 0
            ;;
        cleanup)
            # Run cleanup command
            run_cleanup_command
            exit 0
            ;;
        list)
            # List registered projects
            run_list_command
            exit 0
            ;;
        --version|-v)
            show_version
            exit 0
            ;;
        --update)
            update_self
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        "")
            # No arguments, show help
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown command or option: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# ==============================================================================
# CLEANUP & LOCKING FUNCTIONS
# ==============================================================================

cleanup_on_exit() {
    local exit_code=$?

    # Release lock if acquired
    release_lock

    # If interrupted (Ctrl+C), print a message
    if [ $exit_code -eq 130 ]; then
        echo ""
        log_info "Script interrupted by user. Cleaning up..."
    fi
}

handle_interrupt() {
    echo ""
    log_info "Received interrupt signal (Ctrl+C). Exiting..."
    exit $EXIT_USER_CANCELLED
}

acquire_lock() {
    # Create directory if it doesn't exist
    mkdir -p "$REGISTRY_DIR"

    # Use mkdir as atomic lock (works on all Unix systems without flock)
    local attempts=0
    local max_attempts=$((LOCK_TIMEOUT * 10))  # Check every 0.1 seconds

    while [ $attempts -lt $max_attempts ]; do
        # Try to create lock directory (atomic operation)
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            LOCK_ACQUIRED=true
            return 0
        fi

        # Lock exists, wait and retry
        sleep 0.1
        attempts=$((attempts + 1))
    done

    # Timeout reached
    exit_with_error $EXIT_LOCK_TIMEOUT \
        "Failed to acquire lock after ${LOCK_TIMEOUT}s. Another process may be using the port registry."
}

release_lock() {
    if [ "$LOCK_ACQUIRED" = true ]; then
        # Remove lock directory
        rmdir "$LOCK_FILE" 2>/dev/null || true
        LOCK_ACQUIRED=false
    fi
}

# ==============================================================================
# VALIDATION FUNCTIONS
# ==============================================================================

validate_docker() {
    # Check if Docker is installed
    if ! command -v docker >/dev/null 2>&1; then
        exit_with_error $EXIT_DOCKER_NOT_INSTALLED \
            "Docker is not installed or not in PATH.
Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
    fi
    log_success "Docker is installed"

    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        exit_with_error $EXIT_DOCKER_NOT_RUNNING \
            "Docker is installed but not running.
Please start Docker Desktop and try again."
    fi
    log_success "Docker is running"
}

check_docker_networks() {
    # Check for Docker network address pool exhaustion
    # This is a common issue when too many unused networks exist

    # Count total bridge networks (excluding default bridge)
    local total_networks
    total_networks=$(docker network ls --filter "driver=bridge" --format "{{.Name}}" 2>/dev/null | grep -v "^bridge$" | wc -l | tr -d ' ')

    # If there are many networks, check if cleanup might help
    if [ "$total_networks" -gt 20 ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  WARNING: Many Docker networks detected (${BOLD}$total_networks${NC}${YELLOW})${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${DIM}Docker may fail to create new networks due to IP address pool exhaustion.${NC}"
        echo -e "  ${DIM}This commonly happens with error:${NC}"
        echo -e "  ${RED}'could not find an available, non-overlapping IPv4 address pool'${NC}"
        echo ""
        echo -e "  Cleaning up unused Docker networks can help prevent this issue."
        echo ""

        read -r -p "Clean up unused networks now? [y/N] " response

        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo ""
            echo "Cleaning up unused Docker networks..."
            local before_count
            before_count=$(docker network ls --filter "driver=bridge" --format "{{.Name}}" 2>/dev/null | grep -v "^bridge$" | wc -l | tr -d ' ')

            if docker network prune -f >/dev/null 2>&1; then
                local after_count
                after_count=$(docker network ls --filter "driver=bridge" --format "{{.Name}}" 2>/dev/null | grep -v "^bridge$" | wc -l | tr -d ' ')
                local removed=$((before_count - after_count))
                log_success "Removed $removed unused network(s)"
            else
                log_error "Failed to clean up networks"
                echo -e "${DIM}You may need to run: docker network prune -f${NC}"
            fi
            echo ""
        else
            echo ""
            echo -e "${DIM}→ Skipping network cleanup. If you encounter network errors, run:${NC}"
            echo -e "${DIM}  docker network prune -f${NC}"
            echo ""
        fi
    fi
}

validate_docker_compose() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        exit_with_error $EXIT_COMPOSE_NOT_FOUND "docker-compose file not found: $COMPOSE_FILE"
    fi
    log_success "docker-compose.yml found"
}

validate_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        # Check if .env.example exists
        if [ -f ".env.example" ]; then
            log_info "Creating .env from .env.example..."
            cp .env.example "$ENV_FILE"
            log_success ".env file created from .env.example"
        else
            exit_with_error $EXIT_ENV_NOT_FOUND \
                ".env file not found and .env.example does not exist.
Please create a .env file or .env.example before running this script."
        fi
    else
        log_success ".env file found"
    fi
}

extract_composer_repositories() {
    # Extract repository URLs from composer.json
    if [ ! -f "composer.json" ]; then
        echo ""
        log_error "composer.json not found in current directory"
        exit 1
    fi

    # Use grep and sed to extract repository URLs (simple parsing, works for most cases)
    # This extracts URLs from the "repositories" array and removes https:// prefix
    grep -A 2 '"type".*"composer"' composer.json | grep '"url"' | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"https?:\/\/([^"]+)".*/\1/'
}

run_composer_install() {
    echo ""
    log_info "=========================================="
    log_info "Installing Composer dependencies..."
    log_info "=========================================="
    echo ""

    # Extract repositories from composer.json
    local repositories=($(extract_composer_repositories))

    if [ ${#repositories[@]} -eq 0 ]; then
        log_info "No private repositories found in composer.json, running composer install..."
        echo ""
        docker run --rm -u "$(id -u):$(id -g)" -v "$(pwd):/var/www/html" -w /var/www/html laravelsail/php84-composer:latest composer install --ignore-platform-reqs

        if [ $? -ne 0 ]; then
            echo ""
            log_error "Composer install failed."
            exit 9
        fi

        log_success "Composer dependencies installed"
        echo ""
        return 0
    fi

    log_info "Found ${#repositories[@]} private repository/repositories, configuring credentials..."
    echo ""

    # Build the composer config commands using pre-collected credentials
    local config_commands=""
    local repo_index=0

    for repo in "${repositories[@]}"; do
        local username="${COMPOSER_REPO_USERNAMES[$repo_index]}"
        local password="${COMPOSER_REPO_PASSWORDS[$repo_index]}"

        # Add to config commands
        if [ -n "$config_commands" ]; then
            config_commands="$config_commands && "
        fi
        config_commands="${config_commands}composer config http-basic.$repo $username $password"

        echo "  ✓ Using credentials for $repo"

        repo_index=$((repo_index + 1))
    done

    # Run composer install with all credentials configured
    echo ""
    log_info "Running composer install via Docker..."
    echo ""

    local full_command="$config_commands && composer install --ignore-platform-reqs"

    docker run --rm -u "$(id -u):$(id -g)" -v "$(pwd):/var/www/html" -w /var/www/html laravelsail/php84-composer:latest bash -c "$full_command"

    if [ $? -ne 0 ]; then
        echo ""
        log_error "Composer install failed. Please check your credentials and try again."
        echo ""
        echo "Command that failed:"
        echo "  docker run --rm -u \"\$(id -u):\$(id -g)\" -v \$(pwd):/var/www/html -w /var/www/html laravelsail/php84-composer:latest bash -c \"$config_commands && composer install --ignore-platform-reqs\""
        exit 9
    fi

    log_success "Composer dependencies installed"
    echo ""
}

check_env_for_ports() {
    local found_ports=()
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Match Docker Sail port variables: APP_PORT, VITE_PORT, FORWARD_*_PORT
        # This specifically targets ports that are managed by this script
        if [[ "$line" =~ (^|[[:space:]])(APP_PORT|VITE_PORT|FORWARD_[A-Z_]*_PORT)[[:space:]]*= ]]; then
            local var_name="${BASH_REMATCH[2]}"
            found_ports+=("  - $var_name (line $line_num)")
        fi
    done < "$ENV_FILE"

    if [ ${#found_ports[@]} -gt 0 ]; then
        log_error ".env already contains port definitions."
        echo "" >&2
        echo "Found these port variables:" >&2
        printf '%s\n' "${found_ports[@]}" >&2
        echo "" >&2
        echo "Please remove all *_PORT variables from .env before running this script." >&2
        exit $EXIT_ENV_HAS_PORTS
    fi

    log_success "No existing port definitions in .env"
}

# ==============================================================================
# PORT CONVERSION FUNCTION (EXISTING LOGIC PRESERVED)
# ==============================================================================

convert_port() {
    local port=$1

    # If port is already 4+ digits and ends with 00, return as-is
    if [ ${#port} -ge 4 ] && [[ $port =~ 00$ ]]; then
        echo "$port"
        return
    fi

    # Convert port to at least 4 digits ending in 00
    if [ ${#port} -eq 2 ]; then
        # 80 -> 8000
        echo "${port}00"
    elif [ ${#port} -eq 3 ]; then
        # 100 -> 10000
        echo "${port}00"
    elif [ ${#port} -eq 4 ]; then
        # 5173 -> 5100
        # Strip last 2 digits and add 00
        echo "$((${port:0:2}00))"
    elif [ ${#port} -gt 4 ]; then
        # For 5+ digit ports, round down to nearest 100
        local base=$((port / 100))
        echo "$((base * 100))"
    else
        # Single digit: 6 -> 6000
        echo "${port}000"
    fi
}

# ==============================================================================
# REGISTRY FUNCTIONS (INI FILE HANDLING)
# ==============================================================================

# Sanitize project name for use in bash variable names (replace - with _)
sanitize_project_name() {
    echo "$1" | tr '-' '_' | tr '.' '_'
}

parse_ini_file() {
    # If registry doesn't exist yet, that's OK (first run)
    if [ ! -f "$REGISTRY_FILE" ]; then
        return 0
    fi

    local current_section=""
    local current_section_sanitized=""
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Section header: [project-name]
        if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            current_section_sanitized=$(sanitize_project_name "$current_section")
            REGISTRY_PROJECTS+=("$current_section")

        # Key=value pair
        elif [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            if [ -z "$current_section" ]; then
                exit_with_error $EXIT_REGISTRY_CORRUPTED \
                    "Registry file is corrupted (line $line_num): Key outside of section"
            fi

            # Store in global variables with naming convention: registry_{project}_{key}
            # Use sanitized name for variable names
            eval "registry_${current_section_sanitized}_${key}=\"${value}\""

            # If this is a port value, add to all ports list
            if [[ "$key" =~ _PORT$ ]] && [[ "$value" =~ ^[0-9]+$ ]]; then
                REGISTRY_ALL_PORTS+=("$value")
            fi

        else
            # Malformed line
            exit_with_error $EXIT_REGISTRY_CORRUPTED \
                "Registry file is corrupted or malformed.

File: $REGISTRY_FILE
Invalid line $line_num: \"$line\"

Please fix the registry file manually or delete it to start fresh."
        fi
    done < "$REGISTRY_FILE"
}

cleanup_stale_projects() {
    # Remove projects from registry whose paths no longer exist

    # If registry doesn't exist, nothing to clean
    if [ ! -f "$REGISTRY_FILE" ]; then
        return 0
    fi

    local projects_to_remove=()
    local removed_count=0

    # Check each project's path
    for project in "${REGISTRY_PROJECTS[@]}"; do
        local project_sanitized=$(sanitize_project_name "$project")
        local path_var="registry_${project_sanitized}_path"
        local project_path="${!path_var}"

        if [ -n "$project_path" ] && [ ! -d "$project_path" ]; then
            projects_to_remove+=("$project")
            log_info "  × Project '$project' path no longer exists: $project_path"

            # Check if project has a domain and proxy service registered
            local domain_var="registry_${project_sanitized}_domain"
            local proxy_var="registry_${project_sanitized}_proxy_service"
            local project_domain="${!domain_var}"
            local project_proxy="${!proxy_var}"

            # Clean up proxy if it exists
            if [ -n "$project_domain" ] && [ -n "$project_proxy" ]; then
                log_info "    Removing proxy: $project_domain (via $project_proxy)"

                # Extract domain name without TLD
                local domain_name="${project_domain%.*}"

                # Run unproxy command silently
                if $project_proxy unproxy "$domain_name" >/dev/null 2>&1; then
                    log_info "    ✓ Proxy removed successfully"
                else
                    log_info "    ! Failed to remove proxy (may have been already removed)"
                fi
            fi

            # Clean up Sail volumes if they exist
            # The project name is already normalized (lowercase, valid Docker Compose format)
            log_info "    Checking for Sail volumes to clean up..."

            # Find all volumes matching the pattern: project_sail-*
            local sail_volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^${project}_sail-" || true)

            if [ -n "$sail_volumes" ]; then
                local volume_count=0
                while IFS= read -r volume_name; do
                    if [ -n "$volume_name" ]; then
                        if docker volume rm "$volume_name" >/dev/null 2>&1; then
                            log_info "    ✓ Removed volume: $volume_name"
                            volume_count=$((volume_count + 1))
                        else
                            log_info "    ! Failed to remove volume: $volume_name (may be in use)"
                        fi
                    fi
                done <<< "$sail_volumes"

                if [ $volume_count -gt 0 ]; then
                    log_info "    ✓ Removed $volume_count Sail volume(s)"
                fi
            else
                log_info "    No Sail volumes found"
            fi

            removed_count=$((removed_count + 1))
        fi
    done

    # If no projects to remove, we're done
    if [ ${#projects_to_remove[@]} -eq 0 ]; then
        return 0
    fi

    echo ""
    log_info "Cleaning up $removed_count stale project(s) from registry..."

    # Remove stale projects from REGISTRY_PROJECTS array
    local updated_projects=()
    for project in "${REGISTRY_PROJECTS[@]}"; do
        local should_keep=true
        for remove_project in "${projects_to_remove[@]}"; do
            if [ "$project" = "$remove_project" ]; then
                should_keep=false
                break
            fi
        done

        if [ "$should_keep" = true ]; then
            updated_projects+=("$project")
        fi
    done

    REGISTRY_PROJECTS=("${updated_projects[@]}")

    # Rebuild REGISTRY_ALL_PORTS array (exclude removed projects)
    REGISTRY_ALL_PORTS=()
    for project in "${REGISTRY_PROJECTS[@]}"; do
        local project_sanitized=$(sanitize_project_name "$project")
        local vars=$(compgen -v | grep "^registry_${project_sanitized}_" || true)
        for var in $vars; do
            local key="${var#registry_${project_sanitized}_}"
            local value="${!var}"

            # If this is a port value, add to all ports list
            if [[ "$key" =~ _PORT$ ]] && [[ "$value" =~ ^[0-9]+$ ]]; then
                REGISTRY_ALL_PORTS+=("$value")
            fi
        done
    done

    # Rewrite the registry file without stale projects
    local temp_file="$REGISTRY_FILE.tmp"

    {
        echo "# Shipyard Project Registry"
        echo "# This file tracks project configurations including ports, domains, and proxy services"
        echo "# Format: INI with [project-name] sections"
        echo ""

        # Write only existing projects
        for project in "${REGISTRY_PROJECTS[@]}"; do
            echo "[$project]"

            # Get all variables for this project (use sanitized name)
            local project_sanitized=$(sanitize_project_name "$project")
            local vars=$(compgen -v | grep "^registry_${project_sanitized}_" || true)
            for var in $vars; do
                local key="${var#registry_${project_sanitized}_}"
                local value="${!var}"
                echo "$key=$value"
            done

            echo ""
        done
    } > "$temp_file"

    # Atomic move
    if ! mv "$temp_file" "$REGISTRY_FILE"; then
        rm -f "$temp_file"
        log_error "Failed to update registry file during cleanup"
        return 1
    fi

    log_success "Cleaned up $removed_count stale project(s)"
    echo ""
}

run_cleanup_command() {
    # Dedicated cleanup command - cleans up stale projects from registry
    show_title
    echo ""

    echo ""
    validate_docker

    echo ""
    log_info "Starting Shipyard cleanup..."
    echo ""

    # Parse registry file first
    parse_ini_file

    # Clean up stale projects from registry
    if [ ${#REGISTRY_PROJECTS[@]} -eq 0 ]; then
        log_info "No registered projects found"
        echo ""
    else
        log_info "Found ${#REGISTRY_PROJECTS[@]} registered project(s)"
        echo ""
        cleanup_stale_projects
    fi

    log_success "Cleanup complete!"
    echo ""
}

run_list_command() {
    # List all registered projects from the config file
    show_title
    echo ""

    # Parse registry file first
    parse_ini_file

    if [ ${#REGISTRY_PROJECTS[@]} -eq 0 ]; then
        log_info "No registered projects found"
        echo ""
        echo "Run 'shipyard init' in a project directory to register a new project."
        echo ""
        return 0
    fi

    log_info "Registered Projects (${#REGISTRY_PROJECTS[@]})"
    echo ""

    # Display each project with its details
    for project in "${REGISTRY_PROJECTS[@]}"; do
        local project_sanitized=$(sanitize_project_name "$project")
        local path_var="registry_${project_sanitized}_path"
        local domain_var="registry_${project_sanitized}_domain"
        local proxy_var="registry_${project_sanitized}_proxy_service"

        echo -e "${BOLD}${project}${NC}"
        
        # Show path
        if [ -n "${!path_var:-}" ]; then
            echo "  Path:   ${!path_var}"
            # Check if path still exists
            if [ ! -d "${!path_var}" ]; then
                echo -e "  ${YELLOW}⚠ Path no longer exists${NC}"
            fi
        fi
        
        # Show domain if available
        if [ -n "${!domain_var:-}" ]; then
            local proxy_service="${!proxy_var:-unknown}"
            echo "  Domain: ${!domain_var} (${proxy_service})"
        fi
        
        # Show all port variables dynamically
        local ports=()
        while IFS= read -r varname; do
            if [[ "$varname" =~ ^registry_${project_sanitized}_(.+_PORT)$ ]]; then
                local port_name="${BASH_REMATCH[1]}"
                local port_value="${!varname}"
                if [ -n "$port_value" ]; then
                    ports+=("${port_name}:${port_value}")
                fi
            fi
        done < <(compgen -v "registry_${project_sanitized}_")
        
        if [ ${#ports[@]} -gt 0 ]; then
            echo "  Ports:"
            for port_info in "${ports[@]}"; do
                echo "    ${port_info}"
            done
        fi
        
        echo ""
    done

    log_info "Config file: $REGISTRY_FILE"
    echo ""
}

is_port_in_registry() {
    local port=$1

    for registered_port in "${REGISTRY_ALL_PORTS[@]}"; do
        if [ "$registered_port" = "$port" ]; then
            return 0  # Port is taken
        fi
    done

    return 1  # Port is available
}

is_project_registered() {
    local project_name=$1

    for registered_project in "${REGISTRY_PROJECTS[@]}"; do
        if [ "$registered_project" = "$project_name" ]; then
            return 0  # Project exists
        fi
    done

    return 1  # Project doesn't exist
}

save_registry() {
    local temp_file="$REGISTRY_FILE.tmp"

    {
        echo "# Shipyard Project Registry"
        echo "# This file tracks project configurations including ports, domains, and proxy services"
        echo "# Format: INI with [project-name] sections"
        echo ""

        # Write existing projects first
        for project in "${REGISTRY_PROJECTS[@]}"; do
            echo "[$project]"

            # Get all variables for this project (use sanitized name)
            local project_sanitized=$(sanitize_project_name "$project")
            local vars=$(compgen -v | grep "^registry_${project_sanitized}_" || true)
            for var in $vars; do
                local key="${var#registry_${project_sanitized}_}"
                local value="${!var}"
                echo "$key=$value"
            done

            echo ""
        done

        # Write new project
        echo "[$PROJECT_NAME]"
        echo "path=$(pwd)"

        # Write domain and proxy service if registered
        if [ "$DOMAIN_REGISTERED" = true ]; then
            echo "domain=${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
            echo "proxy_service=$SELECTED_DEV_TOOL"
        fi

        # Write port assignments in sorted order
        for var_name in $(echo "${!PORT_ASSIGNMENTS[@]}" | tr ' ' '\n' | sort); do
            echo "$var_name=${PORT_ASSIGNMENTS[$var_name]}"
        done

    } > "$temp_file"

    # Atomic move
    if ! mv "$temp_file" "$REGISTRY_FILE"; then
        rm -f "$temp_file"
        exit_with_error $EXIT_REGISTRY_WRITE_FAILED \
            "Failed to write registry file: $REGISTRY_FILE"
    fi
}

# ==============================================================================
# PORT ASSIGNMENT FUNCTIONS
# ==============================================================================

extract_port_vars() {
    # Extract all port-related environment variables with their defaults
    # Pattern: ${VAR_PORT:-default} or ${VAR_PORT:default}
    local port_vars=$(grep -oE '\$\{[A-Z_]*_PORT[^}]*\}' "$COMPOSE_FILE" | sort -u)

    if [ -z "$port_vars" ]; then
        exit_with_error $EXIT_SUCCESS "No port variables found in $COMPOSE_FILE"
    fi

    local -a results=()

    while IFS= read -r var; do
        # Extract variable name and default value
        # Pattern: ${VAR_NAME:-default} or ${VAR_NAME:default}
        local var_clean=$(echo "$var" | sed 's/\${//;s/}//')

        if [[ $var_clean =~ ^([A-Z_]+_PORT)(:-?)(.+)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local default_value="${BASH_REMATCH[3]}"
            results+=("$var_name:$default_value")
        fi
    done < <(echo "$port_vars")

    printf '%s\n' "${results[@]}"
}

is_port_available() {
    local port=$1

    # Check registry first
    if is_port_in_registry "$port"; then
        return 1  # Port taken in registry
    fi

    # Check system using /dev/tcp (bash built-in)
    if (echo >/dev/tcp/localhost/"$port") 2>/dev/null; then
        return 1  # Port is in use
    fi

    # Fallback to lsof if available (more reliable on macOS)
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            return 1  # Port is in use
        fi
    fi

    return 0  # Port is available
}

find_next_available_port() {
    local start_port=$1
    local var_name=$2
    local port=$start_port
    local max_attempts=10000
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if is_port_available "$port"; then
            echo "$port"
            return 0
        fi

        port=$((port + 1))
        attempt=$((attempt + 1))
    done

    # Exhausted all attempts
    exit_with_error $EXIT_NO_PORTS_AVAILABLE \
        "No available ports found for $var_name
Searched range: $start_port-$port ($max_attempts attempts)

This is extremely rare. Please check your system's port usage."
}

# ==============================================================================
# PROJECT FUNCTIONS
# ==============================================================================

get_project_name() {
    # Generate project name from full path
    # Always normalize to valid Docker Compose format (lowercase, alphanumeric + underscores)
    # Remove leading slash, then replace all non-alphanumeric chars with underscores, convert to lowercase
    echo "$PWD" | sed 's|^/||' | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]'
}

ensure_compose_project_name() {
    # Generate normalized project name
    local project_name=$(get_project_name)

    # Set global PROJECT_NAME variable
    PROJECT_NAME="$project_name"
}

# ==============================================================================
# .ENV FILE FUNCTIONS
# ==============================================================================

append_ports_to_env() {
    local temp_file="${ENV_FILE}.tmp"

    {
        # Add header comment at the top
        echo "# Auto-assigned Docker Ports (via shipyard.sh)"

        # Always add COMPOSE_PROJECT_NAME (normalized from path)
        echo "COMPOSE_PROJECT_NAME=$PROJECT_NAME"

        # Add APP_URL based on domain registration or APP_PORT
        if [ -n "${PORT_ASSIGNMENTS[APP_PORT]}" ]; then
            if [ "$DOMAIN_REGISTERED" = true ]; then
                # Use HTTPS domain if registered
                echo "APP_URL=https://${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
                echo "VITE_SERVER_HOST=${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
            else
                # Fall back to localhost
                echo "APP_URL=http://localhost:${PORT_ASSIGNMENTS[APP_PORT]}"
                echo "VITE_SERVER_HOST=localhost"
            fi
            echo "ASSET_URL=\"\${APP_URL}\""
        fi

        # Add port assignments in sorted order
        for var_name in $(echo "${!PORT_ASSIGNMENTS[@]}" | tr ' ' '\n' | sort); do
            echo "$var_name=${PORT_ASSIGNMENTS[$var_name]}"
        done

        # Add blank line separator
        echo ""

        # Copy existing .env content, but skip COMPOSE_PROJECT_NAME, APP_URL, ASSET_URL, and VITE_SERVER_HOST
        while IFS= read -r line; do
            # Skip lines we're managing at the top
            if [[ ! "$line" =~ ^COMPOSE_PROJECT_NAME= ]] && \
               [[ ! "$line" =~ ^APP_URL= ]] && \
               [[ ! "$line" =~ ^ASSET_URL= ]] && \
               [[ ! "$line" =~ ^VITE_SERVER_HOST= ]]; then
                echo "$line"
            fi
        done < "$ENV_FILE"

    } > "$temp_file"

    # Atomic move
    if ! mv "$temp_file" "$ENV_FILE"; then
        rm -f "$temp_file"
        exit_with_error $EXIT_ENV_WRITE_FAILED \
            "Failed to prepend ports to .env file"
    fi
}

# ==============================================================================
# DOMAIN REGISTRATION FUNCTIONS (VALET/HERD)
# ==============================================================================

detect_local_dev_tools() {
    # Check for valet
    if command -v valet >/dev/null 2>&1; then
        VALET_AVAILABLE=true
    fi

    # Check for herd
    if command -v herd >/dev/null 2>&1; then
        HERD_AVAILABLE=true
    fi

    # Return 0 if at least one tool is available
    if [ "$VALET_AVAILABLE" = true ] || [ "$HERD_AVAILABLE" = true ]; then
        return 0
    fi

    return 1
}

validate_domain_name() {
    local domain=$1

    # Check if empty
    if [ -z "$domain" ]; then
        return 1
    fi

    # Check if valid format: alphanumeric and hyphens only
    # Cannot start or end with hyphen
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ! "$domain" =~ ^[a-zA-Z0-9]$ ]]; then
        return 1
    fi

    return 0
}

check_existing_proxy() {
    local domain=$1
    local tool=$2

    # Get list of existing proxies
    local existing_proxies
    existing_proxies=$($tool proxies 2>/dev/null | tail -n +4 | awk '{print $1}' | grep -v '^+' | grep -v '^$' | grep -v '^|$')

    # Check if domain exists in list
    echo "$existing_proxies" | grep -q "^${domain}$"
    return $?
}

register_domain_with_tool() {
    local domain=$1
    local port="${PORT_ASSIGNMENTS[APP_PORT]}"

    if [ -z "$port" ]; then
        log_error "APP_PORT not assigned. Cannot register proxy."
        return 1
    fi

    local full_domain="${domain}.${DOMAIN_TLD}"
    local proxy_target="http://localhost:${port}"

    log_info "Registering proxy: $full_domain -> $proxy_target"

    # Run the proxy command with --secure flag
    if $SELECTED_DEV_TOOL proxy "$domain" "$proxy_target" --secure >/dev/null 2>&1; then
        log_success "Proxy created with SSL certificate"
        return 0
    else
        log_error "$SELECTED_DEV_TOOL proxy command failed"
        return 1
    fi
}

prompt_domain_registration() {
    # Check if user wants domain registration (already collected)
    if [ "$REGISTER_DOMAIN" = false ]; then
        return 0
    fi

    # Domain name and tool already validated during input collection
    local domain="$USER_DOMAIN_NAME"
    local port="${PORT_ASSIGNMENTS[APP_PORT]}"

    if [ -z "$port" ]; then
        log_error "APP_PORT not assigned. Cannot register proxy."
        return 1
    fi

    local full_domain="${domain}.${DOMAIN_TLD}"
    local proxy_target="http://localhost:${port}"

    log_info "Registering proxy: $full_domain -> $proxy_target"

    # Run the proxy command with --secure flag
    if $SELECTED_DEV_TOOL proxy "$domain" "$proxy_target" --secure >/dev/null 2>&1; then
        DOMAIN_REGISTERED=true
        REGISTERED_DOMAIN="$domain"
        log_success "Proxy created with SSL certificate"
        log_success "Domain registered: https://$domain.$DOMAIN_TLD"
        return 0
    else
        log_error "$SELECTED_DEV_TOOL proxy command failed"
        DOMAIN_REGISTERED=false
        return 1
    fi
}

find_ssl_certificates() {
    local domain=$1
    local tool=$2

    # Determine certificate directory based on tool
    local cert_dir
    if [ "$tool" = "valet" ]; then
        cert_dir="$VALET_CERT_DIR"
    else
        cert_dir="$HERD_CERT_DIR"
    fi

    # Build full domain name
    local full_domain="${domain}.${DOMAIN_TLD}"

    # Check if certificate files exist
    local cert_file="${cert_dir}/${full_domain}.crt"
    local key_file="${cert_dir}/${full_domain}.key"

    if [ ! -f "$cert_file" ]; then
        log_error "Certificate file not found: $cert_file"
        return 1
    fi

    if [ ! -f "$key_file" ]; then
        log_error "Key file not found: $key_file"
        return 1
    fi

    # Export paths for use by symlink function
    export FOUND_CERT_FILE="$cert_file"
    export FOUND_KEY_FILE="$key_file"

    return 0
}

symlink_certificates() {
    if [ "$DOMAIN_REGISTERED" = false ]; then
        return 0
    fi

    # Find certificates
    if ! find_ssl_certificates "$REGISTERED_DOMAIN" "$SELECTED_DEV_TOOL"; then
        log_error "Could not find SSL certificates. You may need to run:"
        echo "  $SELECTED_DEV_TOOL secure $REGISTERED_DOMAIN"
        return 1
    fi

    # Create certificates directory
    if [ ! -d "$PROJECT_CERT_DIR" ]; then
        mkdir -p "$PROJECT_CERT_DIR"
        log_success "Created certificates/ directory"
    fi

    # Create symlinks with generic names
    local target_cert="${PROJECT_CERT_DIR}/cert.crt"
    local target_key="${PROJECT_CERT_DIR}/cert.key"

    # Remove existing symlinks if they exist
    [ -L "$target_cert" ] && rm "$target_cert"
    [ -L "$target_key" ] && rm "$target_key"

    # Create new symlinks
    ln -s "$FOUND_CERT_FILE" "$target_cert"
    ln -s "$FOUND_KEY_FILE" "$target_key"

    log_success "Symlinked SSL certificates:"
    log_info "  cert.crt -> $FOUND_CERT_FILE"
    log_info "  cert.key -> $FOUND_KEY_FILE"

    return 0
}

update_gitignore_for_certs() {
    if [ "$DOMAIN_REGISTERED" = false ]; then
        return 0
    fi

    local gitignore_file=".gitignore"

    # Check if /certificates is already in .gitignore
    if grep -q "^/certificates" "$gitignore_file" 2>/dev/null; then
        return 0
    fi

    # Append to .gitignore
    echo "/certificates" >> "$gitignore_file"
    log_success "Added /certificates to .gitignore"

    return 0
}

# ==============================================================================
# USER INPUT COLLECTION
# ==============================================================================

collect_user_input() {
    echo ""
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║  📝  INTERACTIVE SETUP                                           ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${DIM}Please answer a few questions to configure your project.${NC}"
    echo -e "${DIM}After this, everything will run automatically.${NC}"
    echo ""

    # 1. Collect Composer credentials for private repositories
    if [ ! -f "composer.json" ]; then
        log_error "composer.json not found in current directory"
        exit 1
    fi

    local repositories=($(extract_composer_repositories))

    if [ ${#repositories[@]} -gt 0 ]; then
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}🔐 Private Repository Authentication${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "Found ${BOLD}${#repositories[@]}${NC} private repository/repositories in composer.json:"
        for repo in "${repositories[@]}"; do
            echo -e "  ${DIM}•${NC} $repo"
        done
        echo ""

        local repo_index=1
        for repo in "${repositories[@]}"; do
            echo -e "${BOLD}Repository $repo_index/${#repositories[@]}:${NC} ${CYAN}$repo${NC}"
            echo -n "  Username (or press Enter to use 'token'): "
            read -r username
            username=${username:-token}

            echo -n "  Password/token (input hidden): "
            read -s -r password
            echo ""

            if [ -z "$password" ]; then
                echo ""
                log_error "No password/token provided for $repo. Cannot proceed."
                echo ""
                echo "Please run this script again with valid credentials."
                exit 1
            fi

            COMPOSER_REPO_USERNAMES+=("$username")
            COMPOSER_REPO_PASSWORDS+=("$password")

            log_success "Credentials stored for $repo"
            echo ""

            repo_index=$((repo_index + 1))
        done
    fi

    # 2. Detect available local dev tools (Valet/Herd)
    detect_local_dev_tools

    # 3. Ask about domain registration
    if [ "$VALET_AVAILABLE" = true ] || [ "$HERD_AVAILABLE" = true ]; then
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}🌐 Local Domain Registration${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${DIM}Would you like to register a local domain for this project?${NC}"
        echo -n "Register domain? [Y/n]: "
        read -r response
        response=${response:-Y}

        if [[ "$response" =~ ^[Yy]$ ]]; then
            REGISTER_DOMAIN=true

            # Select dev tool
            if [ "$VALET_AVAILABLE" = true ] && [ "$HERD_AVAILABLE" = false ]; then
                SELECTED_DEV_TOOL="valet"
                echo -e "${DIM}→ Using Valet for domain management${NC}"
            elif [ "$HERD_AVAILABLE" = true ] && [ "$VALET_AVAILABLE" = false ]; then
                SELECTED_DEV_TOOL="herd"
                echo -e "${DIM}→ Using Herd for domain management${NC}"
            else
                # Both are available, ask user
                echo ""
                echo -e "${BOLD}Both Valet and Herd are installed. Which should be used?${NC}"
                echo -e "  ${CYAN}[1]${NC} Valet"
                echo -e "  ${CYAN}[2]${NC} Herd"
                echo -n "Select tool [1]: "
                read -r selection
                selection=${selection:-1}

                case $selection in
                    1)
                        SELECTED_DEV_TOOL="valet"
                        log_success "Selected: Valet"
                        ;;
                    2)
                        SELECTED_DEV_TOOL="herd"
                        log_success "Selected: Herd"
                        ;;
                    *)
                        echo -e "${YELLOW}Invalid selection. Defaulting to Valet.${NC}"
                        SELECTED_DEV_TOOL="valet"
                        ;;
                esac
            fi

            # Get project name to suggest as domain
            ensure_compose_project_name
            local suggested_domain="$PROJECT_NAME"

            # Loop until valid domain name is provided
            while true; do
                echo ""
                echo -e "${BOLD}Domain Configuration${NC}"
                echo -e "${DIM}Enter domain name (without .${DOMAIN_TLD})${NC}"
                echo -n "Domain name [$suggested_domain]: "
                read -r domain
                domain=${domain:-$suggested_domain}

                # Validate domain name format
                if ! validate_domain_name "$domain"; then
                    echo ""
                    log_error "Invalid domain name. Use only alphanumeric characters and hyphens."
                    echo -e "${DIM}Domain cannot start or end with a hyphen.${NC}"
                    echo ""
                    echo -n "Try again? [Y/n]: "
                    read -r retry
                    retry=${retry:-Y}
                    if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                        echo -e "${DIM}→ Cancelled domain registration${NC}"
                        REGISTER_DOMAIN=false
                        break
                    fi
                    continue
                fi

                # Check if proxy already exists
                if check_existing_proxy "$domain" "$SELECTED_DEV_TOOL"; then
                    echo ""
                    log_error "Domain '$domain.$DOMAIN_TLD' is already registered as a proxy."
                    echo ""
                    echo -e "${DIM}Existing proxies:${NC}"
                    $SELECTED_DEV_TOOL proxies 2>/dev/null | grep "| $domain " || true
                    echo ""
                    echo -n "Try a different domain name? [Y/n]: "
                    read -r retry
                    retry=${retry:-Y}
                    if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                        echo -e "${DIM}→ Cancelled domain registration${NC}"
                        REGISTER_DOMAIN=false
                        break
                    fi
                    continue
                fi

                # Domain is valid and available
                USER_DOMAIN_NAME="$domain"
                log_success "Domain name validated: ${CYAN}$domain.$DOMAIN_TLD${NC}"
                break
            done
        else
            echo -e "${DIM}→ Skipping domain registration${NC}"
        fi
    fi

    # 4. Ask about post-setup commands
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}⚡ Post-Setup Automation${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${DIM}After port assignment, these commands can be run:${NC}"
    echo -e "  ${DIM}1.${NC} Start Docker containers ${DIM}(vendor/bin/sail up -d)${NC}"
    echo -e "  ${DIM}2.${NC} Run Laravel setup ${DIM}(vendor/bin/sail composer setup)${NC}"
    echo ""
    echo -n "Run these commands automatically? [Y/n]: "
    read -r RUN_POST_SETUP
    RUN_POST_SETUP=${RUN_POST_SETUP:-Y}

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}✓ All user input collected!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Configuration Summary:${NC}"
    if [ ${#COMPOSER_REPO_USERNAMES[@]} -gt 0 ]; then
        echo -e "  ${DIM}•${NC} Private repositories: ${BOLD}${#COMPOSER_REPO_USERNAMES[@]}${NC} configured"
    fi
    if [ "$REGISTER_DOMAIN" = true ]; then
        echo -e "  ${DIM}•${NC} Domain: ${CYAN}$USER_DOMAIN_NAME.$DOMAIN_TLD${NC} (via $SELECTED_DEV_TOOL)"
    else
        echo -e "  ${DIM}•${NC} Domain: ${DIM}Not configured${NC}"
    fi
    if [[ "$RUN_POST_SETUP" =~ ^[Yy]$ ]]; then
        echo -e "  ${DIM}•${NC} Post-setup: ${GREEN}Auto-run enabled${NC}"
    else
        echo -e "  ${DIM}•${NC} Post-setup: ${DIM}Manual${NC}"
    fi
    echo ""
    echo -e "${DIM}The following steps will be performed:${NC}"
    echo -e "  ${DIM}1.${NC} Assign available ports for the project"
    echo -e "  ${DIM}2.${NC} Update .env file with port assignments"
    echo -e "  ${DIM}3.${NC} Register project in Shipyard registry"
    if [ "$REGISTER_DOMAIN" = true ]; then
        echo -e "  ${DIM}4.${NC} Configure local domain and SSL certificates"
    fi
    if [[ "$RUN_POST_SETUP" =~ ^[Yy]$ ]]; then
        echo -e "  ${DIM}5.${NC} Start Docker containers and run Laravel setup"
    fi
    echo ""
    read -r -p "Continue with setup? [Y/n] " confirm
    confirm=${confirm:-Y}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${YELLOW}Setup cancelled by user.${NC}"
        echo ""
        echo -e "${DIM}You can run 'shipyard init' again when ready.${NC}"
        exit $EXIT_USER_CANCELLED
    fi

    echo ""
    echo -e "${DIM}Starting setup...${NC}"
    echo ""
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    # Setup cleanup and interrupt handlers
    trap cleanup_on_exit EXIT
    trap handle_interrupt INT TERM

    # Check for updates before starting
    check_for_updates

    # Show title banner
    show_title
    log_info "(Press Ctrl+C at any time to cancel)"
    echo ""

    # Step 1: Validate Docker is installed and running
    validate_docker

    # Step 2: Check for Docker network issues
    check_docker_networks

    # Step 3: Validate docker-compose.yml exists
    validate_docker_compose

    # Step 4: Collect all user input upfront
    collect_user_input

    # Step 5: Run composer install (non-interactive)
    run_composer_install

    # Step 6: Validate/create .env file
    validate_env_file

    # Step 7: Check .env for existing port definitions
    check_env_for_ports

    # Step 8: Acquire lock on registry
    acquire_lock
    log_success "Acquired registry lock"

    # Step 9: Get or generate project name (if not already set during input collection)
    if [ -z "$PROJECT_NAME" ]; then
        ensure_compose_project_name
    fi
    log_info "Project identifier: $PROJECT_NAME"

    # Step 10: Load existing registry
    parse_ini_file

    # Step 10: Clean up stale projects (paths that no longer exist)
    cleanup_stale_projects

    # Step 11: Check if project already registered
    if is_project_registered "$PROJECT_NAME"; then
        exit_with_error $EXIT_ALREADY_REGISTERED \
            "Project '$PROJECT_NAME' is already registered in the port registry.

Registry file: $REGISTRY_FILE

To re-assign ports, manually remove the [$PROJECT_NAME] section from the registry."
    fi
    log_success "Project not yet registered"

    local num_other_projects=${#REGISTRY_PROJECTS[@]}
    if [ $num_other_projects -gt 0 ]; then
        log_success "Loaded existing registry ($num_other_projects other project(s))"
    else
        log_success "Registry is empty (first project)"
    fi

    # Step 12: Extract port variables from docker-compose.yml
    local port_vars_output=$(extract_port_vars)
    readarray -t port_vars_array <<< "$port_vars_output"
    local num_port_vars=${#port_vars_array[@]}
    log_success "Extracted $num_port_vars port variable(s) from docker-compose.yml"

    echo ""
    log_info "Assigning ports:"

    # Step 13: Assign ports
    for port_var in "${port_vars_array[@]}"; do
        local var_name="${port_var%:*}"
        local default_port="${port_var#*:}"

        # Convert default port to starting point
        local start_port=$(convert_port "$default_port")

        # Find next available port
        local assigned_port=$(find_next_available_port "$start_port" "$var_name")

        # Store assignment
        PORT_ASSIGNMENTS["$var_name"]="$assigned_port"

        # Log assignment
        if [ "$assigned_port" = "$start_port" ]; then
            log_info "  $var_name: $start_port → $assigned_port ✓ available"
        else
            log_info "  $var_name: $start_port → $assigned_port ($start_port taken) ✓ available"
        fi
    done

    echo ""

    # Step 14: Domain registration (non-interactive)
    if [ "$REGISTER_DOMAIN" = true ]; then
        prompt_domain_registration

        if [ "$DOMAIN_REGISTERED" = true ]; then
            echo ""
            log_info "Setting up SSL certificates..."
            symlink_certificates
            update_gitignore_for_certs
            echo ""
        fi
    else
        log_info "Domain registration skipped (as per user preference)"
        echo ""
    fi

    # Step 15: Save registry
    save_registry
    log_success "Updated registry: $REGISTRY_FILE"

    # Step 16: Append to .env
    append_ports_to_env

    # Build success message with APP_URL info
    local success_msg="Added $num_port_vars port assignment(s) to top of .env file"
    if [ "$DOMAIN_REGISTERED" = true ]; then
        success_msg="$success_msg (APP_URL=https://${REGISTERED_DOMAIN}.${DOMAIN_TLD})"
    elif [ -n "${PORT_ASSIGNMENTS[APP_PORT]}" ]; then
        success_msg="$success_msg (APP_URL=http://localhost:${PORT_ASSIGNMENTS[APP_PORT]})"
    fi
    log_success "$success_msg"

    # Step 17: Release lock
    release_lock

    # Success message
    echo ""
    log_success "Project setup complete! Assigned $num_port_vars ports to '$PROJECT_NAME'."

    # Step 18: Run post-setup commands (non-interactive)
    if [[ "$RUN_POST_SETUP" =~ ^[Yy]$ ]]; then
        echo ""
        echo "=========================================="
        echo "Running post-setup commands..."
        echo "=========================================="
        echo ""

        log_info "Step 1/2: Starting Docker containers (vendor/bin/sail up -d)..."
        ./vendor/bin/sail up -d

        if [ $? -ne 0 ]; then
            echo ""
            log_error "Failed to start Docker containers."
            echo "You may need to run this manually:"
            echo "  ./vendor/bin/sail up -d"
            exit 9
        fi
        log_success "Docker containers started"

        echo ""
        log_info "Step 2/2: Running Laravel setup (vendor/bin/sail composer setup)..."
        ./vendor/bin/sail composer setup

        if [ $? -ne 0 ]; then
            echo ""
            log_error "Laravel setup failed. You may need to run this manually:"
            echo "  ./vendor/bin/sail composer setup"
            exit 9
        fi
        log_success "Laravel setup completed"

        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}${BOLD}✓ All setup complete! 🎉${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if [ "$DOMAIN_REGISTERED" = true ]; then
            echo ""
            echo -e "${BOLD}Your application is accessible at:${NC}"
            echo -e "  ${CYAN}https://${REGISTERED_DOMAIN}.${DOMAIN_TLD}${NC}"
            echo ""
            echo -e "${DIM}SSL certificates are symlinked in ./${PROJECT_CERT_DIR}/${NC}"
            echo -e "${DIM}  • cert.crt${NC}"
            echo -e "${DIM}  • cert.key${NC}"
            echo ""
            echo -e "${DIM}Docker is listening on localhost:${PORT_ASSIGNMENTS[APP_PORT]}${NC}"
            echo -e "${DIM}Valet/Herd proxy: ${REGISTERED_DOMAIN}.${DOMAIN_TLD} → localhost:${PORT_ASSIGNMENTS[APP_PORT]}${NC}"
        elif [ -n "${PORT_ASSIGNMENTS[APP_PORT]}" ]; then
            echo ""
            echo -e "${BOLD}Your application should be accessible at:${NC}"
            echo -e "  ${CYAN}http://localhost:${PORT_ASSIGNMENTS[APP_PORT]}${NC}"
        fi
    else
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}Next steps: Start containers and run setup${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "To complete setup manually, run:"
        echo -e "  ${DIM}1.${NC} ./vendor/bin/sail up -d"
        echo -e "  ${DIM}2.${NC} ./vendor/bin/sail composer setup"
    fi
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

# Parse arguments before running main
parse_arguments "$@"

# Run main function
main
