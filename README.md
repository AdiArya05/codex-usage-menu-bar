# Codex Usage

A native Mac menu bar app that shows your remaining Codex quota. Click the Codex icon for a compact panel with live usage, reset countdowns, and earned reset credits. The dashboard keeps the 5-hour and weekly Codex windows visible when reported for your account.

## Install

Requires macOS 14 or later on Apple Silicon or Intel and a local Codex installation signed in with your ChatGPT account. [Get Codex](https://chatgpt.com/codex)

1. [Download Codex Usage for macOS](https://github.com/AdiArya05/codex-usage-menu-bar/releases/latest/download/Codex-Usage-macOS.zip). See the [latest release](https://github.com/AdiArya05/codex-usage-menu-bar/releases/latest) for its version and changes.
2. Quit any existing copy of Codex Usage. Unzip the download, drag **Codex Usage.app** into **Applications**, and choose **Replace** if prompted.
3. Open **Codex Usage** from Applications, then click its icon in the menu bar.

### If macOS blocks the first launch

The current ZIP is ad hoc signed and has no Apple notarization. If you trust the download, choose **Done** on the alert, then go to **System Settings → Privacy & Security**. Scroll to **Security**, choose **Open Anyway** for Codex Usage, and confirm **Open**. If your Mac is managed and the option is unavailable, contact your administrator. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445)

You can also build the app from this repository using the instructions below.

## App updates

The GitHub download checks for updates automatically. If you have an earlier build, replace it once with version 1.0.3 or later. You can also select **… → Check for Updates…** from the popup. Install the app in a writable Applications folder so it can install updates there.

## Activity indicators

With Codex Desktop open and signed in, start a local chat to check the animation. Three dots orbit while a local chat is working, and an orb moves around the quota ring when you open the popup. macOS Reduce Motion can make the animation static. A dot to the left turns yellow for input, green for a recent completion, or red for a recent failed turn. Unanswered question cards can stay yellow for up to ten minutes after a completed turn. The quota percentage stays visible in every state. The app also polls the most recent Codex Cloud tasks through the signed-in CLI. Cloud tasks can show pending work, completion, or failure.

## Build and run

Build with the macOS 26 SDK or newer. The app runs on macOS 14 or newer and uses Liquid Glass controls on macOS 26 or newer. Install Codex and sign in to your ChatGPT account before launching.

```sh
./build.sh
open "$HOME/Applications/Codex Usage.app"
```

The app reads your usage through the locally installed Codex App Server and its existing sign-in. It uses an OpenAI-signed native CLI from ChatGPT or Codex in Applications, or from a standard Homebrew prefix.

## Publish a signed app update

For the GitHub build, set `CODEX_USAGE_SPARKLE_DIR` to a verified Sparkle release directory containing `Sparkle.framework` and `bin/generate_appcast`. Run `build.sh` with `CODEX_USAGE_UNIVERSAL=1` after increasing both bundle versions. Build without `CODEX_USAGE_SPARKLE_DIR` for local development without the updater.

Archive the app with `ditto -c -k --keepParent` as `Codex-Usage-macOS.zip`. Keep the private signing key in Keychain under Sparkle account `codex-usage-menu-bar`. Generate a signed feed in a directory that contains the release ZIP. Use the release tag in the download URL so each feed signature stays tied to its exact ZIP.

```sh
"$CODEX_USAGE_SPARKLE_DIR/bin/generate_appcast" --account codex-usage-menu-bar \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/AdiArya05/codex-usage-menu-bar/releases/download/$tag/" \
  "$release_directory"
```

Publish the ZIP to the GitHub release before committing the generated `appcast.xml` at the repository root. Keep the feed byte-for-byte as generated so its signature stays valid.

## Build a notarized release

Use a valid **Developer ID Application** identity and a stored [Apple notarytool Keychain profile](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
./release.sh "Developer ID Application: Your Name (TEAMID)" "notary-profile" /path/to/Codex-Usage-macOS.zip
```

The script builds a universal app, signs it with the hardened runtime, submits it to Apple, and verifies the stapled ticket and Gatekeeper assessment before writing the release ZIP.
