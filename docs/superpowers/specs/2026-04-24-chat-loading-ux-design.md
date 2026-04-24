# Chat Loading UX Redesign — Design Spec

**Date:** 2026-04-24
**Scope:** `submodules/frappe_ai/frontend` (primary), `submodules/frappe-ai-agent` (verification only)
**Out of scope:** `submodules/frappe-mcp-server`, message-block rendering (`ToolCallCard` stays as-is), non-loading-related UX.

## Problem

When the user sends a message in the Frappe AI sidebar, three overlapping loading indicators appear at once:

1. An orange "Thinking…" pill in `ChatHeader` next to the title.
2. A standalone 3-animated-dots row in `ChatMessages`, below the last message.
3. A "Connecting to agent…" hint under the input — paired with the textarea being disabled.

This is visually noisy, technically inaccurate ("Connecting to agent…" fires even when the connection is long established), and out of step with every mainstream chat UI, each of which picks a single indicator positioned where the next assistant message will appear. The current structure also ignores the rich contextual `status` events the agent already emits over SSE (`"Thinking"`, tool-specific labels) — these are stored on `metadata.statusText` and never rendered.

## Goals

- One loading indicator, not three.
- Surface the contextual `status` messages the backend already sends (Claude-style).
- Keep the textarea editable throughout the AI turn.
- Offer a real **Stop** button that aborts the in-flight SSE stream (ChatGPT/Claude behavior).
- Preserve the existing `ToolCallCard` render path — it's already useful and unrelated to the loading-indicator problem.

## Non-goals

- Redesigning message bubbles, tool-call cards, or block rendering.
- Changing the SSE event schema or backend emit points (the events we need already exist).
- Supporting Stop in the legacy `frappe.call()` fallback path (that API has no abort hook).

## The Single Idea

The assistant placeholder message becomes the one-and-only loading indicator. It is created the instant the user hits Send, and it morphs through its lifecycle inside the same DOM bubble:

```
T=0   User clicks Send
T=1   Placeholder bubble shows: [· · ·] Thinking…        (status event not yet received)
T=2   status event arrives   → [· · ·] Looking up Bobby Simmons…
T=3   tool_call event fires  → separate ToolCallCard inserted above; bubble now
                                [· · ·] Updating contact…
T=4   content tokens arrive  → dots disappear, bubble renders streamed text in same slot
T=5   done event             → placeholder finalized; Stop → Send
```

No other loading affordances exist anywhere in the UI. Header is clean. Input is clean and editable. The send button swaps to a square "Stop" icon while `isLoading` is true.

## Render Contract for the Placeholder Bubble

The `Message` type gains one optional boolean, `pending`. `MessageBubble` renders the assistant bubble as follows:

| `message.content` | `message.pending` | Rendered output |
|---|---|---|
| empty | `true` | `.frappe-ai-bubble-status` — 3 pulsing dots + italic gray text: `metadata.statusText \|\| "Thinking…"` (logical OR, so empty-string status falls back to "Thinking…") |
| non-empty | anything | normal content/blocks path (statusText ignored) |
| empty | `false` / undefined | nothing (pure empty bubble — transient only; cancelled or errored turns remove the placeholder entirely) |

`pending` is set to `true` when the placeholder is created in `_sendSSE()`, and cleared in any of: first `content` chunk arrival, `done` event, `error` event, abort.

## State Flow (`useChat.ts`)

```
sendMessage(content)
  ├─ isLoading.value = true
  ├─ currentAbort = new AbortController()
  ├─ push user message
  ├─ push placeholder assistant message { content: "", pending: true }
  └─ fetch(agentUrl/api/v1/chat, { signal: currentAbort.signal })
        │
        ├─ status     → placeholder.metadata.statusText = ev.message
        ├─ tool_call  → insert ToolCallCard before placeholder (unchanged)
        ├─ content    → placeholder.content += ev.text; placeholder.pending = false
        ├─ content_block → placeholder.blocks.push(...); placeholder.pending = false
        ├─ done       → placeholder.pending = false; statusText cleared;
        │                 running ToolCallCards → status: "done"
        └─ error      → remove placeholder; add error bubble

cancelMessage()
  └─ currentAbort?.abort()
        │
        └─ fetch rejects with AbortError, caught in _sendSSE:
              ├─ placeholder.content non-empty → placeholder.pending = false (keep partial)
              ├─ placeholder.content empty     → remove placeholder
              ├─ running ToolCallCards → status: "cancelled"
              └─ no error bubble added

finally:
  ├─ currentAbort = null
  └─ isLoading.value = false
```

Exported API from `useChat()` gains `cancelMessage: () => void`.

## Component Changes (`submodules/frappe_ai/frontend/src/`)

### `components/ChatHeader.vue`
- Delete the `<span v-if="isLoading" class="frappe-ai-indicator …">` block (current lines 28-34).
- Remove the `isLoading` prop from `defineProps`.
- The stale comment in `MessageBubble.vue` claiming "the global 'Thinking…' indicator lives in ChatHeader" is also removed (see below).

### `components/ChatMessages.vue`
- Delete the `<div v-if="isStreaming" class="frappe-ai-streaming">…</div>` block (current lines 57-61).
- Remove the `isStreaming` prop from `defineProps`.

### `components/MessageBubble.vue`
- Assistant branch: before the existing blocks/content logic, add the pending-status path:
  ```vue
  <div
    v-if="message.pending && !message.content && (!message.blocks || !message.blocks.length)"
    class="frappe-ai-bubble-status"
  >
    <span class="frappe-ai-bubble-status-dot"></span>
    <span class="frappe-ai-bubble-status-dot"></span>
    <span class="frappe-ai-bubble-status-dot"></span>
    <span class="frappe-ai-bubble-status-text">
      {{ message.metadata?.statusText || "Thinking…" }}
    </span>
  </div>
  ```
- Remove the now-misleading comment at lines 40-42 ("The global 'Thinking…' indicator lives in ChatHeader…").
- Hide the timestamp (`.frappe-ai-bubble-time`) while `pending && !content`, so the placeholder doesn't show a time before the message exists. Reveal it normally once content arrives.

### `components/ChatInput.vue`
- Replace the `disabled: boolean` prop with `busy: boolean`.
- The `<textarea>` is no longer bound to `:disabled`; it is always editable.
- The send button renders one of two states based on `busy`:
  - `busy === false` → existing send icon, emits `@send` (unchanged).
  - `busy === true`  → `.frappe-ai-send-btn--stop` variant with a square icon, emits `@stop`.
- Delete the `<p v-if="disabled" class="frappe-ai-input-hint">Connecting to agent...</p>` line.
- `defineEmits` gains `stop: []`.
- The click handler chooses between `send()` and `emit('stop')` based on `busy`.

### `components/ChatSidebar.vue`
- Stop passing `:is-loading` to `ChatHeader` and `:is-streaming` to `ChatMessages`.
- Replace `:disabled="isLoading"` on `ChatInput` with `:busy="isLoading"`.
- Listen for `@stop="handleStop"` on `ChatInput`; `handleStop` calls the new `cancelMessage()` from `useChat`.
- Destructure `cancelMessage` from the `useChat()` return.

### `composables/useChat.ts`
- Add a module-level `let currentAbort: AbortController | null = null`.
- In `_sendSSE()`:
  - Construct `currentAbort = new AbortController()` before `fetch`.
  - Pass `signal: currentAbort.signal` in the `fetch` options.
  - When pushing the placeholder assistant message, set `pending: true`.
  - On first `content` or `content_block` event, also set `pending: false` on the placeholder.
  - On `done`, set `pending: false` on the placeholder.
  - In `catch`: distinguish `err?.name === "AbortError"`:
    - Partial content present → `pending: false`, keep.
    - Empty → remove placeholder.
    - Mark running tool_calls `status: "cancelled"` (requires adding `"cancelled"` to the tool-call status union in `types/messages.ts`).
    - Do **not** call `_addErrorMessage` for aborts.
  - Non-abort errors keep existing behavior (remove placeholder, add error bubble).
  - In `finally`: `currentAbort = null`.
- Export a new `cancelMessage()` function:
  ```ts
  function cancelMessage(): void {
    currentAbort?.abort();
  }
  ```
- Return `cancelMessage` from `useChat()`.

### `types/messages.ts`
- Add `pending?: boolean` to the `Message` interface.
- Add `"cancelled"` to the tool-call status union type.

### `frappe_ai/public/css/frappe_ai_sidebar.css`
- **Delete** rules: `.frappe-ai-indicator`, `.frappe-ai-indicator--connecting`, `.frappe-ai-indicator-dot`, `.frappe-ai-streaming`, `.frappe-ai-streaming-dot`, `@keyframes frappe-ai-pulse`, `.frappe-ai-input-hint`.
- **Add** rules:
  - `.frappe-ai-bubble-status` — flex row, `gap: 6px`, `align-items: center`, padding matching a normal bubble's text line so the bubble's height doesn't jump when status swaps to content.
  - `.frappe-ai-bubble-status-dot` — 5px circle, muted gray (`#9ca3af`), uses a new `frappe-ai-status-bounce` keyframe: `translateY(0)` → `translateY(-2px)` → `translateY(0)` with opacity `.4 → 1 → .4`, `1.2s infinite ease-in-out`. Three dots, with `animation-delay: 0.15s` on the second and `0.30s` on the third.
  - `.frappe-ai-bubble-status-text` — italic, same muted gray, 12px (one step smaller than the 13px body copy).
  - `.frappe-ai-send-btn--stop` — reuses the existing 36×36 `.frappe-ai-send-btn` footprint and position; centered 10×10 filled square icon (inline SVG), colored with `var(--primary)` so it reads as "active/actionable" the way `.frappe-ai-send-btn--active` does today. Identical hit target so the button doesn't visually shift when it toggles.

## Stop Semantics

- SSE mode (agent URL configured): Stop aborts the fetch. Whatever streamed before the click is preserved. ToolCallCards for tools that started server-side are marked `cancelled` in the UI; the server may still complete the underlying write (see "Agent-side verification"). No error bubble is shown.
- Fallback mode (`frappe.call()`): no Stop button. The button stays as Send and is disabled during the request. This is an intentional honest degradation — `frappe.call` has no abort hook, and pretending to cancel would mislead the user.

## Agent-side Verification

One review item before merge, not a change by default:

- Confirm that the SSE endpoint in `submodules/frappe-ai-agent` terminates its generator cleanly when the HTTP client disconnects (i.e., no orphaned tasks, no exception spam in logs).
- Explicitly accept the policy: **in-flight MCP tool calls are allowed to complete server-side** even after client abort. Partial writes are worse than completed ones for ERPNext docs, so we prefer "let the write finish, just don't stream further updates." If the agent team disagrees, that's a follow-up spec in the agent repo, not this one.

## Testing

Manual test matrix (done in a real ERPNext page with the sidebar open):

- **Empty turn aborted immediately.** Send, click Stop within 100ms, before any SSE event arrives. Expected: placeholder disappears; no error bubble; input still usable.
- **Status-only abort.** Send, wait for "Thinking…" / status to appear, click Stop. Expected: placeholder disappears; no error; no partial content left.
- **Tool-call abort.** Send a prompt that triggers a tool, click Stop while ToolCallCard is "running." Expected: ToolCallCard turns "cancelled"; placeholder removed if no text streamed, else finalized with whatever streamed.
- **Mid-stream abort.** Send, wait for content to start, click Stop. Expected: button flips back to Send; the partial assistant text is kept as a final bubble.
- **Normal completion.** Send, let it finish. Expected: bubble morphs dots → status → text → final content. No indicator elsewhere.
- **Status text overrides default.** Send a prompt that causes the backend to emit a custom status like `"Looking up …"`. Expected: bubble shows that text, not "Thinking…".
- **Fallback mode.** Unset the agent URL setting, send. Expected: Send button disables during request, no Stop icon, old-path response renders. No "Connecting to agent…" line.
- **Queueing.** While the AI is responding, type into the textarea — input must accept characters. (Pressing Enter at that point: currently `sendMessage` guards with `isLoading` and silently ignores; we keep that guard. Users can compose but can't submit until the turn completes. A future enhancement could queue; out of scope here.)
- **Re-open sidebar mid-turn.** Close the sidebar via the × button while AI is working, then re-open. Existing behavior preserved; this redesign doesn't touch sidebar visibility handling.

## Risks

- **Stop race with `done`.** If the user clicks Stop in the tiny window between the last `content` event and the `done` event, `abort()` fires on an already-closing connection. `fetch`'s abort is idempotent and the finally block is idempotent; this is safe, but worth verifying manually.
- **AbortError browser compat.** The `err.name === "AbortError"` check is standard across modern browsers; no action needed, but if the app ever targets older environments, a fallback check on `currentAbort.signal.aborted` inside the catch handles it.
- **Status text wraps in a narrow sidebar.** A long backend status like `"Generating response from gpt-4-turbo-2024-04-09…"` could wrap inside the bubble. Acceptable — we do not truncate, because truncation hides useful info during uncertainty. CSS uses normal wrap.

## Out-of-scope follow-ups (intentionally deferred)

- A message queue so users can submit a second prompt before the first finishes.
- Per-tool contextual labels injected by the agent (e.g., "Searching sales orders…" derived from the tool name). The plumbing exists; refining the strings is an agent-side concern.
- Consolidating `ToolCallCard` with the placeholder bubble so they feel like one unit. The current split is acceptable and non-disruptive.
