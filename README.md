# Qash Mobile

Print station app for Qash. It sits next to a Bluetooth ESC/POS receipt printer (tested on the Rongta RPP02N) and prints whatever the Qash backoffice queues for its station: customer receipts, kitchen/waiter tickets, table QR slips and cashier session reports.

Jobs arrive two ways, both feeding the same durable queue (`lib/app/printer/print_queue.dart`):

- **Reverb push** (`reverb_service.dart`): the fast path.
- **Polling** (`poll_service.dart`): every 4s, catches anything the socket missed, and acknowledges each job (`mark-printed` / `mark-failed`).

The queue deduplicates on the server job id, so a job is printed once even if both paths deliver it.

## Running

```bash
flutter pub get
flutter run --dart-define=CENTRAL_URL=https://withqash-demo.tech
```

`CENTRAL_URL` defaults to `https://qash.id` (production). Activation always goes to `{CENTRAL_URL}/api/device/activate`; the server answers with the tenant's own API and Reverb settings.

Test on a real Android phone (Bluetooth printing doesn't work in an emulator). Debug builds allow `http://` backends; release builds don't.

## Activating a station

1. In the backoffice, create a print station, or run `php artisan device:token` on the backend.
2. Enter the 4-character token on the app's first screen.
3. Tap **Hubungkan / ganti printer**, pick the printer, then **Tes cetak**.

Re-activating the same station on another phone rotates its token; the old phone then shows **Perangkat dinonaktifkan**.

## Platforms

- **Android**: supported. A foreground service keeps polling alive in the background, and the app asks once to be exempt from battery optimisation.
- **iOS**: printing needs the printer's MFi protocol string (placeholder in `ios/Runner/Info.plist` and `bluetooth_service.dart`, see the TODO there). App Store release also needs the printer vendor to register the app through the MFi program. iOS stations only poll while the app is in front; the screen is kept awake.

## Checks

```bash
flutter analyze
flutter test
```

CI runs both on every push to `main` and every pull request.

## Branding

Icons and splash are generated from `assets/brand/` (see the comment in `pubspec.yaml` for how to regenerate).
