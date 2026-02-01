# MyTerminal

A terminal emulator for jailbroken iOS devices (iOS 13+).

## Features

- Full terminal emulation with PTY support
- ANSI color support (256 colors, RGB)
- Custom font support (MesloLGS NF for Powerline)
- Command history (up/down arrows)
- Special key toolbar (Ctrl+C, Ctrl+D, Ctrl+U, etc.)
- Symbol keyboard row for easy access to special characters
- Screenshot button (requires Activator)
- SSH support with quick connect button
- Runs as root by default on jailbroken devices
- Portrait and landscape orientation support

## Requirements

- Jailbroken iOS device (iOS 13.0+)
- SSH access to the device
- `ldid` installed for code signing

## Installation

### Via SSH

1. Clone this repository
2. Build the app:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer clang -arch arm64 \
-isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
-framework UIKit -framework Foundation -framework CoreGraphics -framework CoreText \
-miphoneos-version-min=13.0 -fobjc-arc -lutil \
-o MyTerminal.app/MyTerminal main.m
```

3. Copy to device:
```bash
scp -r MyTerminal.app root@<device-ip>:/Applications/
```

4. Sign and set permissions on device:
```bash
ssh root@<device-ip>
cd /Applications/MyTerminal.app
chown root:wheel MyTerminal
chmod 4755 MyTerminal
ldid -S MyTerminal
```

5. Respring or run `uicache` to refresh the app list

## Usage

- Type commands in the input field at the bottom
- Use toolbar buttons for special keys
- Swipe the symbol row for more special characters
- Use ↑/↓ to navigate command history

## Custom Fonts

The app supports MesloLGS NF font for Powerline prompt themes. Place font files in `MyTerminal.app/Fonts/`:
- `MesloLGS NF Regular.ttf`
- `MesloLGS NF Bold.ttf`

## License

MIT License
