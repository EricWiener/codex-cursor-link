# Codex Cursor Link

When the Codex desktop app uses your Mac in the background, it draws its own cursor on screen. With several chats running, it is hard to tell which one is moving that cursor.

Codex Cursor Link is a small macOS helper that fixes this. Rest your mouse on the Codex cursor and a tooltip appears with the name of the chat that is driving it. Click the tooltip to jump straight to that chat in Codex.

This is an unofficial community tool. It is not made by or affiliated with OpenAI.

Example:

<img width="668" height="190" alt="screenshot_2026-11-21_22_01_55" src="https://github.com/user-attachments/assets/e5ae409e-1733-4631-ac32-b300d06140be" />


## Requirements

- macOS 13 or later
- The Codex desktop app with computer use turned on
- The Xcode command line tools (`xcode-select --install`), used to compile the helper

## Install

```bash
git clone https://github.com/EricWiener/codex-cursor-link.git
cd codex-cursor-link
./install.sh
```

The script compiles the helper into `~/Applications/Codex Cursor Link.app` and adds a login item so it starts automatically. It needs no special permissions: no Accessibility, no Screen Recording.

To update, pull the latest code and run `./install.sh` again.

## Uninstall

```bash
./uninstall.sh
```

## How it works

- **Finding the cursor.** The helper checks the on-screen window list about ten times a second for Codex computer-use cursor windows. It only reads window positions, never their contents. Codex draws two kinds of cursor: one that floats above everything, and one that sits just above the app window it is controlling, which other windows can cover. The helper handles both and ignores a cursor that is hidden behind another window.
- **Hover.** When your mouse moves onto an arrow and stays there for a quarter of a second, the tooltip opens just below it. It stays open while you move onto it, even if the Codex cursor moves away. Moving onto a different cursor opens that cursor's tooltip instead.
- **Finding the chat.** Codex keeps a local record of each chat in `~/.codex`, including which app each computer-use action controlled. The helper reads it (read-only) and matches the cursor to the chat that is controlling the app under the cursor. When no chat matches, it lists the chats that made a computer-use action in the last five minutes, newest first, or the most recent one today.
- **Opening the chat.** Clicking a row opens `codex://threads/<chat id>`, which Codex handles.

Everything stays on your Mac. The helper makes no network requests and writes no files.

To print what it currently detects:

```bash
~/Applications/Codex\ Cursor\ Link.app/Contents/MacOS/CodexCursorLink --list
```

## Limitations

- It relies on details of the Codex app that are not a public API: the name of the cursor window, the layout of the local chat database, and how computer-use calls are logged. A Codex update can break it. Please open an issue if it stops working.
- The cursor window does not say which chat owns it, so the match is based on the app under the cursor. If two chats control the same app, or a cursor stays parked after its chat finishes, the tooltip may list more than one chat or a recent chat instead of the owner.

## Development

`--self-test` runs the cursor detection against fake window stacks:

```bash
swiftc -O main.swift -o /tmp/codex-cursor-link && /tmp/codex-cursor-link --self-test
```

## License

MIT
