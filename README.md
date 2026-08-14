# flextable-cli-tools

Reproducible builds of the database backup/restore **client binaries** that the
[FlexTable](https://flextable.dev) desktop app downloads at runtime - `pg_dump`,
`pg_restore`, `psql`, `mysqldump`, `mysql`, ... - bundled per platform and per
major with their full dylib / shared-library / DLL closure so backup works
without the user installing a client.

This repo is **public for transparency**: anyone can audit exactly how the
binaries FlexTable ships are produced (which upstream source, which build steps,
which relocation). It also lets the builds run on free GitHub-hosted
macOS/Windows/Linux runners.

## What this repo does (and does not)

- **Does**: build the per-platform bundles and upload them as workflow
  **artifacts**. No secrets are configured here.
- **Does not**: sign or publish anything. The ed25519 manifest signing and the
  S3 upload happen in FlexTable's private release repo, which pulls the artifacts
  from a build run here. The signing key never touches this repo.

So a bundle downloaded straight from this repo's Actions artifacts is **unsigned**
and is not what the app trusts - the app only installs bundles listed in the
ed25519-signed manifest served from `dl.flextable.dev/cli-tools`.

## Build

Actions -> **Build CLI tools** -> Run workflow. Inputs:

| Input | Default | Meaning |
|---|---|---|
| `majors` | `16 17 18` | PostgreSQL server majors to build |
| `engines` | `postgresql` | space-separated: `postgresql` and/or `mysql` |
| `platforms` | `all` | subset of `linux-x86_64 macos-arm64 macos-x86_64 windows-x86_64` |
| `include_macos_x64` | `false` | add the scarce macos-13 Intel cell |

Each platform cell fetches the upstream client (Homebrew formula / `postgres:<n>`
& MySQL APT container / EDB & MySQL Community zip), runs the matching
`ops/cli-tools/bundle_*` script (relocates the library closure, `@loader_path` /
`$ORIGIN` rpath rewrite, ad-hoc re-sign on macOS), and uploads `dist/*.zip`.

## Layout

```
ops/cli-tools/
  bundle_macos.sh      # dylib closure -> lib/, @loader_path, ad-hoc codesign
  bundle_linux.sh      # .so closure -> lib/, patchelf --set-rpath $ORIGIN
  bundle_windows.ps1   # co-locate DLLs next to the .exe
.github/workflows/build.yml
```
