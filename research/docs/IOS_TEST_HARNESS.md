# iOS Test Harness — see & control a physical iPhone for verification

Established 2026-06-07. Lets a shell-driven agent (or human) inspect and drive a
connected iPhone end-to-end: launch TV.app, screenshot, read the UI tree, tap /
swipe / type, and confirm a synced episode actually **renders and plays**. This
closes the loop on the "title shows but Play does nothing" failure mode
(CLAUDE.md #14) — we can now watch the real screen.

Driver script: `scripts/ios/mp-ios.sh`.

## Two tiers

| Tier | Gives you | Backend | Needs |
|---|---|---|---|
| **1 — see/launch** | screenshot, launch/terminate apps, app/DB state | `pymobiledevice3` (DVT) + `mediaporterctl` | DDI mounted + RemoteXPC tunnel (sudo) |
| **2 — control** | tap, swipe, type, read UI hierarchy, Play | **WebDriverAgent** (XCUITest) over HTTP | signed WDA on device + port-forward |

Touch injection on a non-jailbroken device **requires** Apple's XCUITest (WDA).
pmd3 / go-ios / Appium are all wrappers around it. Screenshots, by contrast, do
NOT need WDA (pmd3 DVT works), but WDA's `/screenshot` also works once it's up —
so Tier 2 alone covers everything except standalone DB/file inspection.

## Toolchain (one-time install)

```bash
brew install libimobiledevice jq                 # iproxy, ideviceinfo, idevice_id
uv tool install pymobiledevice3 --python 3.12     # 3.14 too new for some deps
GOBIN=$HOME/go/bin go install github.com/danielpaulus/go-ios@latest   # 'go-ios'
xcodebuild -downloadPlatform iOS                  # ~8.5 GB — REQUIRED for device builds
```

Xcode 26 splits the iOS **SDK** (compiles) from the iOS **platform** (makes device
destinations eligible). `xcodebuild -showsdks` can list the SDK while device
builds still fail "iOS 26.5 is not installed" — that means the *platform* download
above is missing.

## One-time device setup (target = akm16pro)

1. **Developer Mode** (hidden by Apple since iOS 16; reveal/enable headless):
   ```bash
   pymobiledevice3 amfi reveal-developer-mode      # makes the menu appear
   pymobiledevice3 amfi enable-developer-mode      # enables (reboots + passcode)
   ```
   After reboot, confirm the on-device "Turn On Developer Mode?" prompt.
2. **Enable UI Automation**: Settings → Developer → **Enable UI Automation** → ON.
   Without this, WDA fails: *"Timed out while enabling automation mode."*
3. **Auto-Lock → Never** (Settings → Display & Brightness). DDI mounts fail with
   `DeviceLocked` if the screen locks mid-operation — this was the single biggest
   time-sink. Keep the device unlocked during builds.
4. **Trust** the Mac (USB pairing). Paid Developer cert (team `BKY9R5336T`) =
   apps trust automatically; a free/personal team would need manual
   Settings → General → VPN & Device Management → Trust.

## Build + sign WDA (one-time, ~5 min)

```bash
git clone --depth 1 https://github.com/appium/WebDriverAgent.git ~/ios-tools/WebDriverAgent
cd ~/ios-tools/WebDriverAgent
xcodebuild build-for-testing \
  -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination 'id=00008140-000C14EA3862201C' \
  -derivedDataPath /tmp/wda-build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=BKY9R5336T CODE_SIGN_STYLE=Automatic
```

Gotchas that cost real time here:
- **`-allowProvisioningDeviceRegistration` is mandatory** for a never-before-seen
  device. Plain `-allowProvisioningUpdates` errors *"Device isn't registered in
  your developer account"* and silently leaves a generic profile that fails
  install with `0xe8008015`.
- **`DEVELOPMENT_TEAM` must be the team Xcode has an account for**, not whichever
  team is on a keychain cert. Find it:
  `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier`. Here the
  keychain had an `Apple Development … (CNWJDZVFBD)` cert but Xcode's account is
  `BKY9R5336T` → build under `BKY9R5336T`.
- **Device must be unlocked** so CoreDevice can mount its DDI. If pmd3 already
  mounted a DDI, unmount it first: `pymobiledevice3 mounter umount-personalized`
  (only one personalized DDI can be mounted at a time → the two tools collide).

## Run WDA + drive it

```bash
scripts/ios/mp-ios.sh wda-up          # launches WDA (xcodebuild test-without-building) + iproxy 8100
scripts/ios/mp-ios.sh launch com.apple.tv
scripts/ios/mp-ios.sh screenshot /tmp/shot.png
scripts/ios/mp-ios.sh buttons         # list tappable accessibility names
scripts/ios/mp-ios.sh tap "TV Shows"
scripts/ios/mp-ios.sh tap "play"      # the TV.app Play control is name="play"
```

`wda-up` is idempotent: it checks `/status`, relaunches the runner if down, and
re-establishes the port-forward. The runner is a long-running `xcodebuild
test-without-building`; if the device sleeps/reboots, re-run `wda-up`.

Element finds in TV.app: episode rows carry invisible Unicode (LRM/FSI/PDI) in
their names — match with a WDA predicate (`label CONTAINS 'Eccentric'`) rather
than exact name. The TV.app tab bar buttons are `UIA.TV.Tab.*`.

### Verified loop (2026-06-07)
Launch TV.app → tap show → episode detail (SEASON 1 · EPISODE 1, HD, still) →
tap `play` (center 201,229) → **episode plays full-motion landscape**. Confirms
the synced file binds and plays, not just a metadata row.

## F1 — Wi-Fi sync (partial validation, 2026-06-07)

Progress against plan.md F1. **akm16pro is now reachable over Wi-Fi for control:**
- `pymobiledevice3 lockdown wifi-connections --state on` (one-time, over USB).
- With the Mac and device on the same subnet (here: both on akm17pro's Personal
  Hotspot, `192.168.10.x` — a single subnet, so Bonjour works), `idevice_id -n`
  lists akm16pro and it advertises `_apple-mobdev2._tcp`.
- `ideviceinfo -n` (network interface only) returns lockdown values → **classic
  lockdown sessions open over Wi-Fi**, strong evidence AFC+ATC will too.
- The app's attach callback (`Sync/Device.swift:388`) has no USB-only filter, so
  a Wi-Fi device already flows into the device list.

**Still unverified:** a full AFC upload + ATC sync session over Wi-Fi (throughput,
Ping/Pong under jitter, session hold). Needs a sync run with **USB unplugged** to
be certain it uses Wi-Fi — which interrupts the WDA harness, so it's a dedicated
next step. A broken-USB-port device (akm17pro) can NOT be an F1 target: initial
pairing requires USB, and there's no pure-wireless pairing in lockdown/usbmux.

## Native vs pmd3

The sync axis is fully native to the app (AMDevice / AFC / ATC, USB **and**
Wi-Fi) — pmd3 is not needed for sync or F1. pmd3 earns its keep only for the
iOS-17+ developer-services layer (DDI mount + RemoteXPC tunnel → DVT screenshot).
`wifi-connections` is one `AMDeviceSetValue` and could be a native
`mediaporterctl wifi-sync on` if we want to keep F1 sudo-free.

## Devices

- **akm16pro** — iPhone 16 Pro (iPhone17,1, iOS 26.4.2), UDID
  `00008140-000C14EA3862201C`. Working USB. Primary harness + F1 target.
- **akm17pro** — over Wi-Fi, **no working USB-data port** → can't be paired →
  not usable as a sync target. Currently the Mac's hotspot uplink.
