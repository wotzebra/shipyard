# Shipyard

Laravel Sail project setup tool with automatic port assignment, SSL certificates, and local domain configuration.

## Features

- 🚢 **Automatic Port Assignment** - Intelligent port allocation across multiple Sail projects
- 🔍 **Port Conflict Detection** - Prevents conflicts with running services and other projects
- 🌐 **Local Domain Registration** - Seamless integration with Valet/Herd
- 🔒 **SSL Certificate Management** - Automatic SSL setup and symlinking
- 📦 **Composer Installation** - Handles private repository authentication
- 🧙 **Interactive Setup Wizard** - Collects all input upfront, then runs unattended
- 🔄 **Self-Updating** - Built-in update mechanism via `--update` flag

## Requirements

- **OS**: macOS, Linux, or Windows (with Git Bash or WSL)
- **Docker**: Docker Desktop installed and running
- **Project**: Laravel Sail project with `docker-compose.yml`
- **Optional**: Laravel Valet or Laravel Herd (for domain registration features)

## Installation

### Quick Install (Recommended)

One-line installation for all platforms:

```bash
curl -fsSL https://raw.githubusercontent.com/wotzebra/shipyard/main/install.sh | bash
```

After installation, restart your terminal or run:

```bash
source ~/.bashrc  # or ~/.zshrc depending on your shell
```

### Manual Installation

1. Download the latest release:
   ```bash
   curl -fsSL https://github.com/wotzebra/shipyard/releases/latest/download/shipyard.sh -o ~/.local/bin/shipyard
   chmod +x ~/.local/bin/shipyard
   ```

2. Ensure `~/.local/bin` is in your PATH:
   ```bash
   export PATH="$HOME/.local/bin:$PATH"
   ```

## Usage

Navigate to your Laravel Sail project directory and run:

```bash
shipyard init
```

### What Happens

The wizard will guide you through:

1. **Composer Authentication** - Provide credentials for private repositories
2. **Port Assignment** - Automatic detection and conflict resolution
3. **Domain Registration** (Optional) - Register a `.test` domain via Valet/Herd
4. **Protocol Selection** (If domain registered) - Choose between HTTPS (secure) or HTTP
5. **SSL Certificates** (If HTTPS selected) - Automatic certificate setup
6. **Post-Setup Commands** (Optional) - Start containers and run Laravel setup

### Commands

```bash
shipyard init      # Initialize project setup
shipyard list      # Show all registered projects
shipyard cleanup   # Clean up stale projects from registry
shipyard --version # Show version
shipyard --update  # Update to latest version
shipyard --help    # Show help
```

## How It Works

### Port Registry

Shipyard maintains a global registry at `~/.config/shipyard/projects.conf` that tracks project configurations including port assignments, domains, and proxy services across all your Sail projects. This prevents port conflicts when running multiple projects simultaneously.

**Registry format:**
```ini
[project-name]
path=/path/to/project
domain=my-project.test
proxy_service=valet
proxy_secure=true
APP_PORT=8000
VITE_PORT=5100
FORWARD_DB_PORT=3300
```

The `domain`, `proxy_service`, and `proxy_secure` fields are optional and only present if you registered a local domain through Valet or Herd. The `proxy_secure` field indicates whether HTTPS (`true`) or HTTP (`false`) was configured.

### Port Assignment Strategy

1. **Conversion** - Converts standard ports to 4-digit ports ending in 00
   - `80` → `8000`
   - `3306` → `3300`
   - `5173` → `5100`

2. **Availability Check** - Verifies port is not:
   - In the global registry (used by another project)
   - In use on the system (checked via `/dev/tcp` and `lsof`)

3. **Auto-Increment** - If port is taken, increments by 1 until available port is found

4. **Environment Configuration** - Writes port assignments to `.env` file:
   ```bash
   # Auto-assigned Docker Ports (via shipyard.sh)
   COMPOSE_PROJECT_NAME=project_name
   APP_URL=http://localhost:8000
   VITE_SERVER_HOST=localhost
   ASSET_URL="${APP_URL}"
   APP_PORT=8000
   VITE_PORT=5100
   FORWARD_DB_PORT=3300
   ```

### Domain Registration (Valet/Herd)

If you have Valet or Herd installed, Shipyard can:

1. **Register Proxy** - Creates a proxy: `myproject.test` → `http://localhost:8000`
2. **Choose Protocol** - Select between HTTPS (with SSL) or HTTP (without SSL)

#### HTTPS Mode (Recommended)

When you choose HTTPS:

1. **SSL Certificates** - Automatically generates SSL certificate via `--secure` flag
2. **Symlink Certificates** - Creates symlinks in `certificates/` directory:
   - `certificates/cert.crt` → Valet/Herd certificate
   - `certificates/cert.key` → Valet/Herd private key
3. **Update APP_URL** - Sets `APP_URL=https://myproject.test` in `.env`
4. **Update .gitignore** - Adds `/certificates` to `.gitignore`

**Result:** Access your app via `https://myproject.test` with valid SSL certificate.

#### HTTP Mode

When you choose HTTP:

1. **Non-Secure Proxy** - Creates proxy without SSL certificates
2. **Create Empty Certificates** - Creates empty `cert.key` and `cert.crt` files in `certificates/` directory
3. **Update APP_URL** - Sets `APP_URL=http://myproject.test` in `.env`
4. **Update .gitignore** - Adds `/certificates` to `.gitignore`

**Result:** Access your app via `http://myproject.test` (no SSL certificate needed).

#### No Domain

When you choose not to register a domain:

1. **Create Empty Certificates** - Creates empty `cert.key` and `cert.crt` files in `certificates/` directory
2. **Update .gitignore** - Adds `/certificates` to `.gitignore`

**Result:** Empty certificate files are created to prevent Docker mount errors. Access your app via `http://localhost:8000`.

### Using SSL Certificates with Vite Dev Server

When you register a domain with HTTPS mode, Shipyard creates certificate symlinks in the `certificates/` directory and automatically adds `/certificates` to your `.gitignore` file. To use these certificates with Vite's dev server inside your Sail container:

#### 1. Mount Certificates in Docker Compose

Add the certificates volume mount to your `docker-compose.yml`:

```yaml
services:
    laravel.test:
        - type: bind
              source: './certificates'
              target: /var/www/certificates
              read_only: true
```

**Note:** The `read_only: true` flag prevents accidental modification of your SSL certificates.

**Important:** The `certificates/` directory is automatically added to your `.gitignore` file by Shipyard, as these are symlinks to your local Valet/Herd certificates and should not be committed to version control.

#### 2. Configure Vite for HTTPS

Update your `vite.config.js` to use the certificates when running in HTTPS mode:

```javascript
import tailwindcss from '@tailwindcss/vite';
import laravel from 'laravel-vite-plugin';
import {defineConfig, loadEnv} from 'vite';
import fs from 'fs';

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), '');

    return {
        build: {
            sourcemap: true,
        },
        plugins: [
            laravel({
                input: [
                    'resources/css/app.css',
                    'resources/js/app.js',
                ],
                refresh: true,
            }),
            tailwindcss(),
        ],
        ...(env.VITE_SERVER_HOST !== 'localhost' && {
            server: {
                host: env.VITE_SERVER_HOST,
                hmr: {
                    host: env.VITE_SERVER_HOST,
                },
                ...(fs.existsSync('/var/www/certificates/cert.key') && fs.existsSync('/var/www/certificates/cert.crt') && fs.statSync('/var/www/certificates/cert.key').size > 0 && fs.statSync('/var/www/certificates/cert.crt').size > 0 && {
                    https: {
                        key: fs.readFileSync('/var/www/certificates/cert.key'),
                        cert: fs.readFileSync('/var/www/certificates/cert.crt'),
                    },
                }),
            },
        }),
    };
});
```

#### 3. Environment Configuration

When Shipyard registers a domain (with or without HTTPS mode), it automatically updates your `.env` file:

```bash
APP_URL=https://myproject.test
VITE_SERVER_HOST=myproject.test
ASSET_URL="${APP_URL}"
```

**How it works:**
- When `VITE_SERVER_HOST` is set to your domain (not `localhost`), Vite uses that domain as its host
- When SSL certificates are available, Vite uses HTTPS with the mounted certificates
- Hot Module Replacement (HMR) connects via `wss://myproject.test`
- Assets are served on the correct domain (with valid SSL certificates)

#### 4. Start Development

```bash
# Start Sail containers
sail up -d

# Start Vite dev server (with HTTPS)
sail npm run dev
```

Your app will be accessible at `https://myproject.test` with:
- Valid SSL certificate (no browser warnings)
- Hot Module Replacement working over WSS
- All assets served securely

## Updating

Shipyard automatically checks for updates when you run it and will prompt you to update if a newer version is available.

To manually update to the latest version:

```bash
shipyard --update
```

This will:
- Check GitHub for the latest release
- Download and replace the current script
- Preserve executable permissions
- Show version change information

**Note:** The automatic update check has a 5-second timeout and fails silently if GitHub is unreachable, so it won't block your workflow.

## Uninstalling

Remove the script:

```bash
rm ~/.local/bin/shipyard
```

Remove the port registry (optional):

```bash
rm -rf ~/.config/shipyard
```

Remove PATH entry from shell config (optional):

```bash
# Edit ~/.bashrc or ~/.zshrc and remove:
export PATH="$HOME/.local/bin:$PATH"
```

## Troubleshooting

### "command not found: shipyard"

**Cause:** `~/.local/bin` is not in your PATH.

**Solution:**
1. Restart your terminal, or
2. Run: `source ~/.bashrc` (or `~/.zshrc`), or
3. Manually add to PATH:
   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

### "Docker is not running"

**Cause:** Docker Desktop is not started.

**Solution:**
- Start Docker Desktop
- Verify with: `docker info`

### Docker Network Error: "could not find an available, non-overlapping IPv4 address pool"

**Cause:** Docker has run out of available IP address ranges due to too many unused networks.

**Solution:**

Shipyard will automatically detect this issue and offer to clean up unused networks. You can also manually clean up:

```bash
docker network prune -f
```

Or remove specific networks:
```bash
docker network ls
docker network rm <network-id>
```

**Prevention:** Regularly clean up stopped containers and unused networks:
```bash
docker system prune -f
```

### Port Already in Use

**Cause:** Port is in use by another service or project.

**Solution:** Shipyard automatically handles this by incrementing to the next available port. No action needed.

### Project Already Registered

**Cause:** Project already has port assignments in the registry.

**Solution:**
- To re-assign ports: Remove the project section from `~/.config/shipyard/projects.conf`
- Or: Use the existing port assignments (check your `.env` file)

### Domain Already Registered (Valet/Herd)

**Cause:** The domain is already proxied to another project.

**Solution:**
- Choose a different domain name, or
- Remove the existing proxy:
  ```bash
  valet unproxy domain-name  # or: herd unproxy domain-name
  ```

### Windows Users

**Requirement:** Shipyard requires bash to run.

**Solutions:**
- **Git Bash** (Recommended) - Comes with Git for Windows
  - Install Git for Windows: https://git-scm.com/download/win
  - Run shipyard from Git Bash terminal
- **WSL** (Windows Subsystem for Linux)
  - Install WSL: https://docs.microsoft.com/en-us/windows/wsl/install
  - Run shipyard from WSL terminal

**Not Supported:**
- PowerShell (requires bash)
- Command Prompt (requires bash)

## Development

### Repository Structure

```
shipyard/
├── README.md          # This file
├── CHANGELOG.md       # Version history
├── LICENSE            # MIT license
├── shipyard.sh        # Main script
└── install.sh         # Installation script
```

### Manual Testing

```bash
git clone https://github.com/wotzebra/shipyard.git
cd shipyard
chmod +x shipyard.sh
./shipyard.sh --help
```

### Creating a Release

1. Update version in `shipyard.sh`:
   ```bash
   readonly VERSION="0.2.0"
   ```

2. Update `CHANGELOG.md`:
   ```markdown
   ## [0.2.0] - 2025-XX-XX
   ### Added
   - New feature
   ```

3. Commit and tag:
   ```bash
   git add .
   git commit -m "Release v0.2.0"
   git tag -a v0.2.0 -m "Version 0.2.0"
   git push origin main
   git push origin v0.2.0
   ```

4. Create GitHub Release:
   - Go to: https://github.com/wotzebra/shipyard/releases/new
   - Select tag: `v0.2.0`
   - Upload `shipyard.sh` as release asset
   - Publish release

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Issues and pull requests are welcome!

- **Bug Reports**: https://github.com/wotzebra/shipyard/issues
- **Feature Requests**: https://github.com/wotzebra/shipyard/issues
- **Pull Requests**: https://github.com/wotzebra/shipyard/pulls

## Credits

Built by the team at [Who Owns The Zebra](https://github.com/wotzebra) for streamlined Laravel Sail project setup.
