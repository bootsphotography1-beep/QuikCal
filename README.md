# QuikCal source

QuikCal is a native macOS menu-bar calendar capture app. It turns typed or spoken notes into editable event drafts. Nothing is written to a calendar until the user explicitly confirms **Add**.

## Generation and speech

- Event extraction uses Apple Foundation Models when the operating system and device support it and Apple Intelligence is ready. This requires macOS 26 or later. Otherwise, QuikCal uses its deterministic built-in parser.
- Speech recognition uses the Parakeet speech model through the bundled-source `transcribe.cpp` helper. The app offers an explicit speech-model download or selection; model weights are not included here or in the app build.
- QuikCal does not expose a downloadable local text-model route. The upstream speech-engine source is generic and supports additional ASR architectures, but QuikCal configures its speech workflow for Parakeet.

## Requirements

- macOS 14 or later; Apple Foundation Models require macOS 26 or later and a compatible, ready Apple Intelligence configuration.
- Swift 6 toolchain and Xcode Command Line Tools.
- CMake and a C/C++ toolchain to build the speech helper.
- The first SwiftPM build may need network access to resolve the pinned Sparkle 2.10.1 dependency. No dependency was downloaded as part of preparing this source snapshot.

## Build and test

```sh
swift test
./scripts/build_speech_helper.sh
./scripts/build_app.sh
./scripts/build_dmg.sh
```

The default test target omits four historical model-evaluation suites whose unpublished research inputs are intentionally not part of this source publication. The packaged speech acceptance test is explicitly gated and requires a built app plus a user-provided Parakeet model.

`build_app.sh` needs the Sparkle package artifact and, by default, exactly one existing Apple Development signing identity. `QUIKCAL_SIGN_MODE=adhoc` is a local-development-only override. `build_dmg.sh` rejects ad-hoc output unless a separate local-development override is set; neither mode makes a build notarized or Developer ID-signed.

Build scripts create or replace generated outputs in `build/` and `dist/`. `build_app.sh` replaces `build/QuikCal.app`; `build_dmg.sh` replaces its staging directory and same-version DMG under `dist/`, and uses a temporary diagnostic file under `/tmp` while checking the DMG. Review those targets before running the scripts.

## Configuration and licensing

The public Google Desktop OAuth client ID and Sparkle public update configuration are in `Resources/Info.plist`; no client secret is embedded. Google credentials, when configured by a user, must remain local.

There is no project-level `LICENSE` in this snapshot. Third-party notices and license texts are retained under `Resources/Notices/`; Sparkle remains a separately resolved SwiftPM dependency with its own license terms. No project license has been invented.
