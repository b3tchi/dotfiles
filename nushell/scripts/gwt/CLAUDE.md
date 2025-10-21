# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Git Worktree Tool (gwt) written in Nushell, designed to manage Git repositories using a worktree-based workflow where each branch exists as a separate directory alongside a central bare repository.

## Repository Structure

The tool enforces a specific repository layout:
- `default/` - Bare Git repository (the central `.git` directory)
- `main/` (or other branch names) - Working directories for each branch as Git worktrees
- Each branch exists in its own directory at the repository root level

## Key Commands

All commands are implemented as Nushell functions in `gwt/mod.nu`. Run from within the Nushell environment.

### Repository Management
- `repo init [path]` - Initialize a new bare repository with worktree structure
- `repo get <profile> <name> [--owner]` - Clone a GitHub repository into the worktree structure
- `repo push <profile> <scope>` - Create remote GitHub repository and push (incomplete implementation)

### Branch Management
- `branch create <name> <from> [--path]` - Create new branch as a worktree directory
- `branch link <name> [--path]` - Link existing remote branch as a local worktree
- `branch remove <name>` - Remove a branch worktree
- `branch version [root]` - Interactive versioning for monorepo subdirectories with semantic versioning

### User Management
- `user register <profile> [--ssh-path]` - Register SSH key for GitHub authentication and configure SSH config

## Architecture

### Profile System
- User profiles are defined in the `data` function (gwt/mod.nu:4-12)
- Currently hardcoded profile: `b3tchi` with email and GitHub domain
- Profiles determine GitHub user, email, and SSH configuration

### Git Worktree Workflow
The tool operates on the principle that:
1. The bare repository (`default/`) is the central source of truth
2. All Git operations use `--git-dir` to point to the bare repository
3. Branches are managed as separate worktrees in sibling directories
4. All commands expect to run from within a branch directory (not from the repo root)

### SSH Configuration
- Generates per-device/per-user SSH keys with naming: `YYMMDD_user_hostname_os_ed25519`
- Stores SSH config in `~/.ssh/config.d/github.com-username`
- Uses Include directive in main `~/.ssh/config` to load all configs

### Monorepo Versioning
- Assumes structure: `container_code/project/component/files`
- Tracks changes at the `project/component` level
- Creates tags in format: `project/component/version` (e.g., `myapp/api/1.2.3`)
- Only versions directories with changes between HEAD and upstream

## Important Notes

- All branch operations must be run from within a branch directory (not repo root)
- The tool validates that a `default/` bare repository exists before operations
- SSH keys are managed per GitHub user profile
- The `repo push` command is incomplete (line 111 indicates TBD items)
