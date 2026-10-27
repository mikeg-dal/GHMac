# Status (2026-10-22)

## Done
- Both apps built: GHMac Server and GHMac Client, with the shared GHEKit/GHEServerKit/GHEClientKit/GHESimKit.
- 473 unit tests pass (GHEKit 122, GHEServerKit 181, GHEClientKit 170); 7 Client and 6 Server UI tests
  (run with no other GHMac windows open).
- Demo mode for both apps (`-GHESimulator demo`).
- Hardware: one approved read-only probe of the RT-21 (fw 4.13.1, 192.168.70.13:6555): `BI2;` → `358.4;`.

## Not yet verified
- Anything on real hardware beyond that probe — see `docs/HARDWARE_TEST_PLAN.md` (needs the user present).
- `AI2;` (Client terminal-server default poll), `AP2…` goto and `AA0;`/`AB0;` jog on fw 4.13.1.
- Interoperability with other client and server software.
- Real (non-demo) mode end to end: Keychain prompts, Local Network permission, real port bind.
- Win-Test STATUS packet layout (needs a real capture), Phidget knobs, GHE Base/Remote hardware.

## Open / next
- Hardware session per the test plan.
- Notarization profile, then `scripts/release.sh`.
- SO2R second-radio instance (deferred).
