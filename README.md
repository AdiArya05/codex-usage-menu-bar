# Codex Usage

A native Mac menu bar app that shows your remaining Codex quota. Click the Codex icon for a compact panel with live usage, reset countdowns, and earned reset credits.

## Install

Requires macOS 14 or later on Apple Silicon or Intel and a local Codex installation signed in with your ChatGPT account. [Get Codex](https://chatgpt.com/codex)

1. [Download Codex Usage for macOS](https://github.com/AdiArya05/codex-usage-menu-bar/releases/latest/download/Codex-Usage-macOS.zip). See the [latest release](https://github.com/AdiArya05/codex-usage-menu-bar/releases/latest) for its version and changes.
2. Quit any existing copy of Codex Usage. Unzip the download, drag **Codex Usage.app** into **Applications**, and choose **Replace** if prompted.
3. Open **Codex Usage** from Applications, then click its icon in the menu bar.

### If macOS blocks the first launch

The current ZIP is ad hoc signed and has no Apple notarization. If you trust the download, choose **Done** on the alert, then go to **System Settings → Privacy & Security**. Scroll to **Security**, choose **Open Anyway** for Codex Usage, and confirm **Open**. If your Mac is managed and the option is unavailable, contact your administrator. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445)

You can also build the app from this repository using the instructions below.

## Activity indicators

With Codex Desktop open and signed in, start a local chat to check the animation. Three dots orbit while a local chat is working, and an orb moves around the quota ring when you open the popup. macOS Reduce Motion can make the animation static. A dot to the left turns yellow for input, green for a recent completion, or red for a recent failed turn. Unanswered question cards can stay yellow for up to ten minutes after a completed turn. The quota percentage stays visible in every state. The app also polls the most recent Codex Cloud tasks through the signed-in CLI. Cloud tasks can show pending work, completion, or failure.

## Build and run

Build with the macOS 26 SDK or newer. The app runs on macOS 14 or newer and uses Liquid Glass controls on macOS 26 or newer. Install Codex and sign in to your ChatGPT account before launching.

```sh
./build.sh
open "$HOME/Applications/Codex Usage.app"
```

The app reads your usage through the locally installed Codex App Server and its existing sign-in.

## Build a notarized release

Use a valid **Developer ID Application** identity and a stored [Apple notarytool Keychain profile](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
./release.sh "Developer ID Application: Your Name (TEAMID)" "notary-profile" /path/to/Codex-Usage-macOS.zip
```

The script builds a universal app, signs it with the hardened runtime, submits it to Apple, and verifies the stapled ticket and Gatekeeper assessment before writing the release ZIP.
