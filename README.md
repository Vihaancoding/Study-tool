# Personal AI School

A native macOS (SwiftUI) classroom where **Claude is the teacher and the app is the classroom**.
Claude doesn't just chat: it operates the app through validated tool calls — it opens lessons, draws on a live
whiteboard, launches real quizzes, reads and marks your answers, logs mistakes, and schedules revision.

> **Status — read this first.** The whole code base was written in a Linux sandbox that has no Swift toolchain,
> so **it has not been compiled or run yet**. I checked every file with a Swift syntax parser (no syntax errors) and
> reviewed types by hand, but expect to fix a handful of compile errors the first time you build on a Mac
> (most likely small SwiftUI/type-inference issues). Section [First build](#first-build) tells you how to do that quickly.
> The unit tests in `Tests/StudyCoreTests` cover the logic (board actions, marking, spaced repetition, tool validation,
> planner, persistence) and have also not been run yet.

## Requirements
- macOS 14 (Sonoma) or later, Xcode 15.3+ / Swift 5.9+
- An Anthropic API key (console.anthropic.com). API usage is billed to your Anthropic account, separately from a Claude subscription.

## First build
```bash
swift build            # compile everything; fix any errors it reports
swift test             # run the core-logic tests
./scripts/build_app.sh # produces build/AISchool.app (needed for notifications + aischool:// links)
open build/AISchool.app
```
You can also `open Package.swift` in Xcode and run the `AISchool` scheme. Running with `swift run` works for the UI, but
macOS only allows notifications, login items and URL schemes for a real `.app` bundle, so use `build_app.sh` for those.

If the build reports errors, paste them back to Claude Code and they can be fixed in one pass.

## Setup (2 minutes)
1. Open **Settings** → paste your API key (stored in the macOS Keychain) → *Test connection*.
2. **Subjects** → *Add subject* (pick the type: Science, Mathematics, Humanities, Language…). MYP criteria names A–D are pre-filled.
3. In the subject → **Resources** → *Import files…* (PDF, TXT, MD, RTF, HTML, CSV, and Claude/ChatGPT `conversations.json` exports).
   Use *Organise with Claude* on a syllabus/brief to have Claude add units, topics, objectives and assessments from the text.
4. **Settings → Notifications** → allow notifications, choose briefing time and quiet hours.
5. **Learn** → pick a subject/topic → *Start lesson*.

## How it works
```
┌────────────── SwiftUI app (Sources/AISchool) ──────────────┐
│ Learn: chat ◀──▶ TeacherSession ──▶ Claude Messages API    │
│        board / quiz panes        (tool-use loop, retries)  │
│                │ tool_use                                   │
│                ▼                                            │
│ ToolExecutor (Sources/StudyCore) ── validates every input ──┤
│                ▼                                            │
│ StudyStore  ◀── the same object the UI renders ──▶ JSON on disk
└─────────────────────────────────────────────────────────────┘
```
- **Integration choice:** the app calls the Claude **Messages API with tool use** directly and runs the agent loop itself.
  I chose this over MCP/Claude Desktop because the classroom has to share *live* state with the model (board, quiz, answers)
  and own the UI; an MCP server would add a process boundary without adding capability. The tool layer is isolated in
  `ToolCatalog` / `ToolExecutor`, so exposing the same tools over MCP later is mechanical.
- **Shared state:** tools mutate `StudyStore`; SwiftUI re-renders from it. When Claude draws, the board changes; when you
  submit a quiz, Claude is told and reads your answers with `get_quiz_results`; when a lesson ends the app saves it.
- **Validation:** every tool input is type- and range-checked before anything changes. Whiteboard batches are atomic (one bad
  action rejects the whole batch with a reason Claude can fix). Quiz questions are checked for answer keys, indices,
  blank counts, topic and criterion ids.
- **Failure handling:** network/429/5xx retried with backoff; you can stop/interrupt Claude mid-turn; stored message history is
  repaired after crashes (dangling `tool_use` blocks get error results); unreadable data files are preserved, not overwritten;
  automatic backups on launch and before restores/deletes.
- **Claude can see the board:** `whiteboard_read` returns object data *and* a PNG of the board, so freehand work is visible.

### Tools Claude can call
`get_student_context`, `list_curriculum`, `search_sources`, `read_source`, `get_mistakes`, `open_lesson`, `whiteboard_apply`
(23 action types), `whiteboard_read`, `create_quiz` (8 question types), `get_quiz_results`, `mark_response`, `log_mistake`,
`record_understanding`, `schedule_review`, `curriculum_add`, `save_note`, `end_lesson`.

### Learning model (all derived from stored evidence — nothing invented)
- Quiz results update per-topic spaced repetition (SM-2-style). Failure brings a topic back in ≤1 day.
- **Mastery ≠ one lucky answer:** `Secure` needs ≥3 successful days, ≥80% recent accuracy, and a ≥6-day interval; a single good result is only "unconfirmed".
- Mistakes are logged automatically with category, criterion, correct reasoning and follow-up outcomes; two correct retests resolve one.
- "Today's session" ranks topics by overdue reviews, weak recent accuracy, proximity of linked assessments, and open mistakes — each with a stated reason.
- Source material (`imported`/`student`) is kept separate from `claude`-written notes, which are labelled everywhere. Claude cites sources as `[[src:id#n]]`, rendered as links that open the passage.

### Notifications
Local notifications via `UserNotifications`, scheduled up to 7 days ahead and rebuilt whenever your data changes or the app opens.
macOS delivers them with the window closed. Caps: your daily limit, 90-minute spacing, quiet hours (late-evening items are dropped, not stacked).
Turn on *Open at login* so the schedule refreshes in the background. Content is composed locally from your data at scheduling time (no API call).
Tapping a notification deep-links (`aischool://…`) into the relevant screen. A menu-bar item shows today's priorities, quick quiz and lesson shortcuts.

### Privacy
Data lives in `~/Library/Application Support/PersonalAISchool/` (JSON + `Backups/`). The key is in the Keychain. What is sent to Anthropic, and when,
is described in **Settings → Privacy**, which also lists each transmission made in the current session. Resources/subjects can be excluded from sharing.

## Known limitations (honest list)
- **Not compiled/tested yet** (see top).
- Responses are not streamed token-by-token; text appears when each model step finishes (tool effects appear as they happen).
- Equations render as Unicode math (superscripts, subscripts, Greek, fractions) — not full TeX typesetting.
- Scanned PDFs (no text layer) can't be imported; no OCR. `.docx` isn't supported (export to PDF/RTF/TXT).
- MYP level descriptors aren't bundled (they're school-specific and I won't invent them): paste your rubric into the subject's criteria or import it as a Rubric resource.
- Notification content for future days is computed when scheduled; if you don't open the app (or enable login item) for a week, the queue runs out.
- Rubric marking by Claude is a judgement; the app shows its stated uncertainty rather than implying precision.
- Single local user, no sync between Macs (use Export/Backup).
