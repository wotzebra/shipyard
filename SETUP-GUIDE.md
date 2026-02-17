# Shipyard Repository Setup Guide

This guide will help you set up the `wotzebra/shipyard` repository on GitHub.

## Files Created

All files are ready in the `shipyard-tool/` directory:

- ✅ `shipyard.sh` - Main script with version, update, and help functionality (v0.1.0)
- ✅ `install.sh` - Universal installation script for all platforms
- ✅ `README.md` - Comprehensive documentation
- ✅ `CHANGELOG.md` - Version history (v0.1.0)
- ✅ `LICENSE` - MIT License
- ✅ `SETUP-GUIDE.md` - This file

## Quick Test

Before publishing, test the scripts locally:

```bash
cd shipyard-tool

# Test version flag
./shipyard.sh --version
# Expected output: Shipyard v0.1.0

# Test help flag
./shipyard.sh --help
# Expected output: Help message

# Test syntax validation
bash -n shipyard.sh && echo "✓ Syntax valid"
bash -n install.sh && echo "✓ Syntax valid"
```

## Setup Steps

### 1. Create GitHub Repository

1. Go to: https://github.com/organizations/wotzebra/repositories/new
2. Repository name: `shipyard`
3. Description: `Laravel Sail project setup with automatic port assignment`
4. Visibility: Public (or Private if preferred)
5. DO NOT initialize with README (we have our own)
6. Click "Create repository"

### 2. Initialize Local Repository

```bash
cd shipyard-tool

# Initialize git
git init

# Add all files
git add .

# Create initial commit
git commit -m "Initial commit - v0.1.0"

# Add remote
git remote add origin git@github.com:wotzebra/shipyard.git

# Push to main branch
git branch -M main
git push -u origin main
```

### 3. Create First Release (v0.1.0)

#### Option A: Via GitHub Web Interface

1. Go to: https://github.com/wotzebra/shipyard/releases/new
2. Click "Choose a tag" → Type `v0.1.0` → Click "Create new tag: v0.1.0 on publish"
3. Release title: `v0.1.0 - Initial Release`
4. Description: Copy content from `CHANGELOG.md` (the v0.1.0 section)
5. **IMPORTANT:** Upload `shipyard.sh` as a release asset:
   - Click "Attach binaries by dropping them here or selecting them"
   - Upload the `shipyard.sh` file
6. Click "Publish release"

#### Option B: Via Command Line

```bash
cd shipyard-tool

# Create and push tag
git tag -a v0.1.0 -m "Initial release"
git push origin v0.1.0

# Use GitHub CLI to create release with asset
gh release create v0.1.0 \
  --title "v0.1.0 - Initial Release" \
  --notes-file CHANGELOG.md \
  shipyard.sh
```

### 4. Verify Installation

Test the installation script:

```bash
# Test from raw URL (after release is published)
curl -fsSL https://raw.githubusercontent.com/wotzebra/shipyard/main/install.sh | bash

# Verify installation
shipyard --version
# Expected output: Shipyard v0.1.0

# Test help
shipyard --help
```

### 5. Test Update Mechanism

After the first release is published:

```bash
# Test update (should say "already at latest")
shipyard --update
# Expected output: ✓ Already at latest version (v0.1.0)
```

## Post-Setup Tasks

### Update Project README

Add installation instructions to your main project (golazo-backend) README or docs:

```markdown
## Development Setup

This project uses Shipyard for automated port assignment and setup.

### Install Shipyard (one-time setup)

```bash
curl -fsSL https://raw.githubusercontent.com/wotzebra/shipyard/main/install.sh | bash
```

### Setup Project

```bash
cd golazo-backend
shipyard
```

For more information: https://github.com/wotzebra/shipyard
```

### Announce to Team

```markdown
🚢 Shipyard is now available!

Shipyard is our new tool for setting up Laravel Sail projects with automatic port assignment.

**Install:**
```bash
curl -fsSL https://raw.githubusercontent.com/wotzebra/shipyard/main/install.sh | bash
```

**Usage:**
```bash
cd your-project
shipyard
```

**Features:**
- ✅ Automatic port assignment (no more conflicts!)
- ✅ Domain registration with Valet/Herd
- ✅ SSL certificate setup
- ✅ Self-updating: `shipyard --update`

**Docs:** https://github.com/wotzebra/shipyard
```

## Future Updates

When you need to release a new version:

1. **Update version in `shipyard.sh`:**
   ```bash
   readonly VERSION="0.2.0"
   ```

2. **Update `CHANGELOG.md`:**
   ```markdown
   ## [0.2.0] - 2025-XX-XX
   
   ### Added
   - New feature description
   
   ### Fixed
   - Bug fix description
   ```

3. **Commit and tag:**
   ```bash
   git add .
   git commit -m "Release v0.2.0"
   git tag -a v0.2.0 -m "Version 0.2.0"
   git push origin main
   git push origin v0.2.0
   ```

4. **Create GitHub release:**
   - Upload new `shipyard.sh` as asset
   - Copy CHANGELOG content to release notes

5. **Team members update:**
   ```bash
   shipyard --update
   ```

## Troubleshooting

### Install script fails

- Check network connectivity
- Verify GitHub repository is public
- Check if release v0.1.0 exists with `shipyard.sh` asset

### Update fails

- Check if release exists: https://github.com/wotzebra/shipyard/releases
- Verify `shipyard.sh` is uploaded as release asset (not just tagged)
- Check GitHub API rate limits: `curl -I https://api.github.com/rate_limit`

### Syntax errors

- Run: `bash -n shipyard.sh`
- Check for unescaped special characters
- Verify all functions are properly closed

## Support

- **Issues:** https://github.com/wotzebra/shipyard/issues
- **Pull Requests:** https://github.com/wotzebra/shipyard/pulls
- **Discussions:** https://github.com/wotzebra/shipyard/discussions

## Checklist

Before announcing to team:

- [ ] Repository created on GitHub
- [ ] Code pushed to main branch
- [ ] Release v0.1.0 created
- [ ] `shipyard.sh` uploaded as release asset
- [ ] Installation script tested
- [ ] `--version` flag works
- [ ] `--help` flag works
- [ ] `--update` mechanism tested
- [ ] Documentation reviewed
- [ ] Team announcement prepared
