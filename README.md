# Codex Cursor Link

When the Codex desktop app uses your Mac in the background, it draws its own cursor on screen. With several chats running, it is hard to tell which one is moving that cursor.

Codex Cursor Link is a small macOS helper that fixes this. Rest your mouse on the Codex cursor and a tooltip appears with the name of the chat that is driving it. Click the tooltip to jump straight to that chat in Codex.

This is an unofficial community tool. It is not made by or affiliated with OpenAI.

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

- **Finding the cursor.** The helper checks the on-screen window list about ten times a second for the Codex computer-use cursor window. It only reads window positions, never their contents.
- **Hover.** When your mouse moves onto the arrow and stays there for a quarter of a second, the tooltip opens just below it. It stays open while you move onto it, even if the Codex cursor moves away.
- **Finding the chat.** Codex keeps a local record of each chat in `~/.codex`. The helper reads it (read-only) to find the chats that made a computer-use action in the last five minutes and lists them, newest first. If none did, it shows the most recent chat that used computer use today.
- **Opening the chat.** Clicking a row opens `codex://threads/<chat id>`, which Codex handles.

Everything stays on your Mac. The helper makes no network requests and writes no files.

To print what it currently detects:

```bash
~/Applications/Codex\ Cursor\ Link.app/Contents/MacOS/CodexCursorLink --list
```

## Limitations

- It relies on details of the Codex app that are not a public API: the name of the cursor window, the layout of the local chat database, and how computer-use calls are logged. A Codex update can break it. Please open an issue if it stops working.
- When several chats use computer use at the same time, the tooltip lists all of them, since the cursor window itself does not say which chat it belongs to.

## License

MIT
