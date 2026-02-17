# Shipyard Standalone Repository - Ready to Deploy

This directory contains all files needed to create the standalone `wotzebra/shipyard` GitHub repository.

## What's Inside

```
shipyard-tool/
├── shipyard.sh          # Main script with v0.1.0, --version, --update, --help
├── install.sh           # Universal installation script (macOS/Linux/Windows Git Bash)
├── README.md            # Comprehensive user documentation
├── CHANGELOG.md         # Version history (v0.1.0)
├── LICENSE              # MIT License
├── SETUP-GUIDE.md       # Step-by-step deployment instructions
└── _README_FIRST.md     # This file
```

## Quick Start

### 1. Test Locally

```bash
# Test the script works
./shipyard.sh --version
./shipyard.sh --help

# Validate syntax
bash -n shipyard.sh && echo "✓ Valid"
bash -n install.sh && echo "✓ Valid"
```

### 2. Deploy to GitHub

Follow the detailed instructions in **SETUP-GUIDE.md**

Quick version:

```bash
# Initialize repository
git init
git add .
git commit -m "Initial commit - v0.1.0"

# Connect to GitHub (create repo first on github.com)
git remote add origin git@github.com:wotzebra/shipyard.git
git branch -M main
git push -u origin main

# Create release v0.1.0 on GitHub
# IMPORTANT: Upload shipyard.sh as release asset!
```

### 3. Test Installation

After creating the release:

```bash
# Test install script
curl -fsSL https://raw.githubusercontent.com/wotzebra/shipyard/main/install.sh | bash

# Verify
shipyard --version  # Should output: Shipyard v0.1.0
```

## Features Added

✅ **Version Management**
- `readonly VERSION="0.1.0"` constant added
- `--version` flag shows current version

✅ **Self-Updating**
- `--update` flag downloads latest from GitHub releases
- Checks GitHub API for latest version
- Atomic replacement of script file
- Shows version change information

✅ **Help System**
- `--help` flag shows comprehensive usage guide
- Lists all features and options
- Links to documentation

✅ **Universal Installation**
- `install.sh` works on macOS, Linux, Windows (Git Bash/WSL)
- Auto-detects shell and adds to PATH
- Downloads from GitHub releases
- No sudo required (installs to ~/.local/bin)

✅ **Documentation**
- Complete README with examples
- Setup guide for deployment
- Changelog following Keep a Changelog format
- MIT License

## Next Steps

1. **Read SETUP-GUIDE.md** for detailed deployment instructions
2. **Create GitHub repository**: `wotzebra/shipyard`
3. **Push code and create v0.1.0 release**
4. **Upload shipyard.sh as release asset** (critical!)
5. **Test installation and update mechanism**
6. **Announce to team**

## Important Notes

⚠️ **Release Asset Required**
The update mechanism and install script download `shipyard.sh` from GitHub release assets.
You MUST upload `shipyard.sh` as a file attachment when creating releases.

⚠️ **Branch Name**
All URLs assume `main` as the default branch. If you use `master` or another name,
update the URLs in `install.sh` and `README.md`.

⚠️ **Testing**
Before announcing to team:
- Test the install script works
- Test `--version` flag
- Test `--help` flag
- Test `--update` mechanism (after release exists)

## File Status

All files have been:
- ✅ Created with correct content
- ✅ Validated for bash syntax
- ✅ Made executable where needed
- ✅ Tested locally

Ready to deploy! 🚀
