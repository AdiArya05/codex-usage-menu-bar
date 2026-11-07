# Codex Usage

A native Mac menu bar app that shows your remaining Codex quota. Click the Codex icon for a compact panel with live usage, reset countdowns, and earned reset credits.

Three dots orbit while any local Codex Desktop chat is working. A dot to the left turns yellow for input, green for a recent completion, or red for a recent failed turn. Unanswered question cards can stay yellow for up to ten minutes after a completed turn. The quota percentage stays visible in every state. The app also polls the most recent Codex Cloud tasks through the signed-in CLI. Cloud tasks can show pending work, completion, or failure.

## Build and run

Build with the macOS 26 SDK or newer. The app runs on macOS 14 or newer and uses Liquid Glass controls on macOS 26 or newer. Install Codex and sign in to your ChatGPT account before launching.

```sh
./build.sh
open "$HOME/Applications/Codex Usage.app"
```

The app reads your usage through the locally installed Codex App Server and its existing sign-in.
