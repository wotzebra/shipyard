#!/usr/bin/env bash

# ==============================================================================
# Shipyard Installation Script
# ==============================================================================
# Installs Shipyard to ~/.local/bin/shipyard and ensures it's in PATH
# ==============================================================================

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Configuration
readonly INSTALL_DIR="$HOME/.local/bin"
readonly INSTALL_PATH="$INSTALL_DIR/shipyard"
readonly GITHUB_REPO="wotzebra/shipyard"
readonly GITHUB_API="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

# ==============================================================================
# Helper Functions
# ==============================================================================

log_info() {
    echo -e "$1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# ==============================================================================
# Installation Functions
# ==============================================================================

check_dependencies() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not installed."
        echo ""
        echo "Please install curl and try again."
        exit 1
    fi
    log_success "curl is installed"
}

create_install_directory() {
    if [ ! -d "$INSTALL_DIR" ]; then
        log_info "Creating installation directory: $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
        log_success "Created $INSTALL_DIR"
    else
        log_success "Installation directory exists"
    fi
}

fetch_latest_version() {
    log_info "Fetching latest release information..."

    local API_RESPONSE
    API_RESPONSE=$(curl -fsSL "$GITHUB_API" 2>/dev/null)

    if [ -z "$API_RESPONSE" ]; then
        log_error "Could not fetch latest release from GitHub"
        echo ""
        echo "This might be due to:"
        echo "  • Network connectivity issues"
        echo "  • GitHub API rate limiting"
        echo ""
        echo "Try again later or install manually from:"
        echo "https://github.com/$GITHUB_REPO/releases"
        exit 1
    fi

    # Extract version tag (remove 'v' prefix)
    LATEST_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        log_error "Could not parse latest version"
        exit 1
    fi

    log_success "Latest version: v$LATEST_VERSION"
}

download_shipyard() {
    log_info "Downloading shipyard v$LATEST_VERSION..."

    local DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v${LATEST_VERSION}/shipyard.sh"
    local TEMP_FILE="${INSTALL_PATH}.tmp"

    if ! curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_FILE"; then
        log_error "Failed to download shipyard"
        rm -f "$TEMP_FILE"
        echo ""
        echo "Download URL: $DOWNLOAD_URL"
        echo ""
        echo "Please try again or download manually from:"
        echo "https://github.com/$GITHUB_REPO/releases"
        exit 1
    fi

    # Verify download is not empty
    if [ ! -s "$TEMP_FILE" ]; then
        log_error "Downloaded file is empty"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    # Make executable and move to final location
    chmod +x "$TEMP_FILE"
    mv "$TEMP_FILE" "$INSTALL_PATH"

    log_success "Downloaded and installed to $INSTALL_PATH"
}

check_path() {
    # Check if $INSTALL_DIR is in PATH
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        log_success "$INSTALL_DIR is in PATH"
        return 0
    fi

    return 1
}

add_to_path() {
    log_warning "$INSTALL_DIR is not in your PATH"
    echo ""
    log_info "Attempting to add to PATH..."

    # Detect shell
    local SHELL_NAME=$(basename "$SHELL")
    local SHELL_CONFIG=""

    case "$SHELL_NAME" in
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                SHELL_CONFIG="$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                SHELL_CONFIG="$HOME/.bash_profile"
            fi
            ;;
        zsh)
            SHELL_CONFIG="$HOME/.zshrc"
            ;;
        fish)
            SHELL_CONFIG="$HOME/.config/fish/config.fish"
            ;;
        *)
            log_warning "Unknown shell: $SHELL_NAME"
            ;;
    esac

    if [ -z "$SHELL_CONFIG" ]; then
        log_warning "Could not determine shell configuration file"
        echo ""
        echo "Please manually add the following to your shell configuration:"
        echo ""
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        return 1
    fi

    # Check if already in config file
    if grep -q "\.local/bin" "$SHELL_CONFIG" 2>/dev/null; then
        log_info "PATH entry already exists in $SHELL_CONFIG"
        return 0
    fi

    # Add to PATH in config file
    echo "" >> "$SHELL_CONFIG"
    echo "# Added by Shipyard installer" >> "$SHELL_CONFIG"
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$SHELL_CONFIG"

    log_success "Added to PATH in $SHELL_CONFIG"
    echo ""
    log_info "Please restart your terminal or run:"
    echo ""
    echo "  source $SHELL_CONFIG"
    echo ""

    return 0
}

verify_installation() {
    if [ -x "$INSTALL_PATH" ]; then
        log_success "Installation verified"

        # Try to get version (only if in PATH)
        if command -v shipyard >/dev/null 2>&1; then
            local VERSION=$(shipyard --version 2>/dev/null || echo "unknown")
            log_info "Installed version: $VERSION"
        fi

        return 0
    else
        log_error "Installation failed - file not executable"
        return 1
    fi
}

# ==============================================================================
# Main Installation Flow
# ==============================================================================

main() {
    echo ""
    echo "=========================================="
    echo "Shipyard Installer"
    echo "=========================================="
    echo ""

    # Step 1: Check dependencies
    check_dependencies

    # Step 2: Create installation directory
    create_install_directory

    # Step 3: Fetch latest version
    fetch_latest_version

    # Step 4: Download and install
    download_shipyard

    # Step 5: Verify installation
    verify_installation

    # Step 6: Check/add to PATH
    if ! check_path; then
        add_to_path
    fi

    # Success message
    echo ""
    echo "=========================================="
    log_success "Shipyard installed successfully!"
    echo "=========================================="
    echo ""

    if check_path; then
        echo "Usage:"
        echo "  cd your-laravel-project"
        echo "  shipyard"
        echo ""
        echo "For help:"
        echo "  shipyard --help"
        echo ""
        echo "To update:"
        echo "  shipyard --update"
    else
        echo "Before using shipyard, please restart your terminal"
        echo "or run the source command shown above."
    fi
    echo ""
}

# Run installation
main
