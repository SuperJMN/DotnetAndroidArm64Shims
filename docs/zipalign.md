# zipalign

`zipalign` aligns ZIP/APK entries before signing or final packaging. It is
invoked by signed APK publishes and is installed by Android SDK `sdkmanager`
under:

```
<android-sdk>/build-tools/<version>/zipalign
```

This is outside the `Microsoft.Android.Sdk.Linux` workload pack. On
Linux/aarch64, Google's upstream build-tools package still installs an x86_64
ELF, so signed APK publishing fails with `Exec format error` even after the
.NET pack shims have been applied.

## Shim strategy

The shim tarball now includes a `zipalign` executable. It is fetched from
`lzhiyong/android-sdk-tools` release `35.0.2`, which publishes static aarch64
Android SDK build-tools built from AOSP sources. The binary is an arm64-v8a
static-bionic executable for Android 30; it runs directly on Linux/aarch64
kernels, the same compatibility property used by the `aapt2` shim.

Unlike `aapt2`, `zipalign` is not version-checked by the .NET Android targets.
The command-line surface needed for signed APK publish is stable (`-f`, `-p`,
`-c`, alignment value, input, output), so one zipalign shim can serve the
current build-tools versions.

## Installation

`scripts/install-shims.sh` overlays every installed
`<android-sdk>/build-tools/*/zipalign` it can find. The Android SDK root is
resolved from:

1. `--android-sdk-root <path>`
2. `$ANDROID_SDK_ROOT`
3. `$ANDROID_HOME`
4. `$HOME/.android-sdk`

Original binaries are backed up to:

```
<android-sdk>/build-tools/<version>/.x86_64-backup/zipalign
```

The overlay is idempotent. If build-tools are not installed yet, the installer
prints a skip message and exits successfully; run it again after `sdkmanager`
installs `build-tools;<version>`.

## Verification

`shims/zipalign/verify-basic.sh` creates a tiny ZIP file, runs:

```
zipalign -f -p 4 sample.zip aligned.zip
zipalign -c -p 4 aligned.zip
```

This is also how the CI smoke test verifies the installed build-tools overlay.
