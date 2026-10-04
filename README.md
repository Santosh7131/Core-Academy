# Core Academy

An Android app for a small maths tuition (CBSE, Classes 6–12). Students take timed
multiple-choice tests on their phones, the app marks them, and the teacher sees every
result. The teacher creates each student's login, builds tests from a question bank, and
can photograph a school question paper so Groq AI types its questions out for her to check.

## What's here

| Folder | What it is |
|---|---|
| `app/` | The Flutter app (Android). Students and the teacher use the same app. |
| `api/` | The API: Hono on Neon Functions, with Postgres and object storage on Neon. The schema and the marking functions are in `api/migrations/`. |
| `design/` | Soft Structuralism comps (`design/comps/`), their screenshots and the token CSS. |
| `tools/` | Scripts to migrate, seed, test, audit, and drive the test phone. |

## How marking stays fair

- The right answers never leave the server until a student submits.
- Each student gets their own order of questions and options.
- The deadline is the start time plus the time limit, capped at the test's closing time. The
  server enforces it with 30 seconds of grace, and an attempt that runs out submits itself.
- One attempt per test, unless the teacher allows a retake.
- Five wrong PINs lock a login for five minutes.

## Running it

You need Node 24, Flutter 3.47, the Neon CLI (`npm i -g neon`, then `neon login`) and an
Android phone with USB debugging on.

**1. Install and link to the dev branch**

```bash
npm install
neon link --project-id tiny-cell-87785722 --branch dev -y
neon env pull
```

`neon env pull` writes the branch's database and storage settings to `.env.local`.

**2. Database** (first time, or after a schema change)

```bash
npm run migrate
npm run seed
```

The seed adds 8 sample students, 42 sample questions and sample tests. Their logins and the
teacher's go to `tools/out/sample-logins.md`. That folder is git-ignored, so logins never
reach the repo.

**3. The API on your PC**

Put the Groq keys in `api/.env.secrets` as `GROQ_API_KEYS=key1,key2` (git-ignored). Then,
in PowerShell:

```powershell
$env:GROQ_API_KEYS = ((Get-Content api\.env.secrets) -match '^GROQ_API_KEYS=')[0].Substring(14)
neon dev --source ./api/src/index.ts --port 8787
```

**4. The app on the phone**

```bash
adb reverse tcp:8787 tcp:8787
cd app
flutter run --dart-define=API_BASE=http://127.0.0.1:8787
```

Leave out `--dart-define` and the app talks to the deployed dev API instead, so it works
without your PC.

## Deploying the API

```bash
npm run deploy
```

This deploys the API function on the linked branch. The Groq keys are set on the function
once per branch, outside `neon.ts`, so a deploy never carries them:

```powershell
powershell -ExecutionPolicy Bypass -File tools/upload-groq-keys.ps1 -Branch dev
```

Until that has run on a branch, the API there reports `"ai": false` at `/` and the paper
reader is off.

## Checks

| Command | What it proves |
|---|---|
| `npm run typecheck` | The API type-checks. |
| `npm run test:api` | 45 end-to-end checks of the marking rules against the deployed dev API. It creates its own students and tests, then removes them. |
| `node tools/check-answers.ts` | Every sample question's marked answer is right, and no other option equals it. |
| `node tools/ai-test.ts` | How accurately the AI reads the 2-page sample paper (render it first with `tools/make-sample-paper.ps1`). |
| `flutter analyze` and `flutter test` (in `app/`) | The app's lints and unit tests. |
| `python tools/audit.py` | The design audit: type scale only, no stray colours, no banned patterns, and where the accent is used. |

## Design

The app follows Soft Structuralism. `tools/extract-tokens.mjs` copies the token layer
verbatim from the design guide into `app/lib/theme.dart` and `design/comps/tokens.css`; the
guide itself stays out of the repo. The one accent colour, violet, belongs to the AI paper
reader and nothing else. Nothing moves: no spinners, slide transitions or animated charts.

To view the comps, run `python -m http.server 8777 --bind 127.0.0.1 --directory design/comps`.

## Secrets

These are git-ignored and must never be committed: `.env.local`, `api/.env.secrets`,
`tools/out/` (sample logins), and any keystore. The Groq keys live only in
`api/.env.secrets` and on the deployed function, never in the app.

## Going live

1. Set up the `main` branch. The seed is what creates the teacher login, so it runs here
   too; it rewrites `tools/out/sample-logins.md` with `main`'s logins.

   ```bash
   neon env pull --branch main --file .env.main
   node tools/migrate.ts --env .env.main
   node tools/seed.ts --env .env.main --allow-main
   neon checkout main
   npm run deploy
   ```

   Then upload the Groq keys with `-Branch main`, and run `neon checkout dev` to go back.
2. Build a signed release APK that points at the `main` API.
3. In the app, delete the sample data (Settings → Delete all sample data). The teacher login
   and the school stay.
4. Change the teacher password from the seeded one.
