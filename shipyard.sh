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

# Require Bash 3.2+
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    echo "Error: Shipyard requires Bash 3.2 or newer. Detected: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# ==============================================================================
# VERSION
# ==============================================================================

readonly VERSION="0.4.0"

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
readonly EXIT_ENV_ALREADY_CONFIGURED=12
readonly EXIT_TEMPLATE_FETCH_FAILED=13
readonly EXIT_CAKE_LAYOUT_NOT_FOUND=14
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

# Port assignments for current project (Bash 3.2 compatible key/value storage)
declare -a PORT_ASSIGNMENT_KEYS=()
declare -a PORT_ASSIGNMENT_VALUES=()

# Project state
PROJECT_NAME=""

# Preset state (drives compose scaffolding for legacy presets)
PRESET=""
SELECTED_PHP_VERSION=""
SELECTED_MYSQL_VERSION=""
OPTIONAL_SERVICES=""
MEILISEARCH_VERSION=""
ELASTICSEARCH_VERSION=""

# CakePHP 2 state (resolved during cakephp-2 scaffolding)
CAKE_CONFIG_DIR=""        # "app/Config" or "Config"
NGINX_DOCROOT=""          # e.g. "public_html", "app/webroot", "webroot"
CAKE_SOURCE_ENV_FOLDER="" # absolute or relative path to the env folder being cloned

# Files that were created or patched during init — printed at end as a review checklist
declare -a REVIEW_FILES=()

# Domain registration state
DOMAIN_REGISTERED=false
REGISTERED_DOMAIN=""
SELECTED_DEV_TOOL=""  # "valet" or "herd"
VALET_AVAILABLE=false
HERD_AVAILABLE=false
USE_SECURE_PROXY=true  # Whether to use --secure flag for HTTPS

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

log_warning() {
    echo -e "${YELLOW}Warning:${NC} $1" >&2
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
        "Failed to acquire lock after ${LOCK_TIMEOUT}s. Another process may be using the project registry."
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
        elif [ "$PRESET" = "laravel-legacy" ] || [ "$PRESET" = "cakephp-2" ]; then
            # Pre-Sail Laravel projects often have no .env.example, and Cake 2
            # predates .env entirely. Either way, start fresh so COMPOSE_PROJECT_NAME
            # and the assigned port vars have somewhere to land.
            log_info "No .env or .env.example — creating empty .env"
            : > "$ENV_FILE"
            log_success "Empty .env file created"
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

detect_php_version() {
    # Detect PHP version from docker-compose.yml
    # Looks for patterns like: ./vendor/laravel/sail/runtimes/8.4 or sail-8.4/app
    local php_version=""

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_warning "docker-compose.yml not found, defaulting to PHP 8.4"
        echo "84"
        return
    fi

    # Try to extract version from context path (e.g., ./vendor/laravel/sail/runtimes/8.4)
    php_version=$(grep -E 'context:.*runtimes/[0-9]+\.[0-9]+' "$COMPOSE_FILE" | sed -E 's/.*runtimes\/([0-9]+)\.([0-9]+).*/\1\2/' | head -n 1)

    # If not found, try to extract from image name (e.g., sail-8.4/app)
    if [ -z "$php_version" ]; then
        php_version=$(grep -E 'image:.*sail-[0-9]+\.[0-9]+' "$COMPOSE_FILE" | sed -E 's/.*sail-([0-9]+)\.([0-9]+).*/\1\2/' | head -n 1)
    fi

    # Default to 8.4 if not found
    if [ -z "$php_version" ]; then
        log_warning "Could not detect PHP version from docker-compose.yml, defaulting to PHP 8.4"
        echo "84"
    else
        echo "$php_version"
    fi
}

is_vite_installed() {
    [ -f "package.json" ] && grep -q '"vite"' package.json
}

is_laravel_mix_installed() {
    [ -f "package.json" ] && grep -q '"laravel-mix"' package.json
}

write_composer_auth_json() {
    local repositories=($(extract_composer_repositories))

    if [ ${#repositories[@]} -eq 0 ]; then
        return 0
    fi

    log_info "Writing auth.json with private repository credentials..."

    # Build the http-basic JSON block
    local http_basic_entries=""
    local repo_index=0

    for repo in "${repositories[@]}"; do
        local username="${COMPOSER_REPO_USERNAMES[$repo_index]}"
        local password="${COMPOSER_REPO_PASSWORDS[$repo_index]}"

        if [ -n "$http_basic_entries" ]; then
            http_basic_entries="$http_basic_entries,"$'\n'
        fi
        http_basic_entries="${http_basic_entries}        \"$repo\": {\"username\": \"$username\", \"password\": \"$password\"}"

        repo_index=$((repo_index + 1))
    done

    cat > auth.json <<EOF
{
    "http-basic": {
$http_basic_entries
    }
}
EOF

    log_success "auth.json written"

    # Ensure auth.json is in .gitignore
    if [ -f ".gitignore" ]; then
        if ! grep -qxF "auth.json" .gitignore; then
            echo "auth.json" >> .gitignore
            log_success "auth.json added to .gitignore"
        fi
    else
        echo "auth.json" > .gitignore
        log_success ".gitignore created with auth.json"
    fi

    echo ""
}

run_composer_install() {
    echo ""
    log_info "=========================================="
    log_info "Installing Composer dependencies..."
    log_info "=========================================="
    echo ""

    # Detect PHP version from docker-compose.yml
    local php_version=$(detect_php_version)
    local composer_php_version="$php_version"

    # Use PHP 8.4 composer image when project runtime is 8.5 (see https://github.com/laravel/sail-server/pull/35)
    if [ "$php_version" = "85" ]; then
        composer_php_version="84"
    fi

    local composer_image="laravelsail/php${composer_php_version}-composer:latest"

    if [ "$php_version" = "$composer_php_version" ]; then
        log_info "Using PHP ${php_version:0:1}.${php_version:1} composer image: $composer_image"
    else
        log_info "Detected PHP ${php_version:0:1}.${php_version:1}; using PHP ${composer_php_version:0:1}.${composer_php_version:1} composer image: $composer_image"
    fi
    echo ""

    log_info "Running composer install via Docker..."
    echo ""

    docker run --rm -u "$(id -u):$(id -g)" -v "$(pwd):/var/www/html" -w /var/www/html "$composer_image" composer install --ignore-platform-reqs

    if [ $? -ne 0 ]; then
        echo ""
        log_error "Composer install failed. Please check your credentials and try again."
        exit 9
    fi

    log_success "Composer dependencies installed"
    echo ""
}

check_env_already_initialized() {
    # Check if .env file exists
    if [ -f "$ENV_FILE" ]; then
        exit_with_error $EXIT_ENV_ALREADY_CONFIGURED \
            ".env file already exists in this project.

File: $ENV_FILE

To run 'shipyard init', please remove or rename the .env file first."
    fi
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

add_registry_key() {
    local project_sanitized=$1
    local key=$2
    local keys_var="registry_${project_sanitized}__keys"
    local existing_keys

    eval "existing_keys=\"\${$keys_var:-}\""

    case " $existing_keys " in
        *" $key "*) ;;
        *)
            if [ -n "$existing_keys" ]; then
                existing_keys="$existing_keys $key"
            else
                existing_keys="$key"
            fi
            eval "$keys_var=\"\$existing_keys\""
            ;;
    esac
}

get_registry_keys() {
    local project_sanitized=$1
    local keys_var="registry_${project_sanitized}__keys"
    local existing_keys

    eval "existing_keys=\"\${$keys_var:-}\""

    if [ -z "$existing_keys" ]; then
        return 0
    fi

    printf '%s\n' $existing_keys
}

parse_ini_file() {
    # Reset global arrays so repeated calls don't accumulate duplicates
    REGISTRY_PROJECTS=()
    REGISTRY_ALL_PORTS=()

    # Reset parsed registry variables from previous parse runs
    local parsed_var
    while IFS= read -r parsed_var; do
        unset "$parsed_var"
    done < <(compgen -v | grep '^registry_' || true)

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
            eval "registry_${current_section_sanitized}__keys=''"

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
            add_registry_key "$current_section_sanitized" "$key"

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
            local project_domain="${!domain_var:-}"
            local project_proxy="${!proxy_var:-}"

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
        for key in $(get_registry_keys "$project_sanitized"); do
            local var="registry_${project_sanitized}_${key}"
            local value="${!var:-}"

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
            for key in $(get_registry_keys "$project_sanitized"); do
                local var="registry_${project_sanitized}_${key}"
                local value="${!var:-}"
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
        local proxy_secure_var="registry_${project_sanitized}_proxy_secure"

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
            local proxy_secure="${!proxy_secure_var:-}"

            if [ -n "$proxy_secure" ]; then
                local protocol="https"
                if [ "$proxy_secure" = "false" ]; then
                    protocol="http"
                fi
                echo "  Domain: ${protocol}://${!domain_var} (${proxy_service})"
            else
                # No proxy_secure field, just show domain without protocol
                echo "  Domain: ${!domain_var} (${proxy_service})"
            fi
        fi

        # Show all port variables dynamically
        local ports=()
        for key in $(get_registry_keys "$project_sanitized"); do
            if [[ "$key" =~ _PORT$ ]]; then
                local port_name="$key"
                local varname="registry_${project_sanitized}_${key}"
                local port_value="${!varname:-}"
                if [ -n "$port_value" ]; then
                    ports+=("${port_name}:${port_value}")
                fi
            fi
        done

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

set_port_assignment() {
    local key=$1
    local value=$2
    local i=0

    while [ $i -lt ${#PORT_ASSIGNMENT_KEYS[@]} ]; do
        if [ "${PORT_ASSIGNMENT_KEYS[$i]}" = "$key" ]; then
            PORT_ASSIGNMENT_VALUES[$i]="$value"
            return 0
        fi
        i=$((i + 1))
    done

    PORT_ASSIGNMENT_KEYS+=("$key")
    PORT_ASSIGNMENT_VALUES+=("$value")
}

get_port_assignment() {
    local key=$1
    local i=0

    while [ $i -lt ${#PORT_ASSIGNMENT_KEYS[@]} ]; do
        if [ "${PORT_ASSIGNMENT_KEYS[$i]}" = "$key" ]; then
            echo "${PORT_ASSIGNMENT_VALUES[$i]}"
            return 0
        fi
        i=$((i + 1))
    done

    echo ""
    return 1
}

get_port_assignment_keys_sorted() {
    if [ ${#PORT_ASSIGNMENT_KEYS[@]} -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${PORT_ASSIGNMENT_KEYS[@]}" | sort
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
            for key in $(get_registry_keys "$project_sanitized"); do
                local var="registry_${project_sanitized}_${key}"
                local value="${!var:-}"
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
            echo "proxy_secure=$USE_SECURE_PROXY"
        fi

        # Write port assignments in sorted order
        for var_name in $(get_port_assignment_keys_sorted); do
            echo "$var_name=$(get_port_assignment "$var_name")"
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

    # Check ports already assigned in this run
    for assigned_port in "${PORT_ASSIGNMENT_VALUES[@]}"; do
        if [ "$assigned_port" = "$port" ]; then
            return 1  # Already assigned to another variable this run
        fi
    done

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
    local app_port
    app_port=$(get_port_assignment "APP_PORT")

    {
        # Add header comment at the top
        echo "# Auto-assigned Docker Ports (via shipyard.sh)"

        # Always add COMPOSE_PROJECT_NAME (normalized from path)
        echo "COMPOSE_PROJECT_NAME=$PROJECT_NAME"

        # Add APP_URL and ASSET_URL only for Laravel projects
        if [ -n "$app_port" ]; then
            if [ "$DOMAIN_REGISTERED" = true ]; then
                # Use domain with protocol based on secure setting
                if [ "$USE_SECURE_PROXY" = true ]; then
                    echo "APP_URL=https://${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
                else
                    echo "APP_URL=http://${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
                fi
            else
                # Fall back to localhost
                echo "APP_URL=http://localhost:${app_port}"
            fi
            echo "ASSET_URL=\"\${APP_URL}\""
        fi

        # Add VITE_SERVER_HOST only when Vite is installed
        if [ -n "$app_port" ] && is_vite_installed; then
            if [ "$DOMAIN_REGISTERED" = true ]; then
                echo "VITE_SERVER_HOST=${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
            else
                echo "VITE_SERVER_HOST=localhost"
            fi
        fi

        # Add MIX_SERVER_HOST only when Laravel Mix is installed
        if [ -n "$app_port" ] && is_laravel_mix_installed; then
            if [ "$DOMAIN_REGISTERED" = true ]; then
                echo "MIX_SERVER_HOST=${REGISTERED_DOMAIN}.${DOMAIN_TLD}"
            else
                echo "MIX_SERVER_HOST=localhost"
            fi
        fi

        # Add port assignments in sorted order
        for var_name in $(get_port_assignment_keys_sorted); do
            echo "$var_name=$(get_port_assignment "$var_name")"
        done

        # Add blank line separator
        echo ""

        # Copy existing .env content, but skip COMPOSE_PROJECT_NAME, APP_URL, ASSET_URL, VITE_SERVER_HOST, and MIX_SERVER_HOST
        while IFS= read -r line; do
            # Skip lines we're managing at the top
            if [[ ! "$line" =~ ^COMPOSE_PROJECT_NAME= ]] && \
               [[ ! "$line" =~ ^APP_URL= ]] && \
               [[ ! "$line" =~ ^ASSET_URL= ]] && \
               [[ ! "$line" =~ ^VITE_SERVER_HOST= ]] && \
               [[ ! "$line" =~ ^MIX_SERVER_HOST= ]]; then
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

prompt_domain_registration() {
    # Check if user wants domain registration (already collected)
    if [ "$REGISTER_DOMAIN" = false ]; then
        return 0
    fi

    # Domain name and tool already validated during input collection
    local domain="$USER_DOMAIN_NAME"
    local port
    port=$(get_port_assignment "APP_PORT")

    if [ -z "$port" ]; then
        log_error "APP_PORT not assigned. Cannot register proxy."
        return 1
    fi

    local full_domain="${domain}.${DOMAIN_TLD}"
    local proxy_target="http://localhost:${port}"

    log_info "Registering proxy: $full_domain -> $proxy_target"

    # Build proxy command with optional --secure flag
    local proxy_cmd="$SELECTED_DEV_TOOL proxy \"$domain\" \"$proxy_target\""
    if [ "$USE_SECURE_PROXY" = true ]; then
        proxy_cmd="$proxy_cmd --secure"
    fi

    # Run the proxy command
    if eval "$proxy_cmd" >/dev/null 2>&1; then
        DOMAIN_REGISTERED=true
        REGISTERED_DOMAIN="$domain"

        if [ "$USE_SECURE_PROXY" = true ]; then
            log_success "Proxy created with SSL certificate"
            log_success "Domain registered: https://$domain.$DOMAIN_TLD"
        else
            log_success "Proxy created (HTTP)"
            log_success "Domain registered: http://$domain.$DOMAIN_TLD"
        fi
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
    # Always create certificates directory
    if [ ! -d "$PROJECT_CERT_DIR" ]; then
        mkdir -p "$PROJECT_CERT_DIR"
        log_success "Created certificates/ directory"
    fi

    if [ "$DOMAIN_REGISTERED" = false ]; then
        # Create empty certificate files when no domain is registered
        local target_cert="${PROJECT_CERT_DIR}/cert.crt"
        local target_key="${PROJECT_CERT_DIR}/cert.key"

        touch "$target_cert"
        touch "$target_key"

        log_success "Created empty certificate files (no domain registered)"
        return 0
    fi

    # Skip SSL certificate setup if using HTTP mode
    if [ "$USE_SECURE_PROXY" = false ]; then
        log_info "Skipping SSL certificate setup (HTTP mode)"

        # Create empty certificate files for HTTP mode
        local target_cert="${PROJECT_CERT_DIR}/cert.crt"
        local target_key="${PROJECT_CERT_DIR}/cert.key"

        touch "$target_cert"
        touch "$target_key"

        log_success "Created empty certificate files for HTTP mode"
        return 0
    fi

    # Find certificates
    if ! find_ssl_certificates "$REGISTERED_DOMAIN" "$SELECTED_DEV_TOOL"; then
        log_error "Could not find SSL certificates. You may need to run:"
        echo "  $SELECTED_DEV_TOOL secure $REGISTERED_DOMAIN"
        return 1
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
    local gitignore_file=".gitignore"

    # Check if /certificates is already in .gitignore
    if grep -q "^/certificates" "$gitignore_file" 2>/dev/null; then
        return 0
    fi

    # Append to .gitignore (always add it since we always create the folder)
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

                # Ask about HTTPS/HTTP preference
                echo ""
                echo -e "${BOLD}SSL/HTTPS Configuration${NC}"
                echo -e "${DIM}Do you want to use HTTPS (secure) or HTTP (non-secure)?${NC}"
                echo -e "  ${CYAN}[1]${NC} HTTPS (Recommended) - Uses SSL certificates"
                echo -e "  ${CYAN}[2]${NC} HTTP - No SSL certificates"
                echo -n "Select option [1]: "
                read -r ssl_choice
                ssl_choice=${ssl_choice:-1}

                case $ssl_choice in
                    1)
                        USE_SECURE_PROXY=true
                        log_success "Selected: HTTPS (secure)"
                        ;;
                    2)
                        USE_SECURE_PROXY=false
                        log_success "Selected: HTTP (non-secure)"
                        ;;
                    *)
                        echo -e "${YELLOW}Invalid selection. Defaulting to HTTPS.${NC}"
                        USE_SECURE_PROXY=true
                        ;;
                esac

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
    echo -e "  ${DIM}2.${NC} Run Composer setup ${DIM}(vendor/bin/sail composer setup)${NC}"
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
        if [ "$USE_SECURE_PROXY" = true ]; then
            echo -e "  ${DIM}•${NC} Domain: ${CYAN}https://$USER_DOMAIN_NAME.$DOMAIN_TLD${NC} (via $SELECTED_DEV_TOOL)"
        else
            echo -e "  ${DIM}•${NC} Domain: ${CYAN}http://$USER_DOMAIN_NAME.$DOMAIN_TLD${NC} (via $SELECTED_DEV_TOOL)"
        fi
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
        if [ "$USE_SECURE_PROXY" = true ]; then
            echo -e "  ${DIM}4.${NC} Configure local domain and SSL certificates"
        else
            echo -e "  ${DIM}4.${NC} Configure local domain (HTTP)"
        fi
    fi
    if [[ "$RUN_POST_SETUP" =~ ^[Yy]$ ]]; then
        echo -e "  ${DIM}5.${NC} Start Docker containers and run Composer setup"
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
# PRESET SCAFFOLDING FUNCTIONS
# ==============================================================================

# Internal: fetch a template file from GitHub and return its raw content on stdout.
# Hard-fails the script if the fetch errors out (no offline fallback).
_fetch_raw_template() {
    local rel="$1"
    local ref="${SHIPYARD_TEMPLATE_REF:-v$VERSION}"
    local url="https://raw.githubusercontent.com/wotzebra/shipyard/${ref}/templates/${rel}"
    local content
    if ! content=$(curl -fsSL "$url" 2>/dev/null); then
        exit_with_error $EXIT_TEMPLATE_FETCH_FAILED \
            "Failed to fetch template: $url
Set SHIPYARD_TEMPLATE_REF to a branch/tag where the file exists, or check your network."
    fi
    printf '%s' "$content"
}

# Internal: substitute the global {{VAR}} placeholders in a template body.
# Port placeholders are resolved via get_port_assignment so they must already
# be assigned before this runs.
_substitute_template_vars() {
    local content="$1"

    content="${content//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
    content="${content//\{\{PHP_VERSION\}\}/$SELECTED_PHP_VERSION}"
    content="${content//\{\{MYSQL_VERSION\}\}/$SELECTED_MYSQL_VERSION}"
    content="${content//\{\{MEILISEARCH_VERSION\}\}/$MEILISEARCH_VERSION}"
    content="${content//\{\{ELASTICSEARCH_VERSION\}\}/$ELASTICSEARCH_VERSION}"
    content="${content//\{\{NGINX_DOCROOT\}\}/$NGINX_DOCROOT}"

    local port_var port_val
    for port_var in APP_PORT FORWARD_DB_PORT FORWARD_REDIS_PORT FORWARD_MAILPIT_PORT \
                    FORWARD_MEILISEARCH_PORT FORWARD_ELASTICSEARCH_PORT; do
        port_val=$(get_port_assignment "$port_var")
        content="${content//\{\{$port_var\}\}/$port_val}"
    done

    printf '%s' "$content"
}

# Internal: replace a single marker line in a multi-line template with replacement
# content. When replacement is empty the marker line disappears entirely.
_replace_marker_line() {
    local template="$1"
    local marker="$2"
    local replacement="$3"
    local output=""
    local line

    while IFS= read -r line; do
        if [ "$line" = "$marker" ]; then
            output+="$replacement"
        else
            output+="$line"$'\n'
        fi
    done <<< "$template"

    printf '%s' "$output"
}

# Fetch a template, substitute {{VAR}} placeholders, write to dest atomically.
fetch_template() {
    local rel="$1"
    local dest="$2"
    local content

    content=$(_fetch_raw_template "$rel")
    content=$(_substitute_template_vars "$content")

    # Note the `\n` — command substitution strips trailing newlines, so we
    # restore one to keep files POSIX-friendly (`text file should end with newline`).
    local tmp="${dest}.shipyard.tmp"
    printf '%s\n' "$content" > "$tmp"
    if ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        exit_with_error $EXIT_TEMPLATE_FETCH_FAILED "Failed to write template to: $dest"
    fi
}

# Assemble service + volume blocks from the optional service fragments the
# user opted into. Results are written to ASSEMBLED_SERVICES_BLOCK and
# ASSEMBLED_VOLUMES_BLOCK so callers can slot them into compose templates.
ASSEMBLED_SERVICES_BLOCK=""
ASSEMBLED_VOLUMES_BLOCK=""

assemble_optional_services() {
    ASSEMBLED_SERVICES_BLOCK=""
    ASSEMBLED_VOLUMES_BLOCK=""

    local service fragment svc vol
    for service in $OPTIONAL_SERVICES; do
        fragment=$(_fetch_raw_template "services/${service}.yml")
        # Split on the marker line: text before MARKER goes into services,
        # text after MARKER goes into volumes. Strip the newline that follows
        # the marker so each block starts at column 0, then ensure each block
        # ends with exactly one newline so multiple opted-in services stack
        # without their lines colliding.
        svc="${fragment%%# === SHIPYARD:VOLUME ===*}"
        vol="${fragment##*# === SHIPYARD:VOLUME ===}"
        vol="${vol#$'\n'}"
        case "$svc" in *$'\n') ;; *) svc+=$'\n' ;; esac
        case "$vol" in *$'\n') ;; *) vol+=$'\n' ;; esac
        ASSEMBLED_SERVICES_BLOCK+="$svc"
        ASSEMBLED_VOLUMES_BLOCK+="$vol"
    done
}

# Compute the port variable list for legacy presets (no compose file exists yet,
# so we can't use extract_port_vars). Output matches extract_port_vars format:
# one VAR:DEFAULT_PORT per line.
compute_legacy_port_vars() {
    echo "APP_PORT:80"
    echo "FORWARD_DB_PORT:3306"
    echo "FORWARD_REDIS_PORT:6379"
    echo "FORWARD_MAILPIT_PORT:8025"

    local service
    for service in $OPTIONAL_SERVICES; do
        case "$service" in
            meilisearch)   echo "FORWARD_MEILISEARCH_PORT:7700" ;;
            elasticsearch) echo "FORWARD_ELASTICSEARCH_PORT:9200" ;;
        esac
    done
}

# Scaffold the full docker stack for a legacy preset. Must be called after
# port assignment so {{*_PORT}} placeholders can resolve.
scaffold_stack() {
    local preset="$1"

    # cake-2 needs the project layout + docroot resolved before nginx.conf is
    # substituted, since the docroot lands in the nginx template.
    if [ "$preset" = "cakephp-2" ]; then
        detect_cake_config_dir
        prompt_cake_docroot
    fi

    echo ""
    log_info "Scaffolding $preset stack..."

    assemble_optional_services

    local compose
    compose=$(_fetch_raw_template "${preset}/docker-compose.yml")
    compose=$(_replace_marker_line "$compose" '    # {{OPTIONAL_SERVICES}}' "$ASSEMBLED_SERVICES_BLOCK")
    compose=$(_replace_marker_line "$compose" '    # {{OPTIONAL_VOLUMES}}' "$ASSEMBLED_VOLUMES_BLOCK")
    compose=$(_substitute_template_vars "$compose")

    local tmp="${COMPOSE_FILE}.shipyard.tmp"
    printf '%s\n' "$compose" > "$tmp"
    if ! mv "$tmp" "$COMPOSE_FILE"; then
        rm -f "$tmp"
        exit_with_error $EXIT_TEMPLATE_FETCH_FAILED "Failed to write $COMPOSE_FILE"
    fi
    log_success "Wrote $COMPOSE_FILE"
    REVIEW_FILES+=("$COMPOSE_FILE")

    fetch_template "${preset}/Dockerfile" "Dockerfile"
    log_success "Wrote Dockerfile"
    REVIEW_FILES+=("Dockerfile")

    fetch_template "${preset}/nginx.conf" "nginx.conf"
    log_success "Wrote nginx.conf"
    REVIEW_FILES+=("nginx.conf")

    fetch_template "${preset}/php.ini" "php.ini"
    log_success "Wrote php.ini"
    REVIEW_FILES+=("php.ini")

    # cake-2 specific: clone an existing env folder, patch the docker bits,
    # and generate the per-machine local.php selector.
    if [ "$preset" = "cakephp-2" ]; then
        scaffold_cakephp_env
    fi
}

# ==============================================================================
# CAKEPHP 2 SCAFFOLDING HELPERS
# ==============================================================================

detect_cake_config_dir() {
    if [ -d "app/Config" ]; then
        CAKE_CONFIG_DIR="app/Config"
    elif [ -d "Config" ]; then
        CAKE_CONFIG_DIR="Config"
    else
        exit_with_error $EXIT_CAKE_LAYOUT_NOT_FOUND \
            "CakePHP 2 layout not found.
Expected either 'app/Config/' or 'Config/' in: $(pwd)
Are you running 'shipyard init' from the project root?"
    fi
    log_success "Found CakePHP 2 config dir: $CAKE_CONFIG_DIR"
}

prompt_cake_docroot() {
    # Callers can pre-seed NGINX_DOCROOT (handy for tests/automation).
    if [ -n "$NGINX_DOCROOT" ]; then
        log_success "Using preset docroot: $NGINX_DOCROOT"
        return
    fi

    local candidates=("public_html" "app/webroot" "webroot")
    local detected=""
    local c
    for c in "${candidates[@]}"; do
        if [ -d "$c" ]; then
            detected="$c"
            break
        fi
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}📂 Web Document Root${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ -n "$detected" ]; then
        echo -e "${DIM}Detected docroot:${NC} ${BOLD}$detected${NC}"
        echo -n "Use this? [Y/n]: "
        local response
        read -r response
        response=${response:-Y}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            NGINX_DOCROOT="$detected"
            log_success "Docroot: $NGINX_DOCROOT"
            return
        fi
    else
        log_warning "No standard docroot found (looked for: ${candidates[*]})"
    fi

    while true; do
        echo -n "Docroot path (relative to project root): "
        read -r NGINX_DOCROOT
        if [ -z "$NGINX_DOCROOT" ]; then
            echo -e "${YELLOW}Docroot cannot be empty.${NC}"
            continue
        fi
        if [ ! -d "$NGINX_DOCROOT" ]; then
            log_warning "Path '$NGINX_DOCROOT' does not exist yet — accepting anyway."
        fi
        log_success "Docroot: $NGINX_DOCROOT"
        break
    done
}

# Find a source env folder under CAKE_CONFIG_DIR. Prefers `dev/`, otherwise
# picks the first folder containing bootstrap.php + database.php (excluding
# the destination `docker/`).
detect_cake_source_env() {
    local dev="$CAKE_CONFIG_DIR/dev"
    if [ -d "$dev" ] && [ -f "$dev/bootstrap.php" ] && [ -f "$dev/database.php" ]; then
        CAKE_SOURCE_ENV_FOLDER="$dev"
        log_success "Source env folder: $CAKE_SOURCE_ENV_FOLDER"
        return
    fi

    local entry name
    for entry in "$CAKE_CONFIG_DIR"/*/; do
        [ -d "$entry" ] || continue
        name=$(basename "$entry")
        if [ "$name" = "docker" ]; then
            continue
        fi
        if [ -f "${entry}bootstrap.php" ] && [ -f "${entry}database.php" ]; then
            CAKE_SOURCE_ENV_FOLDER="${entry%/}"
            log_success "Source env folder: $CAKE_SOURCE_ENV_FOLDER (fallback, no dev/)"
            return
        fi
    done

    exit_with_error $EXIT_CAKE_LAYOUT_NOT_FOUND \
        "No source env folder found under $CAKE_CONFIG_DIR/.
Expected at least one subfolder (e.g. dev/) containing bootstrap.php + database.php to clone from."
}

# If docker/ already exists, prompt overwrite. Aborts on decline.
check_cake_docker_dest() {
    local dest="$CAKE_CONFIG_DIR/docker"
    if [ -d "$dest" ]; then
        echo ""
        log_warning "$dest already exists."
        echo -n "Overwrite it with a fresh clone of $CAKE_SOURCE_ENV_FOLDER? [y/N]: "
        local response
        read -r response
        response=${response:-N}
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit_with_error $EXIT_USER_CANCELLED \
                "Aborted: $dest already exists and overwrite declined."
        fi
        rm -rf "$dest"
    fi
}

clone_cake_env_folder() {
    local dest="$CAKE_CONFIG_DIR/docker"
    cp -R "$CAKE_SOURCE_ENV_FOLDER" "$dest"
    log_success "Cloned $CAKE_SOURCE_ENV_FOLDER → $dest"
}

# Patch the cloned database.php: rewrite host/login/password/database in $default.
patch_cake_database_php() {
    local file="$CAKE_CONFIG_DIR/docker/database.php"
    if [ ! -f "$file" ]; then
        return
    fi

    local tmp="${file}.shipyard.tmp"
    awk -v project="$PROJECT_NAME" '
        BEGIN { in_default = 0 }
        /^[[:space:]]*public[[:space:]]+\$default[[:space:]]*=[[:space:]]*array[[:space:]]*\(/ {
            in_default = 1
            print
            next
        }
        in_default {
            if ($0 ~ /^[[:space:]]*\)[[:space:]]*;/) {
                in_default = 0
                print
                next
            }
            if ($0 ~ /\047host\047[[:space:]]*=>/) {
                sub(/\047host\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047host\047 => \047mysql\047", $0)
            }
            if ($0 ~ /\047login\047[[:space:]]*=>/) {
                sub(/\047login\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047login\047 => \047sail\047", $0)
            }
            if ($0 ~ /\047password\047[[:space:]]*=>/) {
                sub(/\047password\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047password\047 => \047password\047", $0)
            }
            if ($0 ~ /\047database\047[[:space:]]*=>/) {
                sub(/\047database\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047database\047 => \047" project "\047", $0)
            }
            print
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    log_success "Patched $file"
    REVIEW_FILES+=("$file")
}

# Patch the cloned email.php: rewrite host → mailpit and port → 1025 wherever
# they appear as array keys. (Email files often have multiple transport blocks.)
patch_cake_email_php() {
    local file="$CAKE_CONFIG_DIR/docker/email.php"
    if [ ! -f "$file" ]; then
        return
    fi

    local tmp="${file}.shipyard.tmp"
    awk '
        {
            if ($0 ~ /\047host\047[[:space:]]*=>/) {
                sub(/\047host\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047host\047 => \047mailpit\047", $0)
            }
            if ($0 ~ /\047port\047[[:space:]]*=>/) {
                sub(/\047port\047[[:space:]]*=>[[:space:]]*[0-9]+/, "\047port\047 => 1025", $0)
                sub(/\047port\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047port\047 => 1025", $0)
            }
            print
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    log_success "Patched $file"
    REVIEW_FILES+=("$file")
}

# Patch SITE_URL define + the first 'url' => 'http(s)://...' entry per file
# (the latter catches the Site.url in config.php). Best-effort — surfaced in
# the review summary so the user can verify.
patch_cake_site_url() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return
    fi

    local target="http://${PROJECT_NAME}.test/"
    local tmp="${file}.shipyard.tmp"

    awk -v target="$target" '
        BEGIN { url_patched = 0 }
        {
            if ($0 ~ /define[[:space:]]*\([[:space:]]*\047SITE_URL\047[[:space:]]*,/) {
                sub(/define[[:space:]]*\([[:space:]]*\047SITE_URL\047[[:space:]]*,[[:space:]]*\047[^\047]*\047[[:space:]]*\)/, "define(\047SITE_URL\047, \047" target "\047)", $0)
            }
            if (!url_patched && $0 ~ /\047url\047[[:space:]]*=>[[:space:]]*\047https?:\/\//) {
                sub(/\047url\047[[:space:]]*=>[[:space:]]*\047[^\047]*\047/, "\047url\047 => \047" target "\047", $0)
                url_patched = 1
            }
            print
        }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    log_success "Patched $file"
    REVIEW_FILES+=("$file")
}

# Generate (or prompt overwrite) of app/Config/local.php — the per-machine
# selector that points CakePHP at the docker env folder.
write_cake_local_php() {
    local file="$CAKE_CONFIG_DIR/local.php"
    local content
    content="<?php
Configure::write('env', 'docker');

define('SITE_URL', 'http://${PROJECT_NAME}.test/');

include Configure::read('env') . '/bootstrap.php';
"

    if [ -f "$file" ]; then
        echo ""
        log_warning "$file already exists."
        echo -n "Overwrite with the docker selector? [y/N]: "
        local response
        read -r response
        response=${response:-N}
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Keeping existing $file. To switch to docker manually, set:"
            echo -e "  ${DIM}Configure::write('env', 'docker');${NC}"
            return
        fi
    fi

    printf '%s' "$content" > "$file"
    log_success "Wrote $file"
    REVIEW_FILES+=("$file")
}

# Orchestrate the cake-2 env folder clone + patch + local.php generation.
scaffold_cakephp_env() {
    detect_cake_source_env
    check_cake_docker_dest
    clone_cake_env_folder
    patch_cake_database_php
    patch_cake_email_php
    patch_cake_site_url "$CAKE_CONFIG_DIR/docker/bootstrap.php"
    patch_cake_site_url "$CAKE_CONFIG_DIR/docker/config.php"
    write_cake_local_php
}

# Print the review-these-files block at end of init. No-op if nothing tracked.
print_review_summary() {
    if [ ${#REVIEW_FILES[@]} -eq 0 ]; then
        return
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}📋 Review checklist${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${DIM}Shipyard created or patched the files below. Skim them before${NC}"
    echo -e "${DIM}committing — auto-patches are best-effort and may need touch-ups.${NC}"
    echo ""
    local f
    for f in "${REVIEW_FILES[@]}"; do
        echo -e "  ${DIM}•${NC} $f"
    done
    echo ""
}

# ==============================================================================
# PRESET WIZARD FUNCTIONS
# ==============================================================================

prompt_preset() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}🧰 Project Preset${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${DIM}What kind of project is this?${NC}"
    echo -e "  ${CYAN}[1]${NC} Laravel Sail ${DIM}(existing docker-compose.yml)${NC}"
    echo -e "  ${CYAN}[2]${NC} Laravel Legacy ${DIM}(pre-Sail Laravel 6/7/8 on PHP 7.x)${NC}"
    echo -e "  ${CYAN}[3]${NC} CakePHP 2 ${DIM}(PHP 5.6/7.x with per-env config folders)${NC}"
    echo ""

    while true; do
        echo -n "Select preset [1]: "
        read -r selection
        selection=${selection:-1}

        case $selection in
            1) PRESET="sail"; log_success "Selected: Laravel Sail"; break ;;
            2) PRESET="laravel-legacy"; log_success "Selected: Laravel Legacy"; break ;;
            3) PRESET="cakephp-2"; log_success "Selected: CakePHP 2"; break ;;
            *) echo -e "${YELLOW}Invalid selection. Choose 1, 2, or 3.${NC}" ;;
        esac
    done
}

prompt_php_version() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}🐘 PHP Version${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local versions default_version
    if [ "$PRESET" = "laravel-legacy" ]; then
        versions=("7.2" "7.3" "7.4")
        default_version="7.4"
    else
        versions=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4")
        default_version="7.4"
    fi

    echo -e "${DIM}Choose the PHP version for the docker stack:${NC}"
    local i=1
    local default_index=1
    for v in "${versions[@]}"; do
        if [ "$v" = "$default_version" ]; then
            echo -e "  ${CYAN}[$i]${NC} PHP $v ${DIM}(default)${NC}"
            default_index=$i
        else
            echo -e "  ${CYAN}[$i]${NC} PHP $v"
        fi
        i=$((i + 1))
    done
    echo ""

    while true; do
        echo -n "Select PHP version [$default_index]: "
        read -r selection
        selection=${selection:-$default_index}

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#versions[@]}" ]; then
            SELECTED_PHP_VERSION="${versions[$((selection - 1))]}"
            log_success "Selected: PHP $SELECTED_PHP_VERSION"
            break
        else
            echo -e "${YELLOW}Invalid selection. Choose a number between 1 and ${#versions[@]}.${NC}"
        fi
    done
}

prompt_mysql_version() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}🐬 MySQL Version${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # PHP ≤ 7.2 → default 5.7; newer → 8.0
    local default_version="8.0"
    case "$SELECTED_PHP_VERSION" in
        5.6|7.0|7.1|7.2) default_version="5.7" ;;
    esac

    local versions=("5.6" "5.7" "8.0")

    echo -e "${DIM}Choose the MySQL version for the docker stack:${NC}"
    local i=1
    local default_index=1
    for v in "${versions[@]}"; do
        if [ "$v" = "$default_version" ]; then
            echo -e "  ${CYAN}[$i]${NC} MySQL $v ${DIM}(default for PHP $SELECTED_PHP_VERSION)${NC}"
            default_index=$i
        else
            echo -e "  ${CYAN}[$i]${NC} MySQL $v"
        fi
        i=$((i + 1))
    done
    echo ""

    while true; do
        echo -n "Select MySQL version [$default_index]: "
        read -r selection
        selection=${selection:-$default_index}

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#versions[@]}" ]; then
            SELECTED_MYSQL_VERSION="${versions[$((selection - 1))]}"
            log_success "Selected: MySQL $SELECTED_MYSQL_VERSION"
            break
        else
            echo -e "${YELLOW}Invalid selection. Choose a number between 1 and ${#versions[@]}.${NC}"
        fi
    done
}

prompt_optional_services() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}🧩 Optional Services${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${DIM}Base stack always includes php, nginx, mysql, redis, mailpit.${NC}"
    echo -e "${DIM}Add a search engine only if your project actually uses one.${NC}"
    echo ""

    local response

    echo -n "Include Meilisearch? [y/N]: "
    read -r response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
        OPTIONAL_SERVICES="${OPTIONAL_SERVICES} meilisearch"
        echo -n "  Meilisearch image tag [latest]: "
        read -r tag
        MEILISEARCH_VERSION="${tag:-latest}"
        log_success "Meilisearch enabled (getmeili/meilisearch:$MEILISEARCH_VERSION)"
    fi

    echo -n "Include Elasticsearch? [y/N]: "
    read -r response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
        OPTIONAL_SERVICES="${OPTIONAL_SERVICES} elasticsearch"
        echo -n "  Elasticsearch image tag [7.17.28]: "
        read -r tag
        ELASTICSEARCH_VERSION="${tag:-7.17.28}"
        log_success "Elasticsearch enabled (docker.elastic.co/elasticsearch/elasticsearch:$ELASTICSEARCH_VERSION)"
    fi

    # Trim leading whitespace
    OPTIONAL_SERVICES="${OPTIONAL_SERVICES# }"

    if [ -z "$OPTIONAL_SERVICES" ]; then
        echo ""
        log_info "No optional services selected — base stack only"
    fi
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

    # Step 1: Get project name and check if already registered (fail fast!)
    ensure_compose_project_name
    log_info "Project identifier: $PROJECT_NAME"

    # Step 2: Load existing registry (read-only, no lock needed yet)
    parse_ini_file

    # Step 3: Check if project already registered (before any other validation or user input)
    if is_project_registered "$PROJECT_NAME"; then
        exit_with_error $EXIT_ALREADY_REGISTERED \
            "Project '$PROJECT_NAME' is already registered in the port registry.

Registry file: $REGISTRY_FILE

To re-assign ports, manually remove the [$PROJECT_NAME] section from the registry."
    fi
    log_success "Project not yet registered"

    # Step 4: Choose preset (first user input — drives branching below)
    prompt_preset

    # Step 5: For legacy presets, collect stack details now so they're available
    # before scaffolding and port assignment
    if [ "$PRESET" != "sail" ]; then
        prompt_php_version
        prompt_mysql_version
        prompt_optional_services
    fi

    # Step 6: Check if .env file already exists (sail/laravel-legacy only;
    # cakephp-2 uses per-env config folders and is handled separately in Step 4)
    if [ "$PRESET" = "sail" ] || [ "$PRESET" = "laravel-legacy" ]; then
        check_env_already_initialized
        log_success ".env file does not exist yet"
    fi

    # Step 7: Validate Docker is installed and running
    validate_docker

    # Step 8: Check for Docker network issues
    check_docker_networks

    # Step 9: Validate docker-compose.yml exists (sail only — legacy presets
    # scaffold the compose file in Step 3)
    if [ "$PRESET" = "sail" ]; then
        validate_docker_compose
    fi

    # Step 10: Collect all user input upfront
    collect_user_input

    # Step 9: Write auth.json (when needed) and run composer install
    write_composer_auth_json
    run_composer_install

    # Step 10: Validate/create .env file
    validate_env_file

    # Step 11: Check .env for existing port definitions
    check_env_for_ports

    # Step 12: Acquire lock on registry
    acquire_lock
    log_success "Acquired registry lock"

    # Step 13: Reload registry and clean up stale projects (now with lock held)
    # Note: We already loaded the registry earlier for the duplicate check,
    # but we need to reload it here with the lock to ensure we have the latest state
    parse_ini_file
    cleanup_stale_projects

    local num_other_projects=${#REGISTRY_PROJECTS[@]}
    if [ $num_other_projects -gt 0 ]; then
        log_success "Loaded existing registry ($num_other_projects other project(s))"
    else
        log_success "Registry is empty (first project)"
    fi

    # Step 14: Build port variable list. Sail reads them from the existing
    # docker-compose.yml; legacy presets don't have a compose file yet, so the
    # list is computed from the chosen preset + opted-in optional services.
    local port_vars_output
    local port_vars_array=()
    if [ "$PRESET" = "sail" ]; then
        port_vars_output=$(extract_port_vars)
    else
        port_vars_output=$(compute_legacy_port_vars)
    fi
    while IFS= read -r port_var; do
        [ -z "$port_var" ] && continue
        port_vars_array+=("$port_var")
    done <<< "$port_vars_output"
    local num_port_vars=${#port_vars_array[@]}
    if [ "$PRESET" = "sail" ]; then
        log_success "Extracted $num_port_vars port variable(s) from docker-compose.yml"
    else
        log_success "Computed $num_port_vars port variable(s) for preset '$PRESET'"
    fi

    echo ""
    log_info "Assigning ports:"

    # Step 15: Assign ports
    for port_var in "${port_vars_array[@]}"; do
        local var_name="${port_var%:*}"
        local default_port="${port_var#*:}"

        # Convert default port to starting point
        local start_port=$(convert_port "$default_port")

        # Find next available port
        local assigned_port=$(find_next_available_port "$start_port" "$var_name")

        # Store assignment
        set_port_assignment "$var_name" "$assigned_port"

        # Log assignment
        if [ "$assigned_port" = "$start_port" ]; then
            log_info "  $var_name: $start_port → $assigned_port ✓ available"
        else
            log_info "  $var_name: $start_port → $assigned_port ($start_port taken) ✓ available"
        fi
    done

    echo ""

    # Step 15.5: For legacy presets, scaffold the docker stack now that ports
    # are assigned. Sail keeps its existing compose file untouched.
    if [ "$PRESET" != "sail" ]; then
        scaffold_stack "$PRESET"
        echo ""
    fi

    # Step 16: Domain registration (non-interactive)
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

        # Still create empty certificate files even without domain
        log_info "Setting up certificate files..."
        symlink_certificates
        update_gitignore_for_certs
        echo ""
    fi

    # Step 17: Save registry
    save_registry
    log_success "Updated registry: $REGISTRY_FILE"

    # Step 18: Append to .env
    append_ports_to_env

    # Build success message with APP_URL info
    local success_msg="Added $num_port_vars port assignment(s) to top of .env file"
    if [ "$DOMAIN_REGISTERED" = true ]; then
        if [ "$USE_SECURE_PROXY" = true ]; then
            success_msg="$success_msg (APP_URL=https://${REGISTERED_DOMAIN}.${DOMAIN_TLD})"
        else
            success_msg="$success_msg (APP_URL=http://${REGISTERED_DOMAIN}.${DOMAIN_TLD})"
        fi
    else
        local app_port
        app_port=$(get_port_assignment "APP_PORT")
        if [ -n "$app_port" ]; then
            success_msg="$success_msg (APP_URL=http://localhost:${app_port})"
        fi
    fi
    log_success "$success_msg"

    # Step 19: Release lock
    release_lock

    # Success message
    echo ""
    log_success "Project setup complete! Assigned $num_port_vars ports to '$PROJECT_NAME'."

    # Step 20: Run post-setup commands (non-interactive)
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
        log_info "Step 2/2: Running Composer setup (vendor/bin/sail composer setup)..."
        ./vendor/bin/sail composer setup

        if [ $? -ne 0 ]; then
            echo ""
            log_error "Composer setup failed. You may need to run this manually:"
            echo "  ./vendor/bin/sail composer setup"
            exit 9
        fi
        log_success "Composer setup completed"

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
            local app_port
            app_port=$(get_port_assignment "APP_PORT")
            echo -e "${DIM}Docker is listening on localhost:${app_port}${NC}"
            echo -e "${DIM}Valet/Herd proxy: ${REGISTERED_DOMAIN}.${DOMAIN_TLD} → localhost:${app_port}${NC}"
        else
            local app_port
            app_port=$(get_port_assignment "APP_PORT")
            if [ -n "$app_port" ]; then
            echo ""
            echo -e "${BOLD}Your application should be accessible at:${NC}"
            echo -e "  ${CYAN}http://localhost:${app_port}${NC}"
            fi
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

    print_review_summary
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

# Parse arguments before running main
parse_arguments "$@"

# Run main function
main
