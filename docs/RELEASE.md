# Releasing Stunda

Releases are tag-driven. Pushing a tag matching `v*` (e.g. `v2.0.0`) to the
repository triggers `.github/workflows/release.yml`, which builds every platform
in parallel and attaches all artifacts to a GitHub Release for that tag.

## Cutting a release

```bash
# from an up-to-date main with green CI
git tag v2.0.0
git push origin v2.0.0
```

The release job (`softprops/action-gh-release@v2`) reads the tag, generates
release notes, and uploads everything the matrix produced. It runs with
`permissions: contents: write`.

## Obfuscation & debug symbols

**Every** `flutter build` runs with:

```
--release --obfuscate --split-debug-info=build/symbols/<platform>
```

Obfuscation strips Dart symbol names from the shipped binary, so release crash
stack traces are unreadable **without** the matching symbols. The
`build/symbols/<platform>` directory is uploaded as a per-platform artifact
(`<platform>-symbols`). **Keep these somewhere durable per release** — you need
the exact symbols from a given build to de-obfuscate traces from that build:

```bash
flutter symbolize -i <stack_trace.txt> -d build/symbols/<platform>/app.<arch>.symbols
```

## Artifacts per platform

| Platform | Job          | Artifacts                                                        |
| -------- | ------------ | ---------------------------------------------------------------- |
| Android  | `android`    | `*.apk`, `*.aab`, Linux CLI/MCP binaries, `android-symbols`      |
| iOS      | `ios`        | unsigned `*.ipa`, `ios-symbols`                                  |
| macOS    | `macos`      | `Stunda-macos.dmg`, macOS CLI/MCP binaries, `macos-symbols` |
| Windows  | `windows`    | `*.exe` installer (Inno Setup), `*.msi` (WiX), raw Release `.zip`, `windows-symbols` |
| Linux    | `linux`      | `*.AppImage`, `*.deb`, `*.rpm`, Linux CLI/MCP binaries, `linux-symbols` |
| Linux    | `linux-snap` | `*.snap`                                                         |
| Linux    | `linux-flatpak` | `stunda.flatpak`                                         |

The two Dart binaries (`stunda`, `stunda_mcp`) are compiled per-OS
with `dart compile exe` and shipped alongside the GUI.

## What is UNSIGNED and needs secrets

All artifacts this workflow produces are **unsigned**. Real distribution needs
credentials supplied as repository secrets. Steps that can consume them are
guarded with `if: ${{ secrets.X != '' }}` where it makes sense; the rest are
documented in comments in `release.yml`.

| Target | Needs | Suggested secrets |
| ------ | ----- | ----------------- |
| Android (Play) | Upload keystore + signing config | `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD` |
| iOS (App Store / device) | Apple cert + provisioning profile | `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID` |
| macOS (notarized) | Developer ID cert + notarization | `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PWD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` |
| Windows (signed installer) | Code-signing cert | `WINDOWS_CERT_BASE64`, `WINDOWS_CERT_PASSWORD` |
| Snap Store | Store login token | `SNAPCRAFT_STORE_CREDENTIALS` (publish via `snapcore/action-publish@v1`) |
| Flathub | PR-based submission to `flathub/ai.kodsama.Stunda` (not done from this repo) | — |

Without signing:

- **macOS** `.dmg`/`.app` is blocked by Gatekeeper on other machines.
- **iOS** `.ipa` cannot be installed on devices or uploaded to App Store Connect.
- **Windows** installers trigger SmartScreen warnings.
- **Android** APK/AAB are debug-key signed (fine for sideloading, not Play).

## Packaging files

| File | Purpose |
| ---- | ------- |
| `distribute_options.yaml` | flutter_distributor release config (linux appimage/deb/rpm; optional windows/macos) |
| `app/packaging/linux/{appimage,deb,rpm}/make_config.yaml` | per-target name, icon, categories |
| `packaging/linux/ai.kodsama.Stunda.desktop` | Linux `.desktop` entry |
| `packaging/linux/icon_256.png` | 256px icon (derived from `app/assets/icon_1024.png`) |
| `packaging/flatpak/ai.kodsama.Stunda.yml` | flatpak manifest (freedesktop 23.08 runtime) |
| `packaging/flatpak/ai.kodsama.Stunda.metainfo.xml` | AppStream metadata |
| `packaging/windows/product.wxs` | WiX v3 manifest for the `.msi` |
| `snap/snapcraft.yaml` | snap build (core22, gnome extension, strict confinement) |

### Manual setup notes / known nuances

- **WiX `product.wxs`**: replace the placeholder `UpgradeCode` GUID with a
  stable project-owned GUID before the first real release (keep it constant
  across versions). For a *complete* install, harvest the rest of the Release
  folder with `heat.exe` (see the comment in `product.wxs`); the bundled minimal
  component yields a valid `.msi` on its own.
- **Flatpak**: the manifest packages the pre-built `flutter build linux` bundle
  (flatpak builds offline and cannot run the Flutter toolchain), so the Linux
  build must run before the flatpak step.
- **Windows installer / msi** steps use `continue-on-error: true` so a tooling
  hiccup on the hosted runner doesn't sink the whole release; verify the
  artifacts attached to the release after each run.
- **Snap**: `confinement: strict` with `home`/`removable-media` plugs. If users
  report file-access problems with photos outside their home dir, consider
  `classic` confinement (requires Snap Store review).
