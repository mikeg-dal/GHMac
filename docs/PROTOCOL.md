# Protocols (summary)

The wire formats GHMac speaks.

## 1. Client ⇄ Server (TCP 17220)
- Text lines, CP1252, CR LF. Fields separated by U+001F (␟), sub-fields by U+001D (␝).
- **Servers may read raw chunks, not lines**: the Client sends every command as one write
  `<cmd>\r\n` under 256 bytes, never in the same write as a keepalive NUL.
- Login (when "Authenticate Users" is on):
  `S: USER:` → `C: <user>\r\n` → `S: PASS:<challenge>` → `C: <32 raw bytes>` (no terminator)
  where `P = SHA-256(user ‖ low byte of each password char)` and `R = SHA-256(user ‖ challenge ‖ P)`.
  Failure: `INVALID USER/PASS`, `CLOSE`. Test vector: user `alice`, password `secret1`,
  challenge `0.7316931046151538-81283467123456789011665432101234` →
  P `5f454adf…601c`, R `1912ccc6…37c7`.
- Keepalive: client sends one 0x00 byte after 10 s, then every 5 s. Client retries every 15 s.
- Server → client: `ADD␟rotor`, `REMOVE␟rotor`, `POINT␟rotor␟heading␟status␟rssi`, `STACKADD␟a,b,c`,
  `STACKREMOVE`, `STACK␟names␟b1␟b2␟b3␟b4␟status␟rssi`, `SWITCHADD␟type␟name{␟pos␝…}`, `SWITCHREMOVE`,
  `SWITCHUPDATE␟name␟state␟status␟rssi`, `SWITCHLOCKS␟name{␟state}`, empty presets line, `CLOSE`.
- Client → server: `TURN␟rotor␟<heading|CW|CCW>`, `STOP␟rotor`, `SET_STACK␟antenna␟bool`,
  `SET_SWITCH␟switch␟position[␟bool]`, `QUIT` (plus the rarely used `TO_DEC`, `LOCK`, `UNLOCK`, `GETHEAD rotor`,
  `GET_LOCATIONS`, `RESTART`; `TO_PRESET` is ignored by the Server).
- Rotor status chars: `0` ok, `5` not responding, `7` fixed (heading > 360 shows `---`), `8` clone,
  `1`–`4`, `6`, `9` understood by the client.
- Switch display types: 1 buttons, 2 map (`pos␝heading␝beamwidth␝bidir`), 3 band (`pos␝lowMHz␝highMHz`), 4 on/off bank.

## 2. RT-21 rotor protocol
`;`-terminated ASCII.

| Purpose | Bytes | Notes |
|---|---|---|
| Poll (tenths) | `BI2;` → `ddd.d;` | **Verified 2026-10-22 on fw 4.13.1: `358.4;`** |
| Poll (integer) | `AI2;` → `ddd;` | Client terminal-server default; unverified on 4.13.1 |
| Goto (RT-21) | `AP2hhh.h\r;` | after a tenths reply has been seen; unverified |
| Goto (RT-20) | `AP2nnn;AM2;` | before the model is known |
| Goto (terminal) | `AP2nnn\r;` | client direct mode |
| Jog | `AA0;` CCW / `AB0;` CW | RT-21 only; unverified |
| Stop | `;` | |

DCU-1: `AI1;`, `AP1nnn;AM1;`, `;`. Serial: 4800 8N1, no flow control.
The Mac Server also reaches a networked RT-21 directly: a `ports.ini` entry whose value is `host:port`
(`RT21-NET=192.168.70.13\:6555`) is a TCP port.

## 3. Base / Remote switch boxes (XBee 802.15.4 API mode 1, 9600 8N1)
- Frame: `7E len_hi len_lo api … checksum`, checksum = `0xFF − Σ(bytes from api)`.
- Relays on remote *n*: Remote AT `IO` to 16-bit address `0x10nn`; RSSI via remote `DB`; Base relays: local `IO`.
- RT-21 behind a remote: TX16 frames carrying the RT-21 bytes; replies in RX16 frames (RSSI = −byte 6).
- Validate on open: `7E 00 05 08 00 44 44 00 6F`, then wait 3 s.

## 4. Logger feeds
- N1MM+ family: UDP 12060 `RadioInfo` XML (Freq/TXFreq in 10 Hz, RadioNr, FocusRadioNr), UDP 12045 rotor XML
  (`<goazi>`, `<stop>`).
- Win-Test: UDP 9871 `SETAZIMUTH:` / `STATUS:` with a trailing checksum byte.
- N3FJP: client TCP to port 1100, `<FREQ>` in MHz.
