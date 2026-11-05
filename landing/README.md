# Student download page

The public page where new students download the Core Academy app. It is for the students of one tuition: it says what to tap, how to install the app and how to sign in, and nothing else (no feature list, no tutor pitch, no AI talk). Plain HTML, CSS and a little JavaScript, no build step, so it deploys anywhere that serves files.

The page written for tutors (the one that explains and sells the app) is parked in `landing-tutors/` and is not deployed.

## Look at it locally

```bash
python -m http.server 8099 --directory landing
```

Then open http://127.0.0.1:8099/. Opening `index.html` straight from the disk also works, except for the size on the button and the QR code, which need a web address. (A plain `http.server` does not send the security headers from `vercel.json`; to see a Content-Security-Policy mistake, serve the folder with those headers added.)

## Put it online

- **Vercel (what is used):** project `core-academy-landing`, **Root Directory** `landing`, framework **Other**, no build command. Every push to `main` redeploys it.
- **Netlify or Cloudflare Pages:** publish the `landing` folder. The `_headers` file carries the same security headers as `vercel.json`.
- **GitHub Pages or any web server:** copy the contents of `landing` to the site root.

The page's address appears in two places in `index.html` (`og:url` and `og:image`): if the address changes, replace `https://core-academy-landing.vercel.app` there.

## How the download button works

The button links straight to the fixed address `https://github.com/Santosh7131/Core-Academy/releases/latest/download/core-academy.apk`, which always serves the newest release, so a new release needs no edit here. When the page loads it also asks GitHub for the latest release and shows the size of the app file on the button. If GitHub cannot be reached (offline, or its hourly limit for anonymous requests), the button still downloads, it just shows no size. The repository has to stay public.

## Things to know

- **Every statement was checked** when the page was written (5 November 2026): Android 7 or newer (minimum SDK 24 in the built app), Android only, not on the Play Store (the store's page for the app id answers 404), students sign in with the username and PIN their teacher creates, no email address or phone number is needed to sign in, and the app offers new versions by itself. Re-check them if the app changes.
- **Nothing on the page moves.** No animation, no autoplay. Light and dark follow the visitor's system.
- **No cookies, no analytics.** The only outside request is to `api.github.com` for the file size, and the Content Security Policy allows nothing else (no inline styles or scripts either).
- **No privacy page, no contact or owner lines.** They were held back on purpose (the details are not decided and the children's-data wording needs a legal review). They live, with blanks, in `landing-tutors/privacy.html`.
- **The QR code** (desktop only) opens this same page on a phone.
- **The icon** is drawn from the app's own launcher artwork (`app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png`) on the launcher's dark tile.

## What is in the folder

```
index.html              the page
404.html                "That page does not exist", with a button back to the page
favicon-32.png, favicon-192.png, apple-touch-icon.png
robots.txt, vercel.json, _headers
assets/page.css         the page (colours, type and shapes are the app's own)
assets/page.js          the file size on the button, and the QR code on a computer
assets/icon.png         the app icon (320 px)
assets/og.png           the picture shown when the link is shared (1200 by 630)
assets/fonts/           Geist, subset, with its licence
assets/vendor/          a QR code encoder (MIT)
assets/THIRD-PARTY.txt  licences for the font, the icons and the QR encoder
```

The four icons are Phosphor Light, kept in an inline SVG sprite at the top of `index.html`.
