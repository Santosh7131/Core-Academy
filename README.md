# Core Academy

An Android app for a small maths tuition (CBSE, Classes 6–12). Students take timed
multiple-choice tests on their phones, the app marks them, and the teacher sees every
result. The teacher creates each student's login, builds tests from a question bank, and
can photograph a school question paper so Groq AI types its questions out for her to check.

## What's here

| Folder | What it is |
|---|---|
| `app/` | The Flutter app (Android). Students and the teacher use the same app. |
| `admin/` | The developer's admin app (Android), "CA Admin": who uses the app, on which phones, and how the server is doing. |
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
- While a student is logged in, release builds block screenshots and screen recording
  (Android's FLAG_SECURE). The teacher's screens can still be captured.

## Groups and subjects

The tuition teaches more than one subject. Each student studies one or more subjects, and a
group is a class and a subject together: "10th Science" is every Class 10 student who studies
Science. Chapters, questions, papers and tests each belong to a subject, and a test goes to
its group or to chosen students in it. A test never leaves its group: an older "whole class"
test also reaches only the class's students who take its subject. Maths and Science are built
in, and more subjects can be added in Settings or straight from a paper's subject choice.
Students added by the 1.0.0 app, and everything made before subjects existed, count as Maths.

## Fixing and deleting

Correcting a question's right option, or its marks, marks again every test already written
with it, so a student who chose the right answer gets the mark even when the key was wrong at
the time. Questions, tests, papers and students can all be deleted. A question leaves the tests
nobody has written; one in a test students have written stays, so their results stay whole. A
written test, or a student, goes only after a second warning, and takes those results with it.
Deleting a paper also deletes the questions saved from it that no test uses.

## Ready-made questions

`tools/library/` holds original chapter-wise MCQs, with worked solutions, written for the
NCERT 2026-27 books (nothing is copied from a paper or a book): ten per chapter for Class 7
Maths (Ganita Prakash, 15 chapters), Class 8 Maths (Ganita Prakash, 14), Class 9 Maths
(Ganita Manjari, 14) and Science (Exploration, 13), and Class 10 Maths (14) and Science (13).
That is 830 questions. Every answer is proved before it can be imported:

```bash
node tools/check-library.ts
node tools/seed-library.ts --env .env.local
```

The import adds each book's chapters, its questions (tagged Ready-made in the app) and one
draft chapter test per chapter for the class's group. It is safe to run again: rows are
matched by `library_key`, and a chapter test that has been published or written is left alone.

## Question papers

The teacher adds the pages first: photos, gallery images or a PDF. AI then works out the
paper's name, class, subject, where it comes from (its category, such as "NCERT Exemplar")
and, for a one-chapter paper, the chapter. It asks the teacher only for what it could not
find. Every page is read into drafts, together with any answer key the paper prints, on
whichever page it is.

Answers come from that key first. For the rest, two models from different families
(`GROQ_SOLVE_MODELS` and `GROQ_CHECK_MODELS`) each work the question out, and an answer is
marked only when both pick the same option and each is at least 90% sure. Questions that need
a figure are left to the teacher. Each marked answer says where it came from, so the teacher
can check it before saving. Once every question is saved or skipped, the app asks whether to
publish the paper as a test for its class and subject straight away; the test remembers the
paper it came from.

The Questions tab groups the bank by source: one row per paper category, other uploaded
papers, questions typed by hand, and the ready-made library. Each opens with its own class,
subject and chapter filters.

Pages are read by Google's Gemini 3.5 Flash-Lite on its free tier (`GEMINI_API_KEY`), which
takes about 2 seconds a page. Groq's vision model reads instead whenever Gemini is busy or
refuses a page, and Groq always works out the answers. Without a Gemini key, Groq reads too.
Groq limits each account, not each key, so keys made in one account share one budget: about
1,000 requests a day per model, and 7,000 input tokens a minute for the vision model, which is
only two or three pages a minute. The app waits out a limit on its own and shows how long it
is waiting. Using several Groq accounts to get past the limits is against Groq's rules.

## Screens stay current

Every change made in the app tells the screens showing that data to load again, and a tab
loads again when it comes back into view or the app returns to the front. Home, a test's
results and the student's home also check every 30 to 60 seconds while on screen, and stop
after 15 minutes without a touch, so a phone left open does not keep the database awake.

## Updates

From 1.2.0 on, the app updates itself. When it starts, and when it comes back to the front
(at most every two hours), it reads `update.json` from the latest GitHub release. If that
names a higher build number than the one installed, Home shows "Version 1.2.1 is ready".
Update downloads the APK, checks its SHA-256 against the feed and hands it to Android's
package installer. The first time, Android asks once whether Core Academy may install apps.
After that, Android 12 and later put the update in without the Install prompt; older Android
shows it. Android closes the app while it replaces it, and a notification offers to open the
new version. Settings (and a student's profile) show the version and can check at once.

Versions 1.1.0 and earlier have no updater, so 1.2.0 has to be installed by hand once.
Debug builds never offer an update unless they are built with
`--dart-define=UPDATE_FEED=...`.

## The admin app

`admin/` is a separate Android app for the developer, "CA Admin" (app id `com.coreacademy.admin`).
It takes only a developer login, and reads either the live database or dev. It shows:

- every account, when it was last seen, and who is online now;
- each phone an account is signed in on, with its model, Android version and app version, and
  phones shared by more than one account (apps from 1.2.1 report this; an older app's login
  counts as one phone until it updates);
- the login history, wrong PINs and lockouts;
- which app versions the phones run;
- the database and storage sizes, and an estimate of this month's compute hours, taken from
  when the database woke and its last request (Neon's own usage figures read 0 on the free plan;
  its console has the exact number);
- API requests a day, the slowest routes and server errors, and the AI reader's use.

It changes only two things: it can sign an account out of one phone, and unlock a locked login.
Only signed-in requests and logins are counted, since they use the database anyway; the
notification trigger and anonymous traffic never wake it.

It looks the same as the main app because it uses the main app's own theme and components.
`admin/lib/theme.dart`, `ui/tokens.dart` and `ui/kit.dart` are copies: change the originals in
`app/lib`, then copy them over again with `node tools/sync-admin-ui.mjs`. The icons come from
`tools/gen-icons.mjs`, which writes both apps' sets.

The developer login is made per branch, with the password typed at a hidden prompt:

```bash
node tools/create-developer.ts --env .env.main --username <name>
```

The admin app updates itself like the main app, but privately: a release goes into the branch's
storage, and only the developer login can download it. The first install is by hand (the APK is
copied to `tools/out`).

```powershell
.\tools\release-admin.ps1 -Notes notes.txt
```

A release build reads only the live API, the one the students use; there is nothing to switch.
A test build (`flutter run` in `admin/`) reads dev. To run it against an API on the PC:
`adb reverse tcp:8787 tcp:8787`, then `flutter run --dart-define=API_BASE=http://127.0.0.1:8787`.

## Notifications

Push notifications go through Firebase Cloud Messaging. Each student is told once about each
test, the moment it is open for them: when it is published, or later if they join its group or
are added to it (`test_notices` records who was told). They get a reminder an hour before it
closes if they have not started it
(only for tests that were open two hours or more; for a shorter one, the first notification
already gave the closing time). At 8 pm India time the teacher gets a summary of the day, if
anything happened.

The app registers the phone after logging in and on every start. The registration belongs to
that login, so logging out, or a PIN reset, stops the notifications. Android shows a
notification only while the app is in the background. One that arrives with the app open makes
the screens load again instead, so the new test is on the student's home screen at once.
Publishing an open test
announces it straight away. Everything else comes from `/cron/notify`, which a Neon trigger
calls every five minutes. That run reads the time of the next
notification from `notify/next.json` in the bucket and only queries the database when it is
due. If it queried every time, the 0.25 CU compute would never scale to zero: 186
compute-hours a month, and the free plan has 100.

To set it up, once:

1. In the Firebase console, create a project and add two Android apps:
   `com.coreacademy.core_academy` and `com.coreacademy.core_academy.dev`. Save the
   `google-services.json` you get after the second as `app/android/app/google-services.json`.
   Builds made without that file work normally, with notifications off.
2. In Project settings, under Service accounts, generate a private key. Save it as
   `api/firebase-service-account.json` and upload it to the function:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/upload-firebase-key.ps1 -Branch dev
   ```

3. Create the trigger on that branch. The cron is in UTC; every five minutes lines up with
   India's :00 and :30.

   ```bash
   neon triggers create --branch dev --function-slug api --name notify --cron '*/5 * * * *' --function-path /cron/notify
   ```

Until the key is on a branch, the API there reports `"push": false` at `/` and sends nothing.
The trigger is not declared in `neon.ts`: `neon dev` refuses to run against a branch that is
missing a declared trigger, and `neon deploy` leaves triggers made with the CLI alone.

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

Put the AI keys in `api/.env.secrets` (git-ignored): the Groq keys as
`GROQ_API_KEYS=key1,key2` and the Gemini key as `GEMINI_API_KEY=key`. Then, in PowerShell:

```powershell
$env:GROQ_API_KEYS = ((Get-Content api\.env.secrets) -match '^GROQ_API_KEYS=')[0].Substring(14)
$env:GEMINI_API_KEY = ((Get-Content api\.env.secrets) -match '^GEMINI_API_KEY=')[0].Substring(15)
neon dev --source ./api/src/index.ts --port 8787
```

`tools/upload-groq-keys.ps1 -Branch dev` puts both keys on a deployed branch.

**4. The app on the phone**

```bash
adb reverse tcp:8787 tcp:8787
cd app
flutter run --dart-define=API_BASE=http://127.0.0.1:8787
```

This is the test build, "Core Academy Dev" (app id `com.coreacademy.core_academy.dev`), so it
installs beside the live app. Leave out `--dart-define` and it talks to the deployed dev API
instead, so it works
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

The live API runs on the `main` branch. Ship an API change or a new migration there too,
once it works on dev:

```bash
node tools/migrate.ts --env .env.main
neon deploy --branch main --no-env-pull
```

Keep `--no-env-pull`: without it, `neon deploy` writes `main`'s settings over `.env.local`,
and the scripts that read it would then point at the live database.

## Checks

| Command | What it proves |
|---|---|
| `npm run typecheck` | The API type-checks. |
| `npm run test:api` | 109 end-to-end checks of the marking rules, groups, logins, question papers (including ones uploaded before their details are known, printed answer keys and question groups) and the admin app's API against the deployed dev API (add `-- --env .env.main` for the live one; the admin checks run only where the logins file has a developer login). It creates its own students, subject, tests and paper, gives its tests only to those students, then removes them all. |
| `node tools/notify-test.ts --log server.log` | 25 checks of the notifications against the API on your PC, run with `PUSH_DRY_RUN=1` so each notification is written to the log instead of sent. Dev only. |
| `node tools/check-answers.ts` | Every sample question's marked answer is right, and no other option equals it. |
| `node tools/ai-test.ts` | How accurately the AI reads the 2-page sample paper (render it first with `tools/make-sample-paper.ps1`). |
| `flutter analyze` and `flutter test` (in `app/`) | The app's lints and unit tests. |
| `python tools/audit.py` | The design audit: type scale only, no stray colours, no banned patterns, and where the accent is used. |

## Design

The app follows Soft Structuralism. `tools/extract-tokens.mjs` copies the token layer
verbatim from the design guide into `app/lib/theme.dart` and `design/comps/tokens.css`; the
guide itself stays out of the repo. The one accent colour, violet, belongs to the AI paper
reader and nothing else. Motion stays small: the press scale, short fades between screens,
the refresh turn and a chosen option settling into place. No spinners or animated charts.

To view the comps, run `python -m http.server 8777 --bind 127.0.0.1 --directory design/comps`.

## Secrets

These are git-ignored and must never be committed: `.env.local`, `.env.main`,
`api/.env.secrets`, `api/firebase-service-account.json`, `app/android/app/google-services.json`,
`tools/out/` (logins), and any keystore. The Groq keys and the Firebase service-account key
live only in those files and on the deployed function, never in the app.
(`google-services.json` does go into the app: it only names the Firebase project.)

## Going live

The `main` branch holds the live data. It never gets sample data: it starts with just the
teacher login. This is how it was set up:

```bash
neon env pull --branch main --file .env.main -s postgres
node tools/migrate.ts --env .env.main
node tools/create-teacher.ts --env .env.main
neon deploy --branch main --no-env-pull
neon env pull --branch main --file .env.main
node tools/api-test.ts --env .env.main
```

The first pull takes only the database settings, because the bucket the full pull expects
only exists after the first deploy. `create-teacher.ts` writes the teacher login to
`tools/out/logins.main.md`.

Then upload the Groq keys with `tools/upload-groq-keys.ps1 -Branch main`, and change the
teacher password from the generated one in the app (Settings → Password).

The app only accepts teacher passwords of 8 or more characters. To set any other password, or
to reset a forgotten one, run this in a terminal and type the password at the hidden prompt:

```bash
node tools/set-teacher-password.ts --env .env.main
```

## Releasing the app

Release builds talk to the live API (`main`); debug builds talk to dev. A release is signed
with the key in `app/android/core-academy-release.jks`, and `app/android/key.properties` holds
its passwords. Both are git-ignored. **Keep a copy of both somewhere safe.** Android only
installs an update over an app signed with the same key. Lose the key, and every student has
to uninstall and reinstall.

1. Raise `version:` in `app/pubspec.yaml`, for example `1.2.1+4`. The number after `+` must
   go up every release: installed copies compare it to decide whether an update is newer.
2. Build it (ARM only, which covers every phone) and try it on the test phone:

   ```powershell
   .\tools\phone.ps1 release
   ```

3. Write what changed in a plain text file, a line per change. GitHub shows it on the
   release, and the app shows it in its "What is new" card.
4. Publish it:

   ```powershell
   .\tools\release-app.ps1 -Notes notes.txt
   ```

   The script builds the signed APK, writes `tools/out/update.json` (version, build number,
   download link, SHA-256, size and the notes), creates the GitHub release with both files,
   then reads the feed back through GitHub's latest-release link. Phones on 1.2.0 or later
   offer the update within two hours, or at once from Settings, App, Check for updates.
   Add `-NoPublish` to build and write the files without releasing.

To try the updater without publishing anything, build two debug APKs that read a feed on the
PC, the second with a higher build number:

```bash
flutter build apk --debug --build-number=3 --dart-define=UPDATE_FEED=http://127.0.0.1:8778/update.json
flutter build apk --debug --build-number=4 --build-name=1.2.1 --dart-define=UPDATE_FEED=http://127.0.0.1:8778/update.json
```

Put the second APK and an `update.json` that describes it in a folder, serve the folder with
`py -3 -m http.server 8778`, run `adb reverse tcp:8778 tcp:8778`, install the first APK and
tap Update.

The launcher icon comes from `design/icon/icon.html`; run `.\tools\make-icon.ps1` after
changing it.
