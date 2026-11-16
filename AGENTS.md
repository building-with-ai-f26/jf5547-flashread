# AGENTS.md — Coding Agent Operating Manual

> Give this file to your coding agent and check that it is using these instructions. Keep the stack, commands, and ground rules current.

## 1. Project Overview
- **What this repo builds:** FlashRead, a local web app that shows a text-based academic PDF one word at a time (RSVP) with play, pause, rewind 10 words, and a 150–600 WPM speed slider. An optional button asks OpenRouter for a short summary.
- **Primary user & core workflow:** NYU Stern MBA students with long assigned readings. The living PRD is in `docs/index.html`.
- **Tech stack:** `app/index.html` plus PDF.js 3.11.174 from the cdnjs CDN. `app/serve.ps1` serves it with built-in Windows PowerShell and, only after the summary button is clicked, calls OpenRouter. No database. The Product Page is the static file `docs/index.html`.

## 2. Repository structure
- `app/index.html` — local reader.
- `app/serve.ps1` — local server and the summary proxy.
- `docs/index.html` — public Product Page, PRD, and build log.
- `docs/assets/flashread-build1.png` — real screenshot of the Build 1 reader.
- `docs/assets/posthog-events.png` — real PostHog Activity screenshot from Build 2.
- `AGENTS.md` — this file.
- `README.md` — how to run the app.
- `.env.example` — names the OpenRouter variable. The real `.env` is gitignored.
- `journal/`, `Intent.md`, `Plan.md` — optional notes, not the hand-in.

## 3. Setup and how to run
- **Install dependencies:** none.
- **Product Page:** https://building-with-ai-f26.github.io/jf5547-flashread/ after GitHub Pages deploys `main` / `docs`.
- **Local app:** from the repository root, run `powershell -ExecutionPolicy Bypass -File app\serve.ps1`, then open `http://localhost:8000`.
- **Optional summary:** copy `.env.example` to `.env`, set `OPENROUTER_API_KEY`, restart the server, upload a text PDF, and click **Summarize PDF with AI**.
- **Deterministic tests:** none in the repo. Check the reader in a browser. The Build 1 and Build 2 notes are on the Product Page.
- **Model:** summaries use OpenRouter model `openai/gpt-4o-mini`, capped at 6,000 characters in and 180 output tokens. There is no separate eval script.

## 4. Analytics
PostHog's browser snippet is in `docs/index.html` and `app/index.html`. The token in those files is the public project token. Host: `https://us.i.posthog.com`. Autocapture is off. Each page sends one `$pageview` with `page_type` of `product_page` or `local_app`. The Product Page button sends `clicked_try_product`. The app also sends `pdf_uploaded`, `reading_started`, `reading_paused`, `reading_completed`, `reading_speed_changed`, and, after a successful summary, `ai_summary_completed`. Those events can include speed, word count, page count, model name, and character count. They must not include PDF text, the file name, or the summary text. Session replay starts only after the visitor clicks **Allow recording**. The app masks `#word`, `#summary`, and `#status`.

## 5. AI summary
The button sends extracted words to `POST /api/summarize` on the local server. `serve.ps1` reads `OPENROUTER_API_KEY` from `.env` and calls `https://openrouter.ai/api/v1/chat/completions`. If the key is missing, the button shows a setup message and the reader still works. The key must never be pasted into HTML.

## 6. Testing
1. Start `app/serve.ps1` and open `http://localhost:8000`.
2. Upload a text-based PDF. Confirm the word count, Play, Pause, Rewind 10 words, and the speed slider.
3. Click Summarize. With no key, expect the setup message. With a key, expect one paragraph and no key visible in the page.
4. Open the Product Page, click **See the Product**, and confirm it scrolls to the demo section.
5. In PostHog, look for `$pageview` and `clicked_try_product` from the Product Page, and the reading events from the local app. Allow recording on a test visit before expecting a replay.

## 7. Known limitations
Scanned or outlined PDFs produce no words. Multi-column pages may extract out of order. The place is not saved. PDF.js needs internet. The app is local only. A summary screenshot is not on the Product Page until a real summary succeeds. Session replay is opt-in, and masked text will not show the reading.

## 8. Non-Negotiable Engineering Rules
1. **Plan before coding:** Before touching multiple files, propose a brief plan and wait for approval.
2. **Small batches:** Make small, focused changes that can be reviewed and explained by a human in a single Pull Request.
3. **Explainability:** Avoid unnecessary abstractions or dependencies. Help the human builder understand the main components, what changed, why it matters, what could break, and how it was checked.
4. **Verify changes:** Run relevant checks. For a reproducible logic bug, use a failing test to demonstrate the fix when practical. Record manual checks and known limitations; follow the selected Build 4 evaluation track.
5. **Zero secrets in code:** Never hardcode secret API keys. `OPENROUTER_API_KEY` stays in `.env`. The PostHog value in the HTML files is the public project token and is supposed to be there.
6. **Stop when looping:** If a fix fails twice in a row, stop, summarize what failed, and ask the human before trying a third approach.
