# AGENTS.md — Coding Agent Operating Manual

> Give this file to your coding agent and check that it is using these instructions. Keep the stack, commands, and ground rules current.

## 1. Project Overview
- **What this repo builds:** FlashRead, a local web app that shows a text-based academic PDF one word at a time (RSVP) with play, pause, rewind 10 words, and a 150–600 WPM speed slider.
- **Primary user & core workflow:** NYU Stern MBA students with long assigned readings. See the living PRD in `docs/index.html`.
- **Tech stack:** One static HTML/CSS/JavaScript page (`app/index.html`) + PDF.js 3.11.174 from the cdnjs CDN. Served locally by `app/serve.ps1`, which uses built-in Windows PowerShell. No backend, database, AI model, or API keys.

## 2. Commands
- **Install dependencies:** none.
- **Run locally:** `powershell -ExecutionPolicy Bypass -File app\serve.ps1`, then open `http://localhost:8000`.
- **Run deterministic tests:** none yet; Build 1 was checked manually in the browser. See the Build 1 log in `docs/index.html`.
- **Run model evals:** not applicable; there is no AI model yet.

## 3. Non-Negotiable Engineering Rules
1. **Plan before coding:** Before touching multiple files, propose a brief plan and wait for approval.
2. **Small batches:** Make small, focused changes that can be reviewed and explained by a human in a single Pull Request.
3. **Explainability:** Avoid unnecessary abstractions or dependencies. Help the human builder understand the main components, what changed, why it matters, what could break, and how it was checked.
4. **Verify changes:** Run relevant checks. For a reproducible logic bug, use a failing test to demonstrate the fix when practical. Record manual checks and known limitations; follow the selected Build 4 evaluation track.
5. **Zero secrets in code:** Never hardcode API keys, tokens, or credentials. Always read from environment variables (`.env`) and update `.env.example` when new variables are needed.
6. **Stop when looping:** If a fix fails twice in a row, stop, summarize what failed, and ask the human before trying a third approach.
