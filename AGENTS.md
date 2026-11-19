# AGENTS.md — Coding Agent Operating Manual

> Give this file to your coding agent and check that it is using these instructions. Keep the stack, commands, and ground rules current.

## 1. Project Overview
- **What this repo builds:** FlashRead, a web app for a text-based academic PDF. After one upload the student can speed-read the document, generate an AI summary and speed-read that, or play a short local narration. Each mode can request a five-question quiz from the original text. Speed reading keeps play, pause, rewind 10 words, a scrubber, and a 150–600 WPM slider, and shows percent, page, time left, surrounding text, and a small page of the current PDF page with the current word highlighted. Speed reading is also published at `docs/demo/`. Summary, quiz, and podcast stay on the local server.
- **Primary user & core workflow:** NYU Stern MBA students with long assigned readings. The living PRD is in `docs/index.html`.
- **Tech stack:** `app/index.html` plus PDF.js 3.11.174 from the cdnjs CDN. `app/serve.ps1` serves it with built-in Windows PowerShell and, only after the summary button is clicked, calls OpenRouter. No database. The Product Page is the static file `docs/index.html`.

## 2. Repository structure
- `app/index.html` — local reader.
- `app/serve.ps1` — local server and the summary proxy.
- `docs/index.html` — public Product Page, PRD, and build log.
- `docs/demo/index.html` — public speed-reading copy of `app/index.html`. Recopy it when the reader changes. `docs/demo/media/home.mp4` is the homepage video.
- `docs/assets/flashread-build1.png` — real screenshot of the Build 1 reader.
- `docs/assets/flashread-build3.png` — real screenshot of the Build 3 reader on a 79-word PDF.
- `docs/assets/flashread-home.png` — real screenshot of the video homepage.
- `docs/assets/flashread-side-page.png` — real screenshot of the side page. The words in it were typed into the reader, not extracted from a PDF.
- `docs/assets/posthog-events.png` — real PostHog Activity screenshot from Build 2.
- `app/media/home.mp4` — homepage video served by the local app.
- `AGENTS.md` — this file.
- `README.md` — how to run the app.
- `.env.example` — names the OpenRouter variable. The real `.env` is gitignored.
- `journal/`, `Intent.md`, `Plan.md` — optional notes, not the hand-in.

## 3. Setup and how to run
- **Install dependencies:** none.
- **Product Page:** https://building-with-ai-f26.github.io/jf5547-flashread/ after GitHub Pages deploys `main` / `docs`.
- **Public speed reading:** https://building-with-ai-f26.github.io/jf5547-flashread/demo/ . Summary, quiz, and podcast on that page tell the visitor to use the local app.
- **Local app:** from the repository root, run `powershell -ExecutionPolicy Bypass -File app\serve.ps1`, then open `http://localhost:8000`.
- **Optional AI:** copy `.env.example` to `.env`, set `OPENROUTER_API_KEY`, restart the server, upload a text PDF, then click **Generate Summary**, **Generate Podcast**, or **Test My Understanding**. Speed reading works with no key.
- **Deterministic tests:** none in the repo. Check the reader in a browser. The build notes are on the Product Page.
- **Model:** OpenRouter model `openai/gpt-4o-mini`. A summary considers at most about 24,000 characters (up to three chunks plus one combine) and 500 final tokens. A quiz or podcast script sends at most 12,000 characters. The narration WAV is Windows speech on this computer, saved under `app/narration/`, and is not a cloud voice. There is no separate eval script.

## 4. Analytics
PostHog's browser snippet is in `docs/index.html` and `app/index.html`. The token in those files is the public project token. Host: `https://us.i.posthog.com`. Project ID: `723597`. Autocapture is off. Do not call `posthog.init` a second time. Each page sends one `$pageview` with `page_type` of `product_page` or `local_app`. The Product Page button sends `clicked_try_product`. The app sends `pdf_uploaded`, `mode_selected`, `reading_started`, `reading_paused`, `reading_completed`, `reading_speed_changed`, `summary_generated`, `ai_summary_completed`, `podcast_generated`, `quiz_started`, and `quiz_completed` only after the matching action succeeds. Properties can include mode, speed, word count, page count, score, model name, and character count. They must not include PDF text, the file name, a document title, the summary, the narration script, or the quiz text. Session replay starts only after the visitor clicks **Allow recording**. The app masks the current word, context, summary, quiz, and status.

## 5. AI summary, quiz, and narration
The buttons send extracted words to `POST /api/summarize`, `POST /api/quiz`, or `POST /api/podcast` on the local server. `serve.ps1` reads `OPENROUTER_API_KEY` from `.env`, then from the process environment, and calls `https://openrouter.ai/api/v1/chat/completions`. If the key is missing, the button shows a setup message and speed reading still works. The key must never be pasted into HTML. Nothing is sent until the student clicks, and ordinary speed reading stays on this computer. Podcast audio is produced only after a script returns, using Windows speech. Long documents are cut off, and the page says when the beginning was the only part sent.

## 6. Testing
1. Start `app/serve.ps1` and open `http://localhost:8000`.
2. Upload a text-based PDF. Choose Speed Read. Confirm percent, page, time left, Play, Pause, Rewind 10 words, the scrubber, and the speed slider. The current word should be highlighted in the surrounding text.
3. Open Summary, Podcast, and Test My Understanding. With no key, expect the setup message and no invented summary, quiz, or audio. With a key, expect a summary that can be speed-read, a playable WAV labeled as the Windows voice, and five scored questions from the original PDF. The key must not appear on the page.
4. Open the Product Page, click **See the Product**, and confirm it opens the public speed-reading demo. Confirm the side page highlights the current word and that **Hide page** removes it.
5. In PostHog, look for `$pageview` and `clicked_try_product` from the Product Page, and the reading events from the local app. Allow recording on a test visit before expecting a replay.

## 7. Known limitations
Scanned or outlined PDFs produce no words. Multi-column pages may extract out of order. The reading position for a document is stored in this browser as a number and restored on the next upload of that same PDF. It is not sent to PostHog. Line-break hyphens are joined when the next fragment starts with a lowercase letter. The surrounding text marks the PDF page. PDF.js needs internet. Speed reading is public at the demo URL above. Summary, quiz, and narration still need the local server and an OpenRouter key. A live model reply has not succeeded, so those results are not on the Product Page. Podcast audio uses the Windows voice and is not a cloud podcast. Session replay is opt-in, and masked text will not show the reading, summary, or quiz.

## 8. Non-Negotiable Engineering Rules
1. **Plan before coding:** Before touching multiple files, propose a brief plan and wait for approval.
2. **Small batches:** Make small, focused changes that can be reviewed and explained by a human in a single Pull Request.
3. **Explainability:** Avoid unnecessary abstractions or dependencies. Help the human builder understand the main components, what changed, why it matters, what could break, and how it was checked.
4. **Verify changes:** Run relevant checks. For a reproducible logic bug, use a failing test to demonstrate the fix when practical. Record manual checks and known limitations; follow the selected Build 4 evaluation track.
5. **Zero secrets in code:** Never hardcode secret API keys. `OPENROUTER_API_KEY` stays in `.env`. The PostHog value in the HTML files is the public project token and is supposed to be there.
6. **Stop when looping:** If a fix fails twice in a row, stop, summarize what failed, and ask the human before trying a third approach.
