# theadbook Player

Universal **Xibo digital signage player** for theadbook — runs on Android phones, tablets, Android TV, foldables, and dedicated signage hardware. Connects to `https://xibo-be.yourpreview.space`.

Portrait and landscape are supported; orientation follows the device during setup. Playback uses fullscreen immersive mode.

## Run

```bash
flutter pub get
flutter run
```

Release APK:

```bash
flutter build apk --release
```

## First-time setup

1. Open the app → enter **CMS Key** and **Screen Name** → **Connect Screen**
2. Note the **Hardware Key** on the waiting screen for admin approval in the CMS
3. After approval (XMDS code `201`), playback starts automatically

## Replace branding

Replace `assets/logo.png` with your theadbook logo (recommended height ~256px).

## Project layout

See `lib/` — `config/`, `models/`, `services/`, `screens/`, `widgets/`, `utils/`.
