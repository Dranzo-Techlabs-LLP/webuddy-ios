# Deploying Webuddy iOS to TestFlight

End-to-end recipe for building a Webuddy iOS `.ipa` and uploading it to TestFlight.

## 0. Prerequisites (one-time setup)

### 0.1 Apple Developer Program
- Active **Apple Developer Program** membership ($99/yr) on the team that owns Webuddy.
- 10-character **Team ID** from <https://developer.apple.com/account> → Membership.

### 0.2 App ID + Bundle Identifier
- In the developer portal, register an App ID under **Certificates, Identifiers & Profiles → Identifiers**:
  - Description: `Webuddy iOS`
  - Bundle ID: explicit, e.g. `com.dranzo.clariva`
  - Capabilities: enable **Push Notifications**, **App Groups**, **Keychain Sharing** (Element X uses these).
- Register the App Group `group.com.dranzo.clariva` (the script sets `APP_GROUP_IDENTIFIER` in `app.yml` to `group.<bundle id>` for you).

### 0.3 App Store Connect record
- <https://appstoreconnect.apple.com/apps> → **+ → New App**.
- Platform: iOS. Bundle ID: select the one from 0.2. Name: `Webuddy`. SKU: anything unique.
- Under **TestFlight** create at least one **Internal Testing** group. Add internal testers (up to 100, App Store Connect users on your team).

### 0.4 App Store Connect API key (for non-interactive upload)
- App Store Connect → **Users and Access → Integrations → App Store Connect API**.
- Generate a key with role **App Manager** or **Developer**.
- Note the **Key ID**, **Issuer ID**, and download the `.p8` file once (cannot re-download).
- Place the `.p8` somewhere safe outside the repo (e.g. `~/.appstoreconnect/AuthKey_XXXXXXXX.p8`).

### 0.5 Local tooling
```sh
brew install xcodegen xcbeautify
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
Open Xcode once, sign in to your Apple ID under **Settings → Accounts**, and add the developer team.

## 1. Patch project metadata

The repo's defaults still point at Element's team / bundle. The provided script overwrites them in place:

| Field | File | Element default | Webuddy value |
|---|---|---|---|
| `BASE_BUNDLE_IDENTIFIER` | `app.yml` | `io.element.elementx` | `com.dranzo.clariva` |
| `DEVELOPMENT_TEAM`       | `app.yml` | `7J4U792NQT` | _your team id_ |
| `APP_GROUP_IDENTIFIER`   | `app.yml` | `group.io.element` | `group.com.dranzo.clariva` (override with `APP_GROUP_ID`) |
| `MARKETING_VERSION`      | `project.yml` | `26.01.1` | bump per release |
| `CURRENT_PROJECT_VERSION`| `project.yml` | `1` | UTC timestamp by default |

The `Tools/Scripts/build_for_testflight.sh` script does this for you when you set the env vars below.

## 2. Build the `.ipa`

```sh
chmod +x Tools/Scripts/build_for_testflight.sh

# Build only (no upload). Without Homebrew, point XCODEGEN at a downloaded xcodegen binary.
APPLE_TEAM_ID=ABCDE12345 \
APP_BUNDLE_ID=com.dranzo.clariva \
MARKETING_VERSION=1.0.0 \
./Tools/Scripts/build_for_testflight.sh
```

The script:
1. Patches `app.yml` and `project.yml` with your team / bundle / version.
2. Re-runs `xcodegen generate` so `ElementX.xcodeproj` reflects the patch.
3. Archives the `ElementX` scheme (Release config) for `generic/platform=iOS`.
4. Exports a signed App Store `.ipa` to `build/ipa/ElementX.ipa` using automatic signing (`-allowProvisioningUpdates`).

If signing fails, open `ElementX.xcodeproj` in Xcode → target `ElementX` → **Signing & Capabilities**, choose your team, and let Xcode generate the provisioning profile once. Subsequent script runs reuse it.

## 3. Upload to TestFlight

### 3.1 Automatic via the script (recommended)

```sh
APPLE_TEAM_ID=ABCDE12345 \
APP_BUNDLE_ID=com.dranzo.clariva \
APP_STORE_CONNECT_API_KEY_ID=XXXXXXXXXX \
APP_STORE_CONNECT_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
APP_STORE_CONNECT_API_KEY_PATH=~/.appstoreconnect/AuthKey_XXXXXXXX.p8 \
UPLOAD=1 \
./Tools/Scripts/build_for_testflight.sh
```

The script runs `xcrun altool --validate-app` then `--upload-app`. Apple processes the build in 5–30 min; once it appears in App Store Connect → TestFlight → Builds, it's available to your internal testers immediately.

### 3.2 Manual via Transporter

If you'd rather upload by hand:
1. Build with `UPLOAD=0` (default). Find the `.ipa` at `build/ipa/ElementX.ipa`.
2. Open the Transporter app from the Mac App Store, sign in with your Apple ID.
3. Drag the `.ipa` into Transporter, click **Deliver**.

### 3.3 Manual via Xcode Organizer

1. In Xcode: **Product → Archive** (with the `Any iOS Device (arm64)` destination).
2. Window → Organizer → select the archive → **Distribute App → App Store Connect → Upload**.
3. Choose automatic signing, your team, then **Upload**.

## 4. After upload

- App Store Connect → your app → TestFlight → **iOS** tab. You'll see "Processing" then a build number.
- The first build per version triggers an **export compliance** prompt. If the app uses only HTTPS (and our localhost ATS exception only kicks in during dev), you can answer "Uses standard encryption / no qualifying additions" — confirm with your team's legal owner.
- Add the build to your Internal Testing group → testers get an email + push from the TestFlight app.
- For external testers (>100 testers, or non-team users) Apple does a brief beta review (24–48h).

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `No profiles for 'com.dranzo.clariva' were found` | Bundle ID not registered in dev portal | Repeat 0.2 |
| `Failed to register bundle identifier` during archive | App ID exists on a different team | Match `DEVELOPMENT_TEAM` to the team that owns the bundle ID |
| `Invalid Pre-Release Train` from altool | Marketing version regressed | Increment `MARKETING_VERSION` |
| `ERROR ITMS-90023: Missing required icon file` | App icon variant missing | Check `Variants/` and `Resources/Images.xcassets/AppIcon` |
| `cannot find type 'RustBuffer' in scope` / `MatrixSDKFFI` errors (Xcode 26.6) | The SDK's module map is in a `MatrixSDKFFI/` header folder whose name doesn't match its `matrix_sdkFFI` module | The script passes `SWIFT_ENABLE_EXPLICIT_MODULES=NO` and `-Xcc -fmodule-map-file=$(BUILT_PRODUCTS_DIR)/include/MatrixSDKFFI/module.modulemap`; pass the same two settings to any manual `xcodebuild` |
| `App Transport Security has blocked a cleartext HTTP` at runtime | Pointing at non-localhost HTTP URL | Use HTTPS in production. The Info.plist exception only allows `http://localhost` |

## 6. Release checklist

Before each TestFlight upload:
- [ ] `MARKETING_VERSION` bumped if user-visible changes
- [ ] `CURRENT_PROJECT_VERSION` strictly greater than the last uploaded build (the script defaults to a UTC timestamp, which is monotonic)
- [ ] `WalletService.defaultBaseURL` points at production (`https://wallet.clarivahub.com/`), not `http://localhost:3000`
- [ ] No leftover debug logs printing wallet credentials
- [ ] Internal testers added to the TestFlight group
