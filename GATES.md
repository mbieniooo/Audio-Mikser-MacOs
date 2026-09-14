# Mikser — foreseen gates (things only Mieszko can do)

No spend, no accounts, no network, no sudo anywhere in this build.

1. **Keychain password** — creating or first using the self-signed "Mikser Dev" code-signing
   identity may pop a Keychain dialog asking for your login password. Once.
2. **System Audio Recording permission** — the first time Mikser scales an app, macOS shows a
   prompt naming Mikser. Click Allow. Once (stable signing identity keeps it).
3. **Login item** — registering Mikser as a login item may show a macOS notification or ask for
   confirmation in System Settings › General › Login Items. Once.
4. **Install location** — `/Applications` is writable by your account without a password
   (verified), so no gate here; `~/Applications` is the fallback.
5. **Ear test** — the final sign-off is you, with Spotify or YouTube playing, moving sliders.

Not gates, but expected side effects: the first time a slider leaves 100 there may be a gap of
well under 100 ms while the app's audio path switches into the tap.
