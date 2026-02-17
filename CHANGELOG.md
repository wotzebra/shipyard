# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-02-17

### Added
- Initial release
- Automatic port assignment with conflict detection
- Global port registry at `~/.config/shipyard/ports.lock`
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

[0.1.0]: https://github.com/wotzebra/shipyard/releases/tag/v0.1.0
