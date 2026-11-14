# Local Flutter environment

The app requires an explicit environment. It never chooses production by
default.

From a fresh clone, copy the nonsecret local endpoint template:

```powershell
Copy-Item .env.local.example .env.local
```

Run local development with:

```powershell
flutter run --dart-define=ENV=local
```

`ENV=local` loads `.env.local`, whose endpoints are loopback addresses. A
missing or invalid `ENV` value fails during startup. Production must be selected
explicitly with `--dart-define=ENV=production`; that mode loads the existing
`.env` file. Do not commit `.env.local` or place credentials in the example.
