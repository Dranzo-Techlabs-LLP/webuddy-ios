# Google Sign-In on iOS

Clariva signs in with Google through the Clariva API (`POST v1/auth/google`), exactly like Android:
the app gets a Google **ID token** and the API verifies it.

The ID token is requested for the **web/server** client
(`ClarivaConfig.googleServerClientID`, `462109274571-5qsno88m3vu5gijggbvccej3v8tt1qbe`), so its
audience is the same one Android's tokens have and the API already accepts it.

The web client can't be used to *start* the sign-in from an app — Google rejects it with
**"Access blocked: Custom scheme URIs are not allowed for 'WEB' client type (Error 400:
invalid_request)"**. iOS needs its own **iOS-type** OAuth client, just as Android has its own
Android client. Until one is configured the button reports
"Google sign-in is not configured in this build."

## Setup (one time)

1. Open Google Cloud Console → the project that owns the web client above (project number
   `462109274571`) → **APIs & Services → Credentials**.
2. **Create credentials → OAuth client ID**:
   - Application type: **iOS**
   - Name: e.g. `Clariva iOS`
   - Bundle ID: the bundle ID the app is shipped with (`BASE_BUNDLE_IDENTIFIER` in `app.yml`).
3. Copy the new **Client ID**, e.g. `462109274571-abc123def456.apps.googleusercontent.com`.
4. In `app.yml`, paste the part **before** `.apps.googleusercontent.com`:
   ```yaml
   GOOGLE_IOS_CLIENT_NUMBER: "462109274571-abc123def456"
   ```
   This single setting fills in both `GIDClientID` and the reversed-client-ID redirect URL scheme
   (`com.googleusercontent.apps.<number>`) in `Info.plist`.
5. Regenerate the project and build:
   ```bash
   xcodegen
   ```

## Notes

- **Backend:** no change expected — tokens are issued for the web client. If the API ever rejects
  them with an audience error, add the iOS client ID to its `GOOGLE_CLIENT_IDS` as well.
- **OAuth consent screen:** while the app is in *Testing* status only the listed test users can sign
  in (same as Android).
- **Code:** `ElementX/Sources/Services/Clariva/GoogleSignInService.swift` (GoogleSignIn-iOS 8.0.0),
  `ClarivaConfig.googleIOSClientID` (read from `GIDClientID`), Clariva auth screen.
