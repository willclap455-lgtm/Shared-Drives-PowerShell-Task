# AGENTS.md

## Cursor Cloud specific instructions

This is a PowerShell project for managing mapped network drives. The repository name is `Shared-Drives-PowerShell-Task`.

### Environment

- **Runtime**: PowerShell 7+ (`pwsh`) — must be installed via Microsoft's APT repository for Ubuntu 24.04 (noble).
- **No package manager or dependency manifest** exists in this repo; scripts are standalone `.ps1` files.

### Running PowerShell scripts

```bash
pwsh -File <script.ps1>
```

### Notes

- The VM environment does not ship with PowerShell pre-installed. The update script handles installation.
- There are currently no tests, linting tools, or build steps configured in this repository.
