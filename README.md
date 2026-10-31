# PxExtNoJB

Clean-room clone of the `PxExtFFi` menu, rebuilt as a **no-jailbreak dylib** and
wired to a real UE4 runtime reader so enemy ESP draws live actors instead of
placeholders.

No jailbreak, no Substrate, no injection framework. One dylib, injected into the
app bundle, re-signed, sideloaded.

## What the shipped binary says

Static pass over the 416 MB `DeltaForceClient` (thin arm64 Mach-O, `__text` 281 MB,
`__cstring` 21 MB, `__ustring` 17 MB — the engine is linked into the main binary,
not a framework):

| Fact | Value |
|---|---|
| engine | UE4, `CoreUObject` present, 187,517 wide-string literals in `__ustring` |
| symbol table | stripped (`LC_SYMTAB` header only, 0 symbols) |
| game content | 9 `.pak` files, 657 MB — class/function names that live in assets are **not** in the binary |
| `GObjects` / `GNames` | **zero** — `__DATA.__bss` is 10 MB of zeros on disk; both are `malloc`'d at runtime |

Class names that **are** in the binary, and therefore usable as static anchors:

```
AGPCharacterBase                    AGPPlayerCameraManager
ACharacterBase                      ADFMPlayerCameraManager
ABattleFieldCharacter               AGPNetworkPlayerController
ADFMAICharacter_* (dozens)          ADFMPlayerController
ABattleFieldPlayerState             APlayerState_Arena
```

Not in the binary, must be resolved from the live name pool: `SetSkin`,
`K2_GetActorLocation`, `ModularWeapon*` — those are asset-side `FName`s.

That split decides the design: a hardcoded offset is wrong twice over, because
the struct offsets differ per build **and** the interesting names are not in the
file at all. `PxUE4` therefore calibrates at runtime instead — see
`## What actually runs`.


## Layout

```
PxExtNoJB/
├── Makefile
├── PxMenu.m                     entry: constructor, install, foreground hook
└── Menu/
    ├── PxStore.h/.m             menu tree, persistence, feature registry
    ├── PxMenuView.h/.m          the menu UI (header, master, search, 2 columns, tabs)
    ├── PxOverlay.h/.m           ESP overlay window (display-link, drawRect)
    ├── PxUE4.h/.mm              UE4 runtime reader: discovery, ProcessEvent, W2S
    └── PxFloatingButton.h/.m    draggable pill button window
```

## Build

```bash
export THEOS=~/theos
make                # -> .theos/obj/PxMenu.dylib
```

Needs Theos + iOS SDK. `arm64` only — the host app ships an arm64 slice and
mixing in an `arm64e` slice with ptrauth would only complicate the re-sign.
`make clean && make` after editing the menu tree in `PxStore.m`.

## Inject (no jailbreak)

The app binary has `0x7C8` bytes of slack between the end of its load commands
and `__TEXT,__text`, and `@executable_path/Frameworks` is already an `LC_RPATH`.
So no `insert_dylib` and no Mac are required — `tools/inject_ipa.py` appends the
`LC_LOAD_DYLIB` entries into that slack, copies the dylibs into `Frameworks/`,
drops `_CodeSignature`, and repacks the IPA:

```bash
python tools/inject_ipa.py --app Payload/DeltaForceClient.app \
    --dylib PxMenu.dylib --dylib AnoMute.dylib \
    --out DeltaForce_PxMenu.ipa
```

`--verify-only` patches a copy and prints the resulting command count without
writing anything. The tool refuses if the header has no room left.

On a Mac the equivalent is the usual path:

```bash
APP=DeltaForceClient.app
cp .theos/obj/PxMenu.dylib "$APP/Frameworks/PxMenu.dylib"

insert_dylib --strip-codesig --in-place \
  @executable_path/Frameworks/PxMenu.dylib "$APP/DeltaForceClient"

ldid -S"$APP/DeltaForceClient"
codesign -f -s - "$APP/Frameworks/PxMenu.dylib"
```

Either way, the installer re-signs the bundle. The app's own entitlements must be
preserved — sign with the same provisioning profile.

Verify the load command landed:

```bash
otool -L DeltaForceClient | grep PxMenu
```

## Using it

- Floating **PX** pill: drag to move (position persists), tap to toggle the menu.
- Header: status dot, FPS/frame-time, close.
- **Master** gates the overlay globally.
- Tabs: Gun / Hero / Melee / Visuals / Skin / UE4 / Misc.
- Each column has its own search field; filters rows live.
- Sliders and switches persist to `NSUserDefaults` under `px_*`.
- Sliders start at their midpoint (FOV 90, Max Distance 525 m, Opacity 55 %), so
  the overlay and the UI agree on first open.

## ESP

`Visuals → Players` enables the overlay. Every frame it asks `PxUE4` for the
current enemy list and draws boxes/labels from real actor positions:

| Control | Key | Effect |
|---|---|---|
| Enable players | `esp_players` | master for the ESP layer |
| Box | `esp_box` | box draw on/off |
| Box style | `vis_box_style` | Corner / Full / 3D |
| Skeleton | `esp_skeleton` | bone-line sketch |
| Health bar | `esp_health` | side bar, green → amber → red |
| Distance | `esp_distance` | `NNN M` label |
| Max distance | `esp_max_dist` | metres, 50–1000 |
| Opacity | `vis_opacity` | 10–100 % |
| Team check | `esp_team_check` | calls `BP_IsCharacterTeammate` |
| Camera FOV | `esp_fov` | 40–140°, horizontal |

The player camera is the only FOV the game exposes no UFunction for, so the
horizontal FOV is a slider here (default 90). If boxes drift sideways at the
screen edges, that number is the knob.

## UE4 tab

| Button | Does |
|---|---|
| **Rescan** | drops every cached pointer, runs discovery again |
| **Dump to Documents** | writes `Documents/PxUE4.log` and shows a status toast |

Nothing is hardcoded to an address. Every pointer is discovered in the running
process, so a game update that shifts segments does not need a new build.

The host is a **modified** UE4, and its object header does not match stock
4.23–4.27. The shipped `PxExtFFi` cheat reads `UObject::Class` at `+0x08` and the
`FName` at `+0x1C`; upstream UE4 uses `+0x10` and `+0x18`. Neither value is
compiled in here. `pxCalibrate()` scores both against the live object array and
keeps whichever actually resolves:

| Candidate | Values tried |
|---|---|
| `UObject::Class` | `0x08`, `0x10` |
| `UObject::Name` (FName) | `0x18`, `0x1C` |
| `Outer` | derived, always `Name + 8` |
| name-pool entry stride | `1`, `2` (entry = block + `index & mask` × stride) |
| name-pool block shift | `16`, `17` |
| object-array chunk shift | `16`, `17` |

32 tuples × 192 sampled objects. A tuple scores a point when the object's own
name resolves to a valid identifier and another when its class name does, and
three more when the class-of-class is a real metaclass (`Class`, `Function`,
`ScriptStruct`, …). That third hop is the discriminator: `FName::Number` also
resolves to a short valid entry, so name-only scoring would accept the wrong
offset. The winner needs ≥50 % of the sample (`score >= 96`) or discovery stops
with `layout calibration failed`.

Discovery, step by step:

1. **Host image** — `_dyld_image_count` / `_dyld_get_image_name`, leaf name
   `DeltaForceClient`, then walk `LC_SEGMENT_64` for `__DATA*` and `__TEXT`…
2. **GNames** — scan host `__DATA*` for a pointer whose target begins
   `08 00 4E 6F 6E 65 00` (`len=4, ASCII, "None"`). That slot is
   `FNameEntryAllocator::Blocks[0]`; slot 0 of a UE4 name pool is always `None`.
   `Blocks[]` holds `0x2000` pointers, `CurrentByteCursor` sits at `+0x100C8` and
   `CurrentBlock` at `+0x100CC` — that is the pool the shipped cheat resolves
   through, and it is what the stride/shift calibration assumes.
3. **GObjects** — scan for the chunk-pointer slot of `TUObjectArray` and accept
   it when the counts are sane (`1000 ≤ Num ≤ Max`), the first chunk is mapped,
   and at least 3 of the first 8 items are heap pointers whose vtable also lands
   inside the image. Two count layouts are tried: counts *after* the chunk list
   (stock) and *before* it (the cheat's `+0x20` / `+0x14` / `+0x18`).
4. **Layout calibration** — the table above. Logged, and `ready` stays `NO`
   until it passes.
5. **ProcessEvent** — sample class vtables, take the slot that holds the *same*
   function pointer in ≥85 % of them, and require that function body to contain
   `ldr w?, [x1, #0xB8]` (reads `UFunction::FunctionFlags`). That is
   `UObject::ProcessEvent`; its index is the slot number.
6. **Classes / UFunctions** — walk the object array by name:
   `GPCharacterBase`, `PlayerCameraManager`, `Actor`, then their
   `BP_IsCharacterTeammate`, `GetHealth`, `GetHealthMax`,
   `GetCameraLocation`, `GetCameraRotation`, `K2_GetActorLocation`. The skin path
   resolves `ModularWeaponDesc` / `GPModularWeaponDesc` and its `SetSkin` setter
   on first use.

UFunction calls go through `ProcessEvent` with `FUNC_Native (0x400)` set on the
function, restored straight after. Memory is only ever read; the single write is
that flag word, which is a normal mutable field of `UFunction`.

### Reading `PxUE4.log`

Pull it with Xcode → Devices → container, or the Files app if file sharing is on.
What a healthy log looks like:

```
== discovered ==
GNames blocks  0x...        <- non-zero
GObjects slot  0x... count 0x...   <- count in the tens of thousands
layout         class=+0x10 name=+0x18 outer=+0x20   <- winner of the calibration
               stride=1 shift=16 chunk=16 score=192 OK
ProcessEvent   slot 0x43    <- 0x40..0x50 for UE4.23-4.27
ActorLocation  0x...        <- non-zero
CameraLoc/Rot  0x... / 0x...<- non-zero
```

`score` is out of a 192-object sample; `192 OK` means every sampled object
resolved. `FAILED` or `layout calibration failed` in the toast means no tuple fit
— the header moved and the candidate table needs a new entry, not a new build.

If `ProcessEvent slot` is `0x0`, discovery failed on the vtable heuristic — the
overlay stays off rather than calling a bad pointer. `GNames not found` /
`GObjects not found` in the toast means the name-pool or array heuristic missed;
that is a layout change, not a crash.

## Skin

`Skin → Gun Skin ID` takes the numeric skin / appearance id and calls the
weapon's reflected setter. Nothing is patched and no id is hardcoded.

| Control | Key | Effect |
|---|---|---|
| Auto Re-apply | `skin_enable` | keeps the overlay link alive and re-sends the id every 2 s |
| Gun Skin ID | `skin_gun_id` | numeric id, persisted |
| Apply Skin | — | one call on the held weapon's descriptor |
| Restore Default (0) | — | applies id `0` |
| Runtime Status | — | shows the discovery line |

What it does at call time:

1. Resolve `UClass ModularWeaponDesc`, falling back to `GPModularWeaponDesc`.
2. Resolve `UFunction SetSkin`, falling back to `SetSkinInfo`, then
   `SetSkinApperanceId` (game symbols carry `_BS` / `_ES` suffixes; the runtime
   names do not). Cached after the first success.
3. Walk every descriptor of that class and score it by how its `Outer` chain
   reaches the world: `+100` when the chain hits the local pawn (the character
   within 150 uu of the camera), `+10` when it hits any known character,
   otherwise `+1` per hop. Highest score wins.
4. `ProcessEvent(desc, SetSkin, { int32 skinId })` — a 4-byte parameter block.

Returns `1` on success, `0` when no descriptor resolved (weapon not spawned —
hold the gun in a match), `-1` runtime not ready, `-2` class missing, `-3` setter
missing. Each maps to a distinct toast, so a failure says which hop broke.

Auto re-apply exists because the descriptor is rebuilt when you swap weapons or
respawn. It rides the overlay display link, which now runs while **either**
`esp_players` **or** `skin_enable` is on. With both off, nothing ticks.

## What actually runs

| Piece | Works now | Needs game work |
|---|---|---|
| Floating PX button (drag, position saved) | yes | — |
| Menu open/close, tabs, two-column scroll | yes | — |
| Search filters both columns live | yes | — |
| Switch / slider / combo / text / button controls | yes | — |
| Persistence across relaunch | yes | — |
| Master switch gating the overlay | yes | — |
| FPS + frame time pill | yes | — |
| UE4 discovery + calibration + UFunction calls | yes, runtime | — |
| **Enemy ESP (box / skeleton / health / distance)** | **yes, live actors** | tune `esp_fov` per device |
| **Mod skin (`ModularWeaponDesc::SetSkin` via reflection)** | **yes, live descriptors** | needs a valid skin id |
| Aimbot / no recoil / god mode / speed | toggle saves, no effect | per-feature offsets + hooks |

## Antiban (anogs / Tencent ACE)

`anogs` is the shipped ACE build. Strings and imports it carries, and what the
menu does about each:

| anogs signal | Meaning | What this build does |
|---|---|---|
| `inline_hook_opcode_dismatch`, `ms_hook_opcode`, `ms_set_inlie_hook`, `set_inline_hook_error` | snapshots code bytes, reports patches | **no inline hooks, no code patches anywhere** |
| `_dyld_get_image_name`, `_dyld_image_count` | enumerates loaded images | dylib name is `PxMenu` inside `Frameworks/` — looks like a normal embedded framework, not Substrate/Cydia |
| `_dlopen` | watches runtime loads | nothing is `dlopen`ed at runtime; the dylib is in the load commands |
| `mach_vm_region_recurse`, `vm_protect` | walks regions, looks for RWX | no `mprotect`/`vm_protect`, no RWX pages, no `vm_allocate` |
| `sysctl`, `sysctlbyname`, `ptrace` | debugger / `P_TRACED` checks | nothing attaches or traces |
| `BopMemoryOperation.cpp`, `mrpcs_scan_thread_start_failed!`, `ms_scan_start` | memory-op and scan-thread monitoring | only reads own-process memory via plain loads |
| `root_alert`, `debugger`, `cheat_open_id` | jailbreak / debugger / cheat ids | no jailbreak artifacts touched |

Two behaviours matter more than the table:

- **Discovery is lazy and capped.** Six attempts, one per 1.5 s, only while the
  overlay has not resolved. No background threads, no busy loop, no repeated
  scans after success.
- **The UFunction call path is the game's own.** `ProcessEvent` is what Blueprint
  calls itself; calling it looks like gameplay script activity, not a hook.

What this does **not** do: hide the dylib from a heartbeat that already knows the
expected image list, spoof device identity, or defeat a server-side stats check.
If ACE adds an integrity pass over `Frameworks/`, the only fix is a different
delivery path (re-signed app with the dylib merged, or a tweak-free build).

## anogs / ACE, read from the shipped binary

`Frameworks/anogs.framework/anogs` is ACE 7.7.49.57576 (`XCLOUD_VERSION_ACE_7.7.49.57576`),
module tag `MRPCS_IOS`, 2.91 MB, arm64, no substrate imports. It has **21 exports**,
and that is the whole surface:

| Group | Exports | Note |
|---|---|---|
| lifecycle | `AnoSDKInit`, `AnoSDKInitEx`, `AnoSDKOnPause`, `AnoSDKOnResume`, `AnoSDKFree` | `init_info` carries `tss_sdk_send_data_to_svr` |
| report | `AnoSDKGetReportData` `2` `3` `4`, `AnoSDKDelReportData*` | the app pulls the buffer and sends it itself |
| server → client | `AnoSDKOnRecvData`, `AnoSDKOnRecvSignature`, `AnoSDKIoctl`, `AnoSDKIoctlOld` | kick / alert / command |
| identity | `AnoSDKSetUserInfo`, `AnoSDKSetUserInfoWithLicense`, `AnoSDKRegistInfoListener` | |
| ObjC | `PluginTssSDKLifecycle` | |

**anogs does not send anything.** It builds a report buffer and hands it to the
host through `AnoSDKGetReportData*`; the host's own network layer posts it. That
single fact decides the whole approach: there is no socket to intercept, and
blocking the upload looks exactly like a dead SDK, which is itself a signal.

The export thunks are 4-byte `b` instructions packed together in `__text`, at
fixed file offsets in this build:

```
0xf2310  AnoSDKGetReportData      stp x29,x30,[sp,#-0x10]! ... mov w0,#1 ; mov w1,#4 ; bl <engine>
0xf239c  AnoSDKIoctlOld            b <engine>
0xf23a0  AnoSDKIoctl               b <engine>
0xf23a4  AnoSDKFree                b <engine>
0xf23a8  AnoSDKGetReportData2      b <engine>
0xf23ac  AnoSDKGetReportData3      b <engine>
0xf23b0  AnoSDKDelReportData3      b <engine>
0xf23b4  AnoSDKGetReportData4      b <engine>
0xf23b8  AnoSDKDelReportData4      b <engine>
0xf23bc  AnoSDKOnRecvSignature     b <engine>
```

## AnoMute — what is actually muted

`AnoMute.dylib` (built here, injected the same way as `PxMenu`) does **not** hook
code. It rewrites the host's own import slots for the report exports, which is a
pointer swap in `__DATA.__la_symbol_ptr` / `__DATA.__got`, then:

1. calls the real `AnoSDKGetReportData`, so anogs still collects everything;
2. writes `<model>_raw.txt` to `Documents/AnoMute/` — the report format is not
   documented anywhere, so it gets captured before anything is edited;
3. if the buffer is text (`≥90 %` printable in the first 256 B), copies it,
   neutralises the value of every known flag key, and returns the copy with the
   **length and every separator preserved**;
4. if the buffer is binary, passes it through untouched and says so in the log.

Byte-identical length matters: the host sizes its packet from the buffer, and a
report that shrank is as loud as a report that says `root_alert`.

Flag keys scrubbed: `root_alert`, `emu_alert`, `cheat_open_id`, `s_open_id`,
`debugger`, `check_state`, `ts2_alert`, `9010_alert`, `9005_alert`, `9014_alert`,
`inline_hook_opcode_dismatch`, `ms_hook_opcode`, `ms_set_inlie_hook`,
`black_module_macho`, `ms_data_crc`, `mrpcs_data_crc_error`, and the
`ms_*` / `mrpcs_*` match-failure pairs. Identity fields (model, uid, role,
version, timings) are never touched.

`AnoSDKIoctl` is rebind-observed, not blocked — dropping server commands makes
the client and server disagree, and that disagreement is visible.

### What this does not fix

| Not fixed | Why |
|---|---|
| `DoRiskFileTCJTask` / `tcj` file scan | `PxMenu.dylib` on disk in `Frameworks/` is still a file. The scanner sits inside 2.3 MB of obfuscated code plus an MRPCS module that carries its own CRC (`mrpcs_data_crc_error`), so patching it is a fight, not a swap. |
| Server-side correlation | ESP / aimbot are measured statistically. No client function to rebind. |
| Heartbeat timing | A missing or empty report is its own signal. AnoMute keeps the report full. |

## Why no substrate, no rpath, no dylib dependency

The usual packaging answer is: bundle `libsubstrate.dylib` in `Frameworks/`,
add it to `LC_LOAD_DYLIB`, and set `@rpath`. It works mechanically, and it is the
wrong move here:

- Substrate's hook primitive is an inline hook — it rewrites the first
  instructions of the target and keeps a trampoline. `inline_hook_opcode_dismatch`
  and `ms_hook_opcode` exist in anogs precisely to compare those bytes.
- Substrate needs `task_for_pid` / `vm_write` on a foreign task for some paths.
  A sideloaded app has no such entitlement; the paths that survive are the ones
  you could have written yourself.
- Every bundled library is one more image in `_dyld_get_image_name`, and one more
  file for the `tcj` scan.

Rebinding a `__la_symbol_ptr` / `__got` entry needs none of that: `vm_protect`
one page, write 8 bytes, restore the protection. No code page changes, no
trampoline, no extra image.

So the dylib has exactly one link dependency to worry about — the one the loader
gives it — and the inject line is plain:

```
@executable_path/Frameworks/PxMenu.dylib
@executable_path/Frameworks/AnoMute.dylib
```

If the host ever ships `arm64e` only, `AnoRebindEverywhere` skips non-`MH_MAGIC_64`
headers and logs `rebind MISSED` rather than writing through a ptrauth slot.

### One dylib instead of two

Same Makefile builds all three libraries, so folding AnoMute into the menu is one
line:

```make
PxMenu_FILES += AnoMute/AnoMute.m
```

Two images become one, and the inject step drops to a single `LC_LOAD_DYLIB`.

## No key, no licence

No key field, no UDID check, no server revalidation, no AES. The menu opens fully
unlocked. (The original `PxExtFFi` gated its menu behind a UDID-bound key; that
whole path is gone, along with its `com.chunmodvn.deltasdk.*` backend.)

## Notes

- `PxMenuView` renders on the menu's own `UIWindow` (`alert + 60`), overlay at
  `alert + 50`, floating button at `alert + 100`.
- Install retries 40× at 250 ms, then gives up. Re-asserts on foreground.
- `PxSelfCheck()` asserts the tree is non-empty and keys are unique at install.
- Actor list refreshes every 2 s, capped at 160 characters; camera manager is
  cached alongside it.
- `PxUE4` is ObjC++ (`-std=gnu++17`) because the object walker is templated.
- iOS 15+, arm64, ARC.
