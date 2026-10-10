# Landing page

A static page that explains the app and lets people download the APK. It is plain HTML, CSS and a little JavaScript, with no build step and no framework, so it deploys anywhere that serves files.

The product name on it is a placeholder, **ChalkDeck**. Nothing on it is invented: every claim was checked against the app's code on 10 October 2026, there are no prices, no testimonials and no usage figures, and everything that needs a decision from the owner is marked in yellow with the words `FILL IN`.

## Look at it locally

```bash
python -m http.server 8099 --directory landing
```

Then open http://127.0.0.1:8099/. (Opening `index.html` straight from the disk also works, except for the QR code, which needs a web address.)

## Put it online

- **Vercel:** import the repository, set the **Root Directory** to `landing`, leave the framework as **Other** and leave the build command empty. Or from this folder: `npx vercel --prod`.
- **Netlify or Cloudflare Pages:** publish the `landing` folder. The `_headers` file carries the same security headers as `vercel.json`.
- **GitHub Pages or any web server:** copy the contents of `landing` to the site root.

After the first deploy, tell the page where it lives so link previews find the picture:

```bash
node tools/landing-brand.mjs --site https://your-domain.example
```

## Make it yours

| What | How |
|---|---|
| The product name | `node tools/landing-brand.mjs "NewName"` renames it in every file and in `brand.json`. |
| The GitHub repository the download comes from | `node tools/landing-brand.mjs --repo owner/name` |
| The blanks | `node tools/landing-brand.mjs --check` lists every `FILL IN` still on the pages. Fill them in by hand in `index.html` (footer) and `privacy.html`. |
| The link-preview picture | Replace `assets/og.png` with any 1200 by 630 PNG. The current one shows the placeholder name. |
| The draft note on the privacy page | Delete the paragraph that starts with **Draft** once the blanks are filled in. |

## How the download button works

When the page loads it asks GitHub for the latest release of the repository named in the button's link, takes the file ending in `.apk`, and fills in the version, size, release date and SHA-256 checksum from it. The button then points straight at that file. If GitHub cannot be reached (offline, or its hourly limit for anonymous requests), the button keeps pointing at the repository's releases page instead. The repository has to stay public for this to work.

Every release made with `tools/release-app.ps1` shows up on the page by itself. There is nothing to edit.

## Things to know

- **The app does not carry the new name yet.** It installs as "Core Academy" and the file is called `core-academy-<version>.apk`. The page avoids naming the app inside the install steps, so nothing contradicts what people see after installing. Renaming the app itself is a separate change in the Flutter projects.
- **Screens on the page are drawn in HTML** from the app's own colours, type and layout, with made-up names and numbers, and are labelled "Sample data". They are not screenshots.
- **Animations** play by default. They stop for visitors whose system asks for reduced motion, and any visitor can pause them with the button in the top bar or the footer. The choice is kept in the browser (`localStorage`, key `cd-motion`), as is the theme (`cd-theme`).
- **No cookies, no analytics.** The only outside request is to `api.github.com` for the release details, and the page's Content Security Policy allows nothing else.
- **There is no terms page.** Terms need an owner, a place and decisions that are not made yet, and writing them here would mean inventing them.

## What is in the folder

```
index.html            the page
privacy.html          what the app stores and who handles it (a draft with blanks)
favicon.svg, apple-touch-icon.png
robots.txt, vercel.json, _headers
brand.json            the name and repository the rename tool works from
assets/site.css       the page
assets/screens.css    the phone frames and the app screens drawn in HTML
assets/site.js        scroll effects, the demos that replay on the screens, the release lookup
assets/theme.js       runs first: theme and motion preference, so nothing flashes
assets/fonts/         Geist and Geist Mono, subset, with their licence
assets/vendor/        a QR code encoder (MIT), used on desktop to open the page on a phone
assets/THIRD-PARTY.txt  licences for the fonts, the icons and the QR encoder
```

The icons are Phosphor Light, kept in an inline SVG sprite at the end of each page.
