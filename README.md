# Organic Codex

A native macOS shell for Codex conversations. Work in progress.

This repository is a public build site: it carries only what is needed to compile and test the app. Expect unfinished work, test scaffolding and frequent changes.

## Build

Requires macOS 26 or later and Xcode 27.

```sh
zsh scripts/build.sh                  # release build: build/OrganicShell.app
CONFIG=debug zsh scripts/build.sh     # debug build
zsh scripts/selftest.sh               # self-test at 1x and 2x (opens windows)
```

Every push is built by GitHub Actions (`.github/workflows/build.yml`); the app is uploaded as a workflow artifact.

## Live Core

`Runtime/Core` is a local Python process that talks to the official ChatGPT/Codex app components already installed on the Mac and reuses the existing Codex sign-in. It needs the official browser tool catalog at `Runtime/Core/adapters/browser/official-tools.json` when it starts. That file comes from the official app and is not part of this repository.

This project is not affiliated with or endorsed by OpenAI.

## License

MIT. See `LICENSE`.
