# Hardware test plan

The only hardware available is an **RT-21 (firmware 4.13.1) at 192.168.70.13:6555** reached through its
Ethernet/WiFi module. Everything else (serial RT-21/DCU-1, GHE Base/Remote switch boxes, stack matches, Base PTT,
Phidget knobs, the Sticky port) is covered only by the simulators and unit tests (section 7).

## 0. Safety rules (read first)
- The network module accepts **one TCP connection**. A second connection attempt can drop the first and lock
  port 6555 until the controller is power-cycled.
- Before each step, quit everything else that might connect: RT-21 Setup, any other rotor software,
  and the other GHMac app. **Only one of GHMac Server and GHMac Client talks to the
  RT-21 at a time.**
- Steps marked **MOTION** move the antenna: only with someone watching the rotor.
- If the link locks up: power-cycle the controller, wait for it to come back, then continue.

## 1. Server, read-only
1. In the Server's data folder (`~/Library/Containers/com.mikegarcia.GHMacServer/Data/Library/Application Support/GHMac Server/`),
   add to `ports.ini`: `RT21-NET=192.168.70.13\:6555`.
2. Device Manager: row "Tower", Port `RT21-NET`, Type `RT-21`, Connect.
3. Expect: status Connected within ~3 s; log "ROTOR CONNECTED: Tower"; heading updates every second (`BI2;` → `ddd.d;`).
   Verified 2026-10-22: `BI2;` answers `358.4;`.
4. Pull the network cable (or power off the controller): after ~6 s the row reports error status 5; reconnect
   attempts back off from 5 s to 60 s and never overlap. Reconnect: the row recovers on its own.
5. Disconnect the row. Confirm with `lsof -i :6555` (Mac side) that no socket is left open.

## 2. Client "Terminal Server (TCP)" mode, read-only
1. Quit the Server. In the Client: Configuration ▸ Servers…, row: `192.168.70.13`, port `6555`,
   type "Terminal Server (TCP)", Rotor Name "Tower", Connect.
2. Default poll is `AI2;`. Unverified on 4.13.1: check the heading shows.
   If it doesn't, switch the row's poll to `BI2;` (verified) and retry.

## 3. Motion (gated, with the user watching)
| Step | Path | Bytes | Expect |
|---|---|---|---|
| 3.1 | Server row → Client Turn to 090 | `AP2090.0\r;` | rotor turns to 90°, heading tracks |
| 3.2 | Stop while turning | `;` | rotor stops |
| 3.3 | Jog CW / CCW (Medium/Large row) | `AB0;` / `AA0;` | rotor jogs; stop with `;` |
| 3.4 | Client terminal mode Turn to 180 | `AP2180\r;` | rotor turns |

## 4. Mac Client ⇄ Mac Server with the real rotor
1. Server as in section 1 (auth off). Client: GH Server row `127.0.0.1` port 17220, Connect.
2. Tray shows "Tower" with live heading; Turn/Stop work (MOTION); Rotor Map wedge follows.
3. Server: Users ▸ create master password, add user `test1`/`secret1`; Authenticate Users on (Stop → toggle → Start).
   Client row with that user: connects; wrong password shows "Invalid user/pass" and does not retry.
4. Server ▸ Launch Local Controller opens the Client pointed at this server.

## 5. Interop with other client/server software (optional)
- Other client → GHMac Server (auth on/off); GHMac Client → other server. Every message type in
  docs/PROTOCOL.md.

## 6. macOS prompts
- First run: "Local Network" permission for both apps (allow).
- Hotkeys: Carbon hot keys need no permission; the optional event-tap mode asks for Accessibility.

## 7. Simulator-only (no hardware here)
Serial RT-21/DCU-1 (`/dev/cu.*`), GHE Base/Remote XBee bus and relays,
stack matches (6 encodings), virtual switches, matrix lockout, Phidget knobs (Phidget22), Sticky port (CTS/DSR),
N1MM/Win-Test/N3FJP feeds (use Configuration ▸ Software Control ▸ Test communication… with the real logger).
