# Contributing to Waterm

Thanks for your interest in contributing to Waterm.

## Code of Conduct

By participating in this project, you agree to follow `CODE_OF_CONDUCT.md`.

## Before You Start

1. Search existing issues and pull requests to avoid duplicate work.
2. For large changes, open an issue first to align on approach and scope.
3. Keep pull requests focused and small when possible.

## Development Setup

Requirements:

- Xcode 16.0+
- Zig (for building Ghostty): `brew install zig`

Setup:

```bash
git clone https://github.com/mzz2017/waterm.git
cd waterm
./scripts/build.sh all
open Waterm.xcodeproj
```

## Pull Request Guidelines

1. Create a branch from `main`.
2. Make your changes with clear commit messages.
3. Run relevant checks/tests locally before opening a PR.
4. Include screenshots or recordings for UI changes.
5. Include clear validation notes for networking/terminal behavior changes.

## License

This fork is distributed under GPL-3.0. Contributions are not submitted under
the Waterm CLA. No additional commercial or proprietary relicensing rights are
granted.
