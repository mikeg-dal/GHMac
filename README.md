# GHMac

Free, native macOS apps for running Green Heron antenna rotor controllers and switch boxes from a Mac.

> [!IMPORTANT]
> **Not affiliated with Green Heron Engineering.**
> GHMac is an independent, personal project. I wrote it to use my own Green Heron hardware, which has no
> macOS software. It is not made, endorsed or supported by Green Heron Engineering.
>
> - **Please don't contact Green Heron Engineering about GHMac.** They have nothing to do with it.
> - **No one supports this software.** Issues and pull requests may or may not get a response.
> - **Use it at your own risk.** It's provided "as is", without warranty of any kind (see [LICENSE](LICENSE)).
>   It sends commands that move antennas and switch RF paths. You're responsible for any damage to equipment,
>   property or anything else.
>
> Green Heron, RT-21, DCU-1 and other product names are trademarks of their owners and are used here
> only to describe compatibility.

## What it is
Two apps:

- **GHMac Server** drives RT-21 / DCU-1 rotor controllers (USB serial or the RT-21's network module),
  Base/Remote switch boxes, stack matches, fixed and cloned antennas, and serves clients on TCP 17220.
- **GHMac Client** has the rotor tray, rotor map, switch panels, presets, hotkeys and Phidget knobs, and follows
  band changes from N1MM+ / DXLog / Commander / FRStack / PSTRotator, Win-Test and N3FJP. It can also connect
  straight to an RT-21 network module ("Terminal Server (TCP)").
- Swift 6, SwiftUI + AppKit, Apple silicon, macOS 27, no third-party dependencies.

Install both on a Mac and set everything up from scratch: there is nothing to import.

## Build
```sh
xcodegen generate
open GHMac.xcodeproj
xcodebuild -scheme GHEServer -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme GHEClient -destination 'platform=macOS,arch=arm64' build
```

## Try it without hardware
```sh
open "GHMac Server.app" --args -GHESimulator demo
open "GHMac Client.app" --args -GHESimulator demo
```
The demo uses simulated rotors and switch boxes and temporary settings; nothing touches the network.

## Test
```sh
xcodebuild -scheme Kits -destination 'platform=macOS,arch=arm64' test            # unit tests
xcodebuild -scheme GHEClient -destination 'platform=macOS,arch=arm64' test -only-testing:GHEClientUITests
xcodebuild -scheme GHEServer -destination 'platform=macOS,arch=arm64' test -only-testing:GHEServerUITests
```
Run UI tests with no other GHMac windows open. Real hardware: [docs/HARDWARE_TEST_PLAN.md](docs/HARDWARE_TEST_PLAN.md).

## Data
- Server: `~/Library/Containers/com.mikegarcia.GHMacServer/Data/Library/Application Support/GHMac Server/`
- Client: `~/Library/Containers/com.mikegarcia.GHMacClient/Data/Library/Application Support/GHMac Client/`
- Settings are plain files in those folders (`settings.ini`, `DeviceManager.xml`, `ports.ini`, `wioProfiles/`, …).
- Server passwords are kept in the macOS Keychain.
- An RT-21 network module is added to the Server with a `ports.ini` line such as `RT21-NET=192.168.1.50\:6555`.

**RT-21 network modules accept only one TCP connection.** Don't point the Server and a Client (or RT-21 Setup)
at the same module at the same time.

## Release
`scripts/release.sh` archives, signs, notarizes and staples both apps (needs your own Developer ID; one-time:
`xcrun notarytool store-credentials GHENotary --apple-id <id> --team-id <team>`).

## Docs
[docs/PROTOCOL.md](docs/PROTOCOL.md) (wire formats), [docs/HARDWARE_TEST_PLAN.md](docs/HARDWARE_TEST_PLAN.md),
[docs/STATUS.md](docs/STATUS.md).

## License
[MIT](LICENSE) © 2026 Mike Garcia.
