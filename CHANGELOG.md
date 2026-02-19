# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-02-19

### Changed
- Composer installation now detects and uses the correct PHP version from docker-compose.yml configuration

### Fixed
- Prevent Docker mount errors by creating empty certificate files as placeholders if there are no certificates (because user chose no domain or chose a domain without https)

## [0.3.0] - 2026-02-18

### Added
- `list` command to display all registered projects with their paths, domains, and port assignments
- `cleanup` command to manually remove stale projects from the registry and clean up their resources (proxy configurations, Docker volumes)
- Option to choose between HTTP and HTTPS for proxy configuration (via `--secure` flag)
- User prompt to select protocol when registering domains

### Changed
- Improved script output for better readability and user experience
- Enhanced domain registration to support both HTTP and HTTPS modes

### Fixed
- Fixed cleanup command to properly handle stale projects and Docker resources

## [0.2.3] - 2026-02-18

### Changed
- Project name generation now always normalizes to valid Docker Compose format (lowercase, alphanumeric characters and underscores only)
- `COMPOSE_PROJECT_NAME` is now always set in `.env` file based on the normalized project path, ensuring consistency with Docker Compose behavior
- Simplified project name handling by removing conditional logic for `COMPOSE_PROJECT_NAME` assignment

### Fixed
- Project names now properly match Docker Compose project names, avoiding container naming conflicts

## [0.2.2] - 2026-02-18

### Added
- Documentation on how to configure Laravel Sail and Vite when using a domain with SSL certificates

### Changed
- Stale project cleanup now automatically removes Docker volumes for projects that no longer exist

### Fixed
- Improved Docker network error handling to prevent IP address pool exhaustion issues

## [0.2.1] - 2026-02-18

### Fixed
- Fixed docker-compose.yml detection after introducing `init` command (was incorrectly looking for file named "init")

## [0.2.0] - 2026-02-18

### Changed
- **BREAKING**: Command usage changed from `shipyard` to `shipyard init` for project initialization
- Running `shipyard` without arguments now shows help instead of starting setup
- Renamed registry file from `ports.lock` to `projects.conf` to better reflect its expanded purpose
- Registry now tracks domain and proxy service (valet/herd) information in addition to ports
- Updated registry file header to reflect new "Project Registry" purpose
- Stale project cleanup now automatically removes proxy configurations when projects with registered domains are removed

### Added
- `init` command for explicit project initialization
- Domain tracking in project registry (`domain` field)
- Proxy service tracking in project registry (`proxy_service` field)
- Automatic proxy cleanup via `valet unproxy` or `herd unproxy` when stale projects are removed
- Automatic version check on startup with update prompt when newer version is available
- Non-blocking update check with 5-second timeout to avoid hanging on slow connections

## [0.1.0] - 2026-02-17

### Added
- Initial release
- Automatic port assignment with conflict detection
- Global port registry at `~/.config/shipyard/projects.conf`
- Port conversion strategy (converts to 4-digit ports ending in 00)
- System port availability checking via `/dev/tcp` and `lsof`
- Domain registration support for Laravel Valet and Laravel Herd
- SSL certificate management and symlinking to `certificates/` directory
- Composer installation with private repository authentication
- Interactive setup wizard with upfront input collection
- Docker validation (checks if installed and running)
- Post-setup commands (optional container startup and Laravel setup)
- Stale project cleanup (removes projects whose paths no longer exist)
- Graceful interrupt handling (Ctrl+C cleanup)
- `--version` flag to show current version
- `--update` flag for self-updating from GitHub releases
- `--help` flag for usage information
- Cross-platform support (macOS, Linux, Windows Git Bash/WSL)
- Universal install script (`install.sh`) for easy installation

### Features
- **Port Registry**: Tracks port assignments across all projects to prevent conflicts
- **Port Assignment**: Intelligently finds available ports and handles conflicts automatically
- **Domain Registration**: Seamless integration with Valet/Herd for local domain setup
- **SSL Certificates**: Automatic certificate generation and project-local symlinking
- **Private Repositories**: Supports authentication for private Composer repositories
- **Environment Configuration**: Automatically configures `.env` with ports and URLs
- **Project Identification**: Uses `COMPOSE_PROJECT_NAME` or generates from path
- **Lock Mechanism**: Atomic registry locking using `mkdir` for cross-platform compatibility
- **Self-Updating**: Built-in update mechanism via GitHub releases API

### Technical Details
- Written in Bash for maximum compatibility
- Uses semantic versioning (v0.1.0)
- Atomic file operations for registry and `.env` updates
- Proper error handling with meaningful exit codes
- Clean interrupt handling (releases locks on Ctrl+C)
- No external dependencies beyond curl, Docker, and standard Unix tools
