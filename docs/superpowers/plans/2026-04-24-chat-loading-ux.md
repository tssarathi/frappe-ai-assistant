# Chat Loading UX Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-24-chat-loading-ux-design.md`

**Goal:** Replace the three overlapping loading indicators in the Frappe AI chat sidebar with a single morphing placeholder bubble, an editable-throughout textarea, and a real Send↔Stop toggle wired to `AbortController`.

**Architecture:** All code changes live in `submodules/frappe_ai/frontend/`. The SSE agent (`submodules/frappe-ai-agent`) is inspected at the end to confirm graceful client-disconnect, but no code change is planned there. The source of truth for the loading state becomes the assistant placeholder `Message`, carrying a new `pending` flag and reusing the `metadata.statusText` that the backend already emits. Cancellation uses a module-level `AbortController` referenced by a new `cancelMessage()` function exported from `useChat()`.

**Tech Stack:** Vue 3 (`<script setup lang="ts">`), Vite, Vitest + happy-dom + @vue/test-utils, TypeScript 5.7, plain CSS (no framework).

---

## File Map

All paths relative to `submodules/frappe_ai/frontend/`.

**Modified:**
- `src/types/messages.ts` — add `pending?: boolean` to `Message`, add `"cancelled"` to `ToolCall.status`.
- `src/composables/useChat.ts` — `AbortController`, `pending` lifecycle, `cancelMessage()`, `canCancel` ref (true only while an SSE request is in flight), abort-aware catch.
- `src/components/MessageBubble.vue` — in-bubble status block; hide timestamp on empty pending placeholder; remove stale comment.
- `src/components/ChatHeader.vue` — delete `isLoading` pill and prop.
- `src/components/ChatMessages.vue` — delete standalone streaming-dots block and `isStreaming` prop.
- `src/components/ChatInput.vue` — replace `disabled` prop with `busy` + new `canCancel`; textarea always editable; Send↔Stop icon toggle (Stop only when `busy && canCancel`; fallback mode shows Send disabled); emit `stop`; delete hint.
- `src/components/ChatSidebar.vue` — pass `busy` and `canCancel` instead of `disabled`/`is-streaming`/`is-loading`; wire `@stop` to `cancelMessage`.

**Modified (CSS, bundled by the Frappe app, not Vite):**
- `submodules/frappe_ai/frappe_ai/public/css/frappe_ai_sidebar.css` — delete `.frappe-ai-indicator*`, `.frappe-ai-streaming*`, `@keyframes frappe-ai-pulse`, `.frappe-ai-input-hint`. Add `.frappe-ai-bubble-status`, `.frappe-ai-bubble-status-dot`, `.frappe-ai-bubble-status-text`, `@keyframes frappe-ai-status-bounce`, `.frappe-ai-send-btn--stop`.

**Created:**
- `src/composables/__tests__/_mock-sse.ts` — shared SSE fetch mock for `useChat` tests.
- `src/composables/__tests__/useChat.test.ts` — state lifecycle + cancellation tests.
- `src/components/__tests__/MessageBubble.test.ts` — pending-placeholder rendering test.
- `src/components/__tests__/ChatInput.test.ts` — send/stop toggle + emit test.

---

## Development conventions

- **Test runner:** `npm --prefix submodules/frappe_ai/frontend test -- <path>` runs a specific Vitest file. `npm --prefix submodules/frappe_ai/frontend test` runs everything.
- **Build check:** `npm --prefix submodules/frappe_ai/frontend run build` type-checks and bundles. Run after every behavioral task.
- **Git scope:** every commit in this plan touches only files inside `submodules/frappe_ai/`. Because that is a git submodule, commits are made inside it:
  - `cd submodules/frappe_ai && git add … && git commit -m "…"` — then `cd ../..` and `git add submodules/frappe_ai && git commit -m "chore(submodule): bump frappe_ai"` at the end of the feature (Task 12 handles the bumps).
- **Test isolation:** tests stub `globalThis.frappe` and the agent URL; each test cleans up in `afterEach`.

---

## Task 1 — Extend `Message` and `ToolCall` types

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/types/messages.ts:7-34`

Only a type change — no runtime test needed. Correctness is enforced by the type checker as later tasks consume `pending` and `"cancelled"`.

- [ ] **Step 1: Edit `src/types/messages.ts`**

Replace the entire file with:

```ts
/** Message and tool call types for the chat interface. */

import type { ContentBlock } from "./blocks";

export type MessageRole = "user" | "assistant" | "tool_call" | "error";

export interface ToolCall {
  call_id: string;
  name: string;
  arguments: Record<string, unknown>;
  result?: string;
  success?: boolean;
  status: "running" | "done" | "error" | "cancelled";
}

export interface ErrorInfo {
  code: string;
  message: string;
  suggestion?: string;
}

export interface Message {
  id: string;
  role: MessageRole;
  content: string;
  blocks?: ContentBlock[];
  toolCall?: ToolCall;
  error?: ErrorInfo;
  timestamp: Date;
  /**
   * True while the assistant placeholder is waiting for content.
   * Flipped to false on first content chunk, `done`, error, or abort.
   * Used by MessageBubble to render the in-bubble "Thinking…" /
   * contextual-status block.
   */
  pending?: boolean;
  /** SSE-only: transient metadata (thinking status, etc.) */
  metadata?: {
    statusText?: string;
  };
}
```

- [ ] **Step 2: Type-check**

Run: `cd submodules/frappe_ai/frontend && npx vue-tsc --noEmit`
Expected: exits 0 (no new type errors; existing code doesn't read `pending` yet, so no regressions).

- [ ] **Step 3: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/types/messages.ts
git commit -m "types: add Message.pending and ToolCall cancelled status"
```

---

## Task 2 — Create the SSE fetch mock used by `useChat` tests

**Files:**
- Create: `submodules/frappe_ai/frontend/src/composables/__tests__/_mock-sse.ts`

This helper is used by every subsequent `useChat` task. Introduce it once, DRY.

- [ ] **Step 1: Write the helper**

Create `submodules/frappe_ai/frontend/src/composables/__tests__/_mock-sse.ts`:

```ts
/**
 * Test helper: a controllable mock for `globalThis.fetch` that emits
 * SSE-formatted chunks on demand. Supports abort — when the caller
 * aborts the AbortSignal it passed to `fetch`, any in-flight `read()`
 * promise rejects with AbortError, matching real browser behavior.
 */

import { vi, type Mock } from "vitest";

export interface SSEMock {
  fetchMock: Mock;
  /** Push one SSE event (object gets JSON-stringified and prefixed with "data: "). */
  emit: (payload: Record<string, unknown>) => void;
  /** Close the stream normally (reader's next read returns done:true). */
  finish: () => void;
  /** True once the caller's AbortSignal fires. */
  aborted: () => boolean;
}

export function mockSSEFetch(): SSEMock {
  const pending: Uint8Array[] = [];
  let finished = false;
  let wasAborted = false;
  let resolveNext:
    | ((v: { value?: Uint8Array; done: boolean }) => void)
    | null = null;
  let rejectNext: ((e: Error) => void) | null = null;

  const reader = {
    read: () =>
      new Promise<{ value?: Uint8Array; done: boolean }>((resolve, reject) => {
        if (pending.length) {
          resolve({ value: pending.shift()!, done: false });
          return;
        }
        if (finished) {
          resolve({ value: undefined, done: true });
          return;
        }
        resolveNext = resolve;
        rejectNext = reject;
      }),
    releaseLock: () => {},
    cancel: async () => {},
  };

  const fetchMock = vi.fn(async (_url: string, opts: RequestInit = {}) => {
    const signal = opts.signal;
    if (signal) {
      signal.addEventListener("abort", () => {
        wasAborted = true;
        if (rejectNext) {
          const err = new DOMException("aborted", "AbortError");
          rejectNext(err);
          rejectNext = null;
          resolveNext = null;
        }
      });
    }
    return {
      ok: true,
      status: 200,
      body: { getReader: () => reader },
    } as unknown as Response;
  });

  function emit(payload: Record<string, unknown>): void {
    const chunk = new TextEncoder().encode(
      `data: ${JSON.stringify(payload)}\n\n`,
    );
    if (resolveNext) {
      resolveNext({ value: chunk, done: false });
      resolveNext = null;
      rejectNext = null;
    } else {
      pending.push(chunk);
    }
  }

  function finish(): void {
    finished = true;
    if (resolveNext) {
      resolveNext({ value: undefined, done: true });
      resolveNext = null;
      rejectNext = null;
    }
  }

  return { fetchMock, emit, finish, aborted: () => wasAborted };
}
```

- [ ] **Step 2: Sanity-compile**

Run: `cd submodules/frappe_ai/frontend && npx vue-tsc --noEmit`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/composables/__tests__/_mock-sse.ts
git commit -m "test: add SSE fetch mock helper for useChat"
```

---

## Task 3 — Test + implement: `pending` is set on the placeholder and cleared on first content

**Files:**
- Create: `submodules/frappe_ai/frontend/src/composables/__tests__/useChat.test.ts`
- Modify: `submodules/frappe_ai/frontend/src/composables/useChat.ts`

- [ ] **Step 1: Write the failing test**

Create `submodules/frappe_ai/frontend/src/composables/__tests__/useChat.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { nextTick } from "vue";
import { mockSSEFetch } from "./_mock-sse";
import { useChat, setAgentUrl } from "../useChat";

const AGENT_URL = "http://localhost:9999";

beforeEach(() => {
  setAgentUrl(AGENT_URL);
  (globalThis as any).frappe = { session: { user: "test@example.com" } };
});

afterEach(() => {
  vi.restoreAllMocks();
  setAgentUrl("");
});

/** Wait for all queued microtasks to drain. */
async function flush(times = 4) {
  for (let i = 0; i < times; i++) {
    await nextTick();
    await Promise.resolve();
  }
}

describe("useChat — placeholder pending lifecycle", () => {
  it("marks the assistant placeholder as pending until the first content chunk arrives", async () => {
    const { fetchMock, emit, finish } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat();
    chat.sendMessage("hi");
    await flush();

    // placeholder created immediately
    const placeholder = chat.messages.value.find((m) => m.role === "assistant");
    expect(placeholder).toBeDefined();
    expect(placeholder!.pending).toBe(true);
    expect(placeholder!.content).toBe("");

    // status event alone doesn't clear pending
    emit({ type: "status", message: "Thinking" });
    await flush();
    const afterStatus = chat.messages.value.find((m) => m.role === "assistant")!;
    expect(afterStatus.pending).toBe(true);
    expect(afterStatus.metadata?.statusText).toBe("Thinking");

    // first content chunk clears pending
    emit({ type: "content", text: "Hello" });
    await flush();
    const afterContent = chat.messages.value.find((m) => m.role === "assistant")!;
    expect(afterContent.pending).toBe(false);
    expect(afterContent.content).toBe("Hello");

    finish();
    await flush();
  });
});
```

- [ ] **Step 2: Run the test — expect fail**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: FAIL with `expected undefined to be true` (placeholder has no `pending` field yet).

- [ ] **Step 3: Implement — set `pending: true` on placeholder, clear on content**

In `submodules/frappe_ai/frontend/src/composables/useChat.ts`, update `_sendSSE` placeholder push (around line 98-106) — change it to:

```ts
    // Placeholder assistant message that we stream tokens into. It
    // carries `pending: true` so MessageBubble renders the in-bubble
    // "Thinking…" / contextual-status block until the first content
    // chunk arrives (or the stream ends / is aborted).
    const assistantId = crypto.randomUUID();
    messages.value.push({
      id: assistantId,
      role: "assistant",
      content: "",
      blocks: [],
      timestamp: new Date(),
      pending: true,
    });
    messages.value = [...messages.value];
```

Still in the same file, inside `_handleSSEEvent`, update the `content` case (around line 203-209) to clear pending on first chunk:

```ts
      case "content":
        if (ev.text) {
          _updateMessage(assistantId, (m) => {
            m.content += ev.text;
            m.pending = false;
          });
        }
        break;
```

Also update the `content_block` case (around line 211-224) for the same reason:

```ts
      case "content_block":
        // Structured blocks: tables, charts, KPIs, status lists, and
        // text blocks for prose between them. The server parses
        // <copilot-block> tags out of the LLM output and emits one
        // content_block event per block, preserving order.
        if (ev.block && isValidBlock(ev.block)) {
          _updateMessage(assistantId, (m) => {
            if (!m.blocks) {
              m.blocks = [];
            }
            m.blocks.push(ev.block as ContentBlock);
            m.pending = false;
          });
        }
        break;
```

- [ ] **Step 4: Run the test — expect pass**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: PASS (1 test passed).

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/composables/useChat.ts frontend/src/composables/__tests__/useChat.test.ts
git commit -m "feat(useChat): track placeholder pending until first content chunk"
```

---

## Task 4 — Test + implement: `done` event clears `pending` (covers empty-response case)

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/composables/__tests__/useChat.test.ts`
- Modify: `submodules/frappe_ai/frontend/src/composables/useChat.ts`

Edge case: the backend may emit `done` before any `content` (e.g., a pure tool-call turn that ends without a narrative response). `pending` must still clear so the bubble stops showing dots.

- [ ] **Step 1: Add a failing test**

Append inside the same `describe` block in `src/composables/__tests__/useChat.test.ts`:

```ts
  it("clears pending on `done` even when no content chunks arrived", async () => {
    const { fetchMock, emit, finish } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat();
    chat.sendMessage("run a tool and say nothing");
    await flush();

    emit({ type: "status", message: "Thinking" });
    emit({ type: "done" });
    finish();
    await flush();

    const placeholder = chat.messages.value.find((m) => m.role === "assistant")!;
    expect(placeholder.pending).toBe(false);
    expect(placeholder.metadata?.statusText).toBeUndefined();
    expect(chat.isLoading.value).toBe(false);
  });
```

- [ ] **Step 2: Run — expect fail**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: the new test FAILS with `expected true to be false` (pending still true after done).

- [ ] **Step 3: Implement — clear pending on done**

In `submodules/frappe_ai/frontend/src/composables/useChat.ts`, update the `done` case in `_handleSSEEvent` (around line 226-238) to also clear `pending`:

```ts
      case "done":
        // Mark any running tool_calls as done.
        messages.value = messages.value.map((m) => {
          if (m.role === "tool_call" && m.toolCall?.status === "running") {
            return { ...m, toolCall: { ...m.toolCall, status: "done" as const } };
          }
          return m;
        });
        // Finalize the assistant placeholder — clear any transient
        // status and the pending flag so MessageBubble stops showing
        // the in-bubble dots + "Thinking…" block.
        _updateMessage(assistantId, (m) => {
          m.pending = false;
          m.metadata = { ...m.metadata, statusText: undefined };
        });
        break;
```

- [ ] **Step 4: Run — expect pass**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/composables/useChat.ts frontend/src/composables/__tests__/useChat.test.ts
git commit -m "feat(useChat): clear pending and statusText on SSE done event"
```

---

## Task 5 — Test + implement: `cancelMessage()` aborts and preserves partial content

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/composables/__tests__/useChat.test.ts`
- Modify: `submodules/frappe_ai/frontend/src/composables/useChat.ts`

This is the biggest behavior change. Three distinct abort paths:

1. Partial content present → keep the placeholder, clear `pending`.
2. Placeholder still empty → remove it entirely.
3. A `tool_call` was `running` → mark it `"cancelled"`.

In every abort case: `isLoading` becomes false, no error bubble is added.

- [ ] **Step 1: Add three failing tests**

Append inside the same `describe` block in `src/composables/__tests__/useChat.test.ts` (one test per abort scenario):

```ts
  it("cancelMessage with no content streamed removes the placeholder and leaves no error", async () => {
    const { fetchMock, emit } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat() as ReturnType<typeof useChat> & {
      cancelMessage: () => void;
    };
    chat.sendMessage("hi");
    await flush();

    emit({ type: "status", message: "Thinking" });
    await flush();
    expect(chat.messages.value.some((m) => m.role === "assistant")).toBe(true);

    chat.cancelMessage();
    await flush();

    // User message stays; placeholder gone; no error bubble added.
    expect(chat.messages.value.map((m) => m.role)).toEqual(["user"]);
    expect(chat.isLoading.value).toBe(false);
    expect(chat.lastError.value).toBeNull();
  });

  it("cancelMessage mid-stream keeps partial content and clears pending", async () => {
    const { fetchMock, emit } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat() as ReturnType<typeof useChat> & {
      cancelMessage: () => void;
    };
    chat.sendMessage("hi");
    await flush();

    emit({ type: "content", text: "Partial " });
    emit({ type: "content", text: "answer" });
    await flush();

    chat.cancelMessage();
    await flush();

    const assistants = chat.messages.value.filter((m) => m.role === "assistant");
    expect(assistants).toHaveLength(1);
    expect(assistants[0].content).toBe("Partial answer");
    expect(assistants[0].pending).toBe(false);
    expect(chat.isLoading.value).toBe(false);
  });

  it("cancelMessage marks any running tool_call as cancelled", async () => {
    const { fetchMock, emit } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat() as ReturnType<typeof useChat> & {
      cancelMessage: () => void;
    };
    chat.sendMessage("update a doc");
    await flush();

    emit({ type: "tool_call", name: "update_document", arguments: {} });
    await flush();

    chat.cancelMessage();
    await flush();

    const toolMsgs = chat.messages.value.filter((m) => m.role === "tool_call");
    expect(toolMsgs).toHaveLength(1);
    expect(toolMsgs[0].toolCall?.status).toBe("cancelled");
  });

  it("canCancel is true only while the SSE request is in flight", async () => {
    const { fetchMock, emit, finish } = mockSSEFetch();
    vi.stubGlobal("fetch", fetchMock);

    const chat = useChat();
    expect(chat.canCancel.value).toBe(false);

    chat.sendMessage("hi");
    await flush();
    expect(chat.canCancel.value).toBe(true);

    emit({ type: "content", text: "done" });
    emit({ type: "done" });
    finish();
    await flush();

    expect(chat.canCancel.value).toBe(false);
  });
```

- [ ] **Step 2: Run — expect fail**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: the three new tests FAIL (`cancelMessage` does not exist on the object yet).

- [ ] **Step 3: Implement — AbortController plumbing and cancelMessage**

Open `submodules/frappe_ai/frontend/src/composables/useChat.ts`.

**(a)** Add a module-level abort-controller reference near the top, just below `let _agentUrl = "";` (around line 34):

```ts
// Module-level so cancelMessage() can abort the currently-running
// request regardless of which composable instance initiated it.
let _currentAbort: AbortController | null = null;
```

Then add a `canCancel` ref inside `useChat()`, next to `isLoading` (around line 41):

```ts
  // True only while an SSE request is in flight (AbortController
  // exists). Fallback mode (frappe.call()) stays false so ChatInput
  // keeps Send disabled instead of showing a Stop it can't honor.
  const canCancel = ref(false);
```

**(b)** In `_sendSSE`, set up the controller and pass its signal to `fetch`. Replace the current `fetch(...)` call and the surrounding setup (around lines 108-117) with:

```ts
    _currentAbort = new AbortController();
    canCancel.value = true;

    try {
      const resp = await fetch(`${_agentUrl}/api/v1/chat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "text/event-stream",
        },
        credentials: "include",
        body,
        signal: _currentAbort.signal,
      });
```

**(c)** Replace the current `catch`/`finally` of `_sendSSE` (around lines 151-157) with abort-aware handling:

```ts
    } catch (err: any) {
      if (err?.name === "AbortError") {
        // User-initiated cancel. Keep whatever streamed, drop an
        // empty placeholder, mark any running tool_calls as cancelled,
        // and don't surface an error bubble.
        const idx = messages.value.findIndex((m) => m.id === assistantId);
        if (idx >= 0) {
          const placeholder = messages.value[idx];
          const hasContent =
            (placeholder.content && placeholder.content.length > 0) ||
            (placeholder.blocks && placeholder.blocks.length > 0);
          if (hasContent) {
            _updateMessage(assistantId, (m) => {
              m.pending = false;
              m.metadata = { ...m.metadata, statusText: undefined };
            });
          } else {
            _removeMessage(assistantId);
          }
        }
        messages.value = messages.value.map((m) => {
          if (m.role === "tool_call" && m.toolCall?.status === "running") {
            return {
              ...m,
              toolCall: { ...m.toolCall, status: "cancelled" as const },
            };
          }
          return m;
        });
      } else {
        _removeMessage(assistantId);
        _addErrorMessage(err?.message ?? "Stream failed");
      }
    } finally {
      _currentAbort = null;
      canCancel.value = false;
      isLoading.value = false;
    }
```

**(d)** Add the `cancelMessage` function just after `clearMessages` (around line 78):

```ts
  function cancelMessage(): void {
    _currentAbort?.abort();
  }
```

**(e)** Add `cancelMessage` to the returned object at the bottom of `useChat()` (around lines 352-358):

```ts
  return {
    messages: readonly(messages),
    isLoading: readonly(isLoading),
    canCancel: readonly(canCancel),
    lastError: readonly(lastError),
    sendMessage,
    cancelMessage,
    clearMessages,
  };
```

- [ ] **Step 4: Run — expect pass**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/composables/__tests__/useChat.test.ts`
Expected: all five tests PASS.

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/composables/useChat.ts frontend/src/composables/__tests__/useChat.test.ts
git commit -m "feat(useChat): cancelMessage aborts stream and preserves partial content"
```

---

## Task 6 — Test + implement: `MessageBubble` renders the in-bubble status block

**Files:**
- Create: `submodules/frappe_ai/frontend/src/components/__tests__/MessageBubble.test.ts`
- Modify: `submodules/frappe_ai/frontend/src/components/MessageBubble.vue`

- [ ] **Step 1: Write the failing test**

Create `submodules/frappe_ai/frontend/src/components/__tests__/MessageBubble.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { mount } from "@vue/test-utils";
import MessageBubble from "../MessageBubble.vue";
import type { Message } from "@/types/messages";

function assistant(partial: Partial<Message>): Message {
  return {
    id: "x",
    role: "assistant",
    content: "",
    timestamp: new Date("2026-04-24T12:00:00Z"),
    ...partial,
  };
}

describe("MessageBubble — pending placeholder", () => {
  it("shows the status block with default text when pending and empty", () => {
    const wrapper = mount(MessageBubble, {
      props: { message: assistant({ pending: true }) },
    });
    const status = wrapper.find(".frappe-ai-bubble-status");
    expect(status.exists()).toBe(true);
    expect(status.text()).toContain("Thinking");
    // three dots
    expect(wrapper.findAll(".frappe-ai-bubble-status-dot")).toHaveLength(3);
  });

  it("shows backend statusText inside the status block when provided", () => {
    const wrapper = mount(MessageBubble, {
      props: {
        message: assistant({
          pending: true,
          metadata: { statusText: "Looking up Bobby Simmons" },
        }),
      },
    });
    expect(wrapper.find(".frappe-ai-bubble-status").text()).toContain(
      "Looking up Bobby Simmons",
    );
  });

  it("does NOT show the status block once content has streamed in", () => {
    const wrapper = mount(MessageBubble, {
      props: {
        message: assistant({
          pending: false,
          content: "Done.",
        }),
      },
    });
    expect(wrapper.find(".frappe-ai-bubble-status").exists()).toBe(false);
    expect(wrapper.find(".frappe-ai-markdown").exists()).toBe(true);
  });

  it("hides the timestamp while pending and empty", () => {
    const wrapper = mount(MessageBubble, {
      props: { message: assistant({ pending: true }) },
    });
    expect(wrapper.find(".frappe-ai-bubble-time").exists()).toBe(false);
  });

  it("shows the timestamp once content has arrived", () => {
    const wrapper = mount(MessageBubble, {
      props: {
        message: assistant({ pending: false, content: "Hi" }),
      },
    });
    expect(wrapper.find(".frappe-ai-bubble-time").exists()).toBe(true);
  });
});
```

- [ ] **Step 2: Run — expect fail**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/components/__tests__/MessageBubble.test.ts`
Expected: all five tests FAIL (the status block and conditional timestamp don't exist yet).

- [ ] **Step 3: Implement — update `MessageBubble.vue`**

Replace the `<template>` block in `submodules/frappe_ai/frontend/src/components/MessageBubble.vue` with:

```vue
<template>
  <div :class="`frappe-ai-bubble frappe-ai-bubble--${message.role}`">
    <!-- User message -->
    <div v-if="message.role === 'user'" class="frappe-ai-bubble-content">
      {{ message.content }}
    </div>

    <!-- Assistant message. When pending and still empty, show the
         in-bubble "Thinking…" / contextual-status block. As soon as
         content or blocks arrive, fall through to the normal render
         paths. -->
    <div v-else-if="message.role === 'assistant'" class="frappe-ai-bubble-content">
      <div v-if="renderError" class="frappe-ai-error frappe-ai-error--info">
        <div class="frappe-ai-error-message">Could not render response</div>
      </div>
      <template v-else-if="isPendingEmpty">
        <div class="frappe-ai-bubble-status">
          <span class="frappe-ai-bubble-status-dot"></span>
          <span class="frappe-ai-bubble-status-dot"></span>
          <span class="frappe-ai-bubble-status-dot"></span>
          <span class="frappe-ai-bubble-status-text">
            {{ message.metadata?.statusText || "Thinking…" }}
          </span>
        </div>
      </template>
      <template v-else>
        <!-- Structured blocks take priority, rendered in arrival order. -->
        <template v-if="message.blocks && message.blocks.length > 0">
          <component
            v-for="(block, i) in message.blocks"
            :key="i"
            :is="getBlockComponent(block.type)"
            :block="block"
          />
        </template>
        <!-- Plain-text path for simple answers without any blocks. -->
        <!-- eslint-disable-next-line vue/no-v-html -->
        <div
          v-else-if="message.content"
          class="frappe-ai-markdown"
          v-html="renderMarkdown(message.content)"
        />
      </template>
    </div>

    <!-- Error message -->
    <div
      v-else-if="message.role === 'error'"
      :class="`frappe-ai-error frappe-ai-error--${errorSeverity}`"
    >
      <div class="frappe-ai-error-message">{{ message.error?.message }}</div>
      <div v-if="message.error?.suggestion" class="frappe-ai-error-suggestion">
        {{ message.error.suggestion }}
      </div>
    </div>

    <div v-if="!isPendingEmpty" class="frappe-ai-bubble-time">{{ timeStr }}</div>
  </div>
</template>
```

Add the `isPendingEmpty` computed to the `<script setup>` block (just after the existing `timeStr` computed, around line 28-30):

```ts
const isPendingEmpty = computed(
  () =>
    props.message.role === "assistant" &&
    !!props.message.pending &&
    !props.message.content &&
    (!props.message.blocks || props.message.blocks.length === 0),
);
```

- [ ] **Step 4: Run — expect pass**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/components/__tests__/MessageBubble.test.ts`
Expected: all five tests PASS.

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/components/MessageBubble.vue frontend/src/components/__tests__/MessageBubble.test.ts
git commit -m "feat(MessageBubble): render in-bubble status block for pending placeholders"
```

---

## Task 7 — Delete the header "Thinking…" indicator

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/components/ChatHeader.vue`

Direct edit — no automated test. The new `MessageBubble` tests already cover the replacement UX; absence of an element is verified by the manual test matrix in Task 12.

- [ ] **Step 1: Replace the file contents**

Replace `submodules/frappe_ai/frontend/src/components/ChatHeader.vue` with:

```vue
<script setup lang="ts">
const emit = defineEmits<{
  clear: [];
  close: [];
}>();

/** Render a Frappe Lucide icon; falls back to inline SVG in dev mode. */
function frappeIcon(name: string, size: string): string {
  if (typeof frappe !== "undefined" && frappe.utils?.icon) {
    return frappe.utils.icon(name, size);
  }
  return `<svg class="icon icon-${size}"><use href="#icon-${name}"></use></svg>`;
}

declare const frappe: any;
</script>

<template>
  <div class="frappe-ai-header">
    <div class="frappe-ai-header-left">
      <!-- eslint-disable-next-line vue/no-v-html -->
      <span v-html="frappeIcon('message-square-text', 'sm')" />
      <span class="frappe-ai-header-title">Frappe AI</span>
    </div>
    <div class="frappe-ai-header-actions">
      <button class="frappe-ai-icon-btn" title="New conversation" @click="emit('clear')">
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span v-html="frappeIcon('rotate-ccw', 'sm')" />
      </button>
      <button class="frappe-ai-icon-btn" title="Close sidebar" @click="emit('close')">
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span v-html="frappeIcon('x', 'sm')" />
      </button>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Type-check**

Run: `cd submodules/frappe_ai/frontend && npx vue-tsc --noEmit`
Expected: exits 0. (A lingering `isLoading` ref from a consumer will now fail type-check and is fixed in Task 10.)

Note: this command will actually **fail** here because `ChatSidebar.vue` still passes `:is-loading`. That's expected — we tighten the prop type now so the compiler flags the leftover callsite, which Task 10 removes. Proceed even though `vue-tsc` exits non-zero.

- [ ] **Step 3: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/components/ChatHeader.vue
git commit -m "refactor(ChatHeader): remove Thinking indicator and isLoading prop"
```

---

## Task 8 — Delete the standalone streaming-dots block in `ChatMessages.vue`

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/components/ChatMessages.vue`

- [ ] **Step 1: Replace the file contents**

Replace `submodules/frappe_ai/frontend/src/components/ChatMessages.vue` with:

```vue
<script setup lang="ts">
import { ref, watch, nextTick } from "vue";
import MessageBubble from "./MessageBubble.vue";
import ToolCallCard from "./ToolCallCard.vue";
import type { Message } from "@/types/messages";

declare const frappe: any;

function frappeIcon(name: string, size: string): string {
  if (typeof frappe !== "undefined" && frappe.utils?.icon) {
    return frappe.utils.icon(name, size);
  }
  return `<svg class="icon icon-${size}"><use href="#icon-${name}"></use></svg>`;
}

const props = defineProps<{
  messages: readonly Message[];
}>();

const container = ref<HTMLElement>();

watch(
  () => props.messages,
  () => {
    nextTick(() => {
      if (container.value) {
        container.value.scrollTop = container.value.scrollHeight;
      }
    });
  },
  { deep: true },
);
</script>

<template>
  <div ref="container" class="frappe-ai-messages">
    <div v-if="messages.length === 0" class="frappe-ai-empty-state">
      <div class="frappe-ai-empty-icon">
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span v-html="frappeIcon('bot-message-square', 'md')" />
      </div>
      <p class="frappe-ai-empty-title">How can I help?</p>
      <p class="frappe-ai-empty-subtitle">
        Ask me anything about your ERPNext data, or let me help you with tasks.
      </p>
    </div>

    <template v-for="msg in messages" :key="msg.id">
      <ToolCallCard
        v-if="msg.role === 'tool_call' && msg.toolCall"
        :tool-call="msg.toolCall"
      />
      <MessageBubble v-else :message="msg" />
    </template>
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/components/ChatMessages.vue
git commit -m "refactor(ChatMessages): remove standalone streaming dots and isStreaming prop"
```

---

## Task 9 — Test + implement: `ChatInput` busy prop, Send↔Stop toggle, emit `stop`

**Files:**
- Create: `submodules/frappe_ai/frontend/src/components/__tests__/ChatInput.test.ts`
- Modify: `submodules/frappe_ai/frontend/src/components/ChatInput.vue`

- [ ] **Step 1: Write the failing test**

Create `submodules/frappe_ai/frontend/src/components/__tests__/ChatInput.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { mount } from "@vue/test-utils";
import ChatInput from "../ChatInput.vue";

describe("ChatInput — busy / canCancel toggle", () => {
  it("keeps the textarea editable while busy", () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: true },
    });
    const textarea = wrapper.find("textarea");
    expect(textarea.attributes("disabled")).toBeUndefined();
  });

  it("does not render a hint text below the input", () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: true },
    });
    expect(wrapper.find(".frappe-ai-input-hint").exists()).toBe(false);
  });

  it("shows the stop variant when busy && canCancel", () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: true },
    });
    const btn = wrapper.find(".frappe-ai-send-btn");
    expect(btn.classes()).toContain("frappe-ai-send-btn--stop");
    expect(btn.attributes("title")).toBe("Stop generating");
    expect(btn.attributes("disabled")).toBeUndefined();
  });

  it("shows a DISABLED send variant when busy && !canCancel (fallback mode)", () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: false },
    });
    const btn = wrapper.find(".frappe-ai-send-btn");
    expect(btn.classes()).not.toContain("frappe-ai-send-btn--stop");
    expect(btn.attributes("disabled")).toBeDefined();
    expect(btn.attributes("title")).toBe("Send message");
  });

  it("shows the send variant when idle", () => {
    const wrapper = mount(ChatInput, {
      props: { busy: false, canCancel: false },
    });
    const btn = wrapper.find(".frappe-ai-send-btn");
    expect(btn.classes()).not.toContain("frappe-ai-send-btn--stop");
    expect(btn.attributes("title")).toBe("Send message");
  });

  it("emits 'stop' when the button is clicked while busy && canCancel", async () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: true },
    });
    await wrapper.find(".frappe-ai-send-btn").trigger("click");
    expect(wrapper.emitted("stop")).toHaveLength(1);
    expect(wrapper.emitted("send")).toBeUndefined();
  });

  it("emits neither 'stop' nor 'send' when clicked while busy && !canCancel", async () => {
    const wrapper = mount(ChatInput, {
      props: { busy: true, canCancel: false },
    });
    await wrapper.find("textarea").setValue("queued text");
    await wrapper.find(".frappe-ai-send-btn").trigger("click");
    expect(wrapper.emitted("stop")).toBeUndefined();
    expect(wrapper.emitted("send")).toBeUndefined();
  });

  it("emits 'send' with the trimmed text when the button is clicked while idle", async () => {
    const wrapper = mount(ChatInput, {
      props: { busy: false, canCancel: false },
    });
    await wrapper.find("textarea").setValue("  hi there  ");
    await wrapper.find(".frappe-ai-send-btn").trigger("click");
    expect(wrapper.emitted("send")?.[0]).toEqual(["hi there"]);
  });
});
```

- [ ] **Step 2: Run — expect fail**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/components/__tests__/ChatInput.test.ts`
Expected: all six tests FAIL (`busy` prop doesn't exist, stop variant absent, hint still present).

- [ ] **Step 3: Implement — replace `ChatInput.vue`**

Replace `submodules/frappe_ai/frontend/src/components/ChatInput.vue` with:

```vue
<template>
  <div class="frappe-ai-input-area">
    <div class="frappe-ai-input-row">
      <div class="frappe-ai-input-wrapper">
        <textarea
          ref="inputEl"
          v-model="text"
          class="frappe-ai-textarea"
          rows="1"
          placeholder="Ask anything..."
          @keydown="handleKeydown"
          @input="autoResize"
        />
      </div>
      <button
        :class="[
          'frappe-ai-send-btn',
          showStop
            ? 'frappe-ai-send-btn--stop'
            : text.trim()
            ? 'frappe-ai-send-btn--active'
            : '',
        ]"
        :disabled="sendDisabled"
        :title="showStop ? 'Stop generating' : 'Send message'"
        @click="onButtonClick"
      >
        <span v-if="showStop" class="frappe-ai-stop-icon" aria-hidden="true"></span>
        <!-- eslint-disable-next-line vue/no-v-html -->
        <span v-else v-html="frappeIcon('send-horizontal', 'sm')" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, nextTick } from "vue";

declare const frappe: any;

const props = defineProps<{
  /** An assistant turn is currently in flight (SSE or fallback). */
  busy: boolean;
  /** The in-flight turn can actually be cancelled (SSE path only). */
  canCancel: boolean;
}>();
const emit = defineEmits<{
  send: [content: string];
  stop: [];
}>();

const text = ref("");
const inputEl = ref<HTMLTextAreaElement>();

/** Stop button is shown only when busy AND cancel is possible. */
const showStop = computed(() => props.busy && props.canCancel);

/**
 * Send button is disabled when:
 *   - busy in fallback mode (can't cancel, can't queue)  — spec says "stays as Send and is disabled"
 *   - idle but no text typed
 * It is enabled when:
 *   - showStop (so the user can click to abort)
 *   - idle with non-empty text
 */
const sendDisabled = computed(() => {
  if (showStop.value) return false;
  if (props.busy) return true; // fallback busy: disabled Send
  return !text.value.trim();
});

function frappeIcon(name: string, size: string): string {
  if (typeof frappe !== "undefined" && frappe.utils?.icon) {
    return frappe.utils.icon(name, size);
  }
  return `<svg class="icon icon-${size}"><use href="#icon-${name}"></use></svg>`;
}

function onButtonClick() {
  if (showStop.value) {
    emit("stop");
    return;
  }
  if (props.busy) return; // fallback-busy click: no-op (button is also disabled)
  send();
}

function send() {
  const content = text.value.trim();
  if (!content) return;
  emit("send", content);
  text.value = "";
  nextTick(() => {
    if (inputEl.value) inputEl.value.style.height = "auto";
  });
}

function handleKeydown(e: KeyboardEvent) {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    // Enter while busy is a no-op in either mode. We don't repurpose
    // Enter to mean "stop" because it's too easy to hit by accident
    // while typing the next message.
    if (!props.busy) send();
  }
}

function autoResize() {
  const el = inputEl.value;
  if (!el) return;
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 160) + "px";
}
</script>
```

- [ ] **Step 4: Run — expect pass**

Run: `cd submodules/frappe_ai/frontend && npm test -- src/components/__tests__/ChatInput.test.ts`
Expected: all six tests PASS.

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/components/ChatInput.vue frontend/src/components/__tests__/ChatInput.test.ts
git commit -m "feat(ChatInput): busy prop, Send↔Stop toggle, always-editable textarea"
```

---

## Task 10 — Rewire `ChatSidebar.vue` to the new contracts

**Files:**
- Modify: `submodules/frappe_ai/frontend/src/components/ChatSidebar.vue`

This task removes the now-dead props and wires the new `@stop` event to `cancelMessage`. After this task, `vue-tsc` must pass clean.

- [ ] **Step 1: Replace the file contents**

Replace `submodules/frappe_ai/frontend/src/components/ChatSidebar.vue` with:

```vue
<script setup lang="ts">
import { useChat } from "@/composables/useChat";
import ChatHeader from "./ChatHeader.vue";
import ChatMessages from "./ChatMessages.vue";
import ChatInput from "./ChatInput.vue";

defineProps<{
  sidebarWidth: number;
  keyboardShortcut: string;
  visible: boolean;
}>();

const emit = defineEmits<{ close: [] }>();

const {
  messages,
  isLoading,
  canCancel,
  sendMessage,
  cancelMessage,
  clearMessages,
} = useChat();

function handleSend(content: string) {
  sendMessage(content);
}

function handleStop() {
  cancelMessage();
}

function handleClear() {
  clearMessages();
}

function handleClose() {
  emit("close");
}
</script>

<template>
  <div
    v-if="visible"
    class="frappe-ai-sidebar"
    :style="{ width: sidebarWidth + 'px' }"
  >
    <ChatHeader @clear="handleClear" @close="handleClose" />
    <ChatMessages :messages="messages" />
    <ChatInput
      :busy="isLoading"
      :can-cancel="canCancel"
      @send="handleSend"
      @stop="handleStop"
    />
  </div>
</template>
```

- [ ] **Step 2: Full type-check**

Run: `cd submodules/frappe_ai/frontend && npx vue-tsc --noEmit`
Expected: exits 0.

- [ ] **Step 3: Run the full test suite**

Run: `cd submodules/frappe_ai/frontend && npm test`
Expected: all tests PASS (the tests from Tasks 3, 4, 5, 6, 9 all green).

- [ ] **Step 4: Build**

Run: `cd submodules/frappe_ai/frontend && npm run build`
Expected: exits 0; `dist/` (or the configured output) regenerated; `scripts/update-hooks.js` runs cleanly.

- [ ] **Step 5: Commit**

```bash
cd submodules/frappe_ai
git add frontend/src/components/ChatSidebar.vue
git commit -m "refactor(ChatSidebar): wire busy + stop; drop legacy loading props"
```

---

## Task 11 — CSS swap: delete old indicator rules, add new bubble-status + stop-button rules

**Files:**
- Modify: `submodules/frappe_ai/frappe_ai/public/css/frappe_ai_sidebar.css`

- [ ] **Step 1: Delete the old rules**

Open `submodules/frappe_ai/frappe_ai/public/css/frappe_ai_sidebar.css`. Delete these rule blocks entirely (ranges taken from the current file; re-check by searching the selector):

1. `.frappe-ai-indicator` (around line 132).
2. `.frappe-ai-indicator--connecting` (around line 148).
3. `.frappe-ai-indicator-dot` (around line 163).
4. `.frappe-ai-streaming` (around line 424).
5. `.frappe-ai-streaming-dot` (around line 431) and any related `.frappe-ai-streaming-dot:nth-child(...)` rules.
6. `@keyframes frappe-ai-pulse` (around line 447).
7. `.frappe-ai-input-hint` (around line 541).

- [ ] **Step 2: Add the new rules**

Append at the end of `frappe_ai_sidebar.css`:

```css
/* ─── In-bubble status block (replaces header "Thinking…" pill
       and the standalone streaming-dots row) ─── */

#frappe-ai-sidebar-root .frappe-ai-bubble-status {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 2px 0;
  line-height: 1.5;
}

#frappe-ai-sidebar-root .frappe-ai-bubble-status-dot {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: #9ca3af;
  display: inline-block;
  animation: frappe-ai-status-bounce 1.2s infinite ease-in-out;
}

#frappe-ai-sidebar-root .frappe-ai-bubble-status-dot:nth-child(2) {
  animation-delay: 0.15s;
}

#frappe-ai-sidebar-root .frappe-ai-bubble-status-dot:nth-child(3) {
  animation-delay: 0.30s;
}

#frappe-ai-sidebar-root .frappe-ai-bubble-status-text {
  font-size: 12px;
  font-style: italic;
  color: #6b7280;
}

@keyframes frappe-ai-status-bounce {
  0%,
  60%,
  100% {
    transform: translateY(0);
    opacity: 0.4;
  }
  30% {
    transform: translateY(-2px);
    opacity: 1;
  }
}

/* ─── Stop variant of the send button (active during an in-flight
       SSE turn; same 36×36 footprint as the default send button) ─── */

#frappe-ai-sidebar-root .frappe-ai-send-btn--stop {
  color: var(--primary);
}

#frappe-ai-sidebar-root .frappe-ai-send-btn--stop .frappe-ai-stop-icon {
  display: inline-block;
  width: 10px;
  height: 10px;
  background: currentColor;
  border-radius: 2px;
}
```

- [ ] **Step 3: Commit**

```bash
cd submodules/frappe_ai
git add frappe_ai/public/css/frappe_ai_sidebar.css
git commit -m "style(sidebar): swap loading indicator rules for in-bubble status + stop btn"
```

---

## Task 12 — Manual verification, agent disconnect check, and submodule bump

**Files:**
- No new code. Execute the manual test matrix in a running stack.

- [ ] **Step 1: Rebuild the frontend bundle**

Run: `cd submodules/frappe_ai/frontend && npm run build`
Expected: exits 0.

- [ ] **Step 2: Restart the Frappe site so it picks up new JS + CSS**

The exact command depends on the local dev setup. Typical options:

- **Docker Compose dev stack** (this repo's `docker-compose.yml`):
  `docker compose exec backend bench --site sitename.local clear-cache && docker compose restart backend`
- **Bare-metal bench:** `bench --site <site> clear-cache && bench restart`

Either way: hard-reload the browser (⌘-Shift-R on macOS) so the new `frappe_ai_sidebar.css` is fetched.

- [ ] **Step 3: Execute the manual test matrix from the spec**

Open any ERPNext page that triggers the sidebar (e.g., `/app/customer/Bobby Simmons`) and work through each row in the spec's *Testing* section (`docs/superpowers/specs/2026-04-24-chat-loading-ux-design.md`). For each row, record PASS/FAIL in a scratch note:

1. Empty turn aborted immediately → PASS when placeholder disappears, no error bubble, input still usable.
2. Status-only abort → PASS when placeholder disappears and no partial content left.
3. Tool-call abort → PASS when `ToolCallCard` shows "cancelled" (or the equivalent styled state; verify the CSS renders it) and placeholder is finalized appropriately.
4. Mid-stream abort → PASS when partial text is retained as a finalized bubble.
5. Normal completion → PASS when bubble morphs dots → status → text.
6. Status text overrides default → PASS; send a prompt that causes the backend to emit a custom `status` message and confirm the bubble shows it.
7. Fallback mode → PASS; unset the agent URL setting and confirm Send stays disabled during the request and no "Connecting to agent…" text appears.
8. Queueing → PASS; while AI is responding, type into the textarea and confirm characters appear (Enter is a no-op).
9. Re-open sidebar mid-turn → PASS; unchanged behavior.

If any row fails: stop, open the spec, diagnose, and adjust the relevant task above. Reopen this task once fixed.

- [ ] **Step 4: Agent-side disconnect check (verification only, no code change expected)**

With the stack running and SSE logs visible (`docker compose logs -f frappe-ai-agent` or equivalent):

1. Send a prompt that takes at least ~3 seconds.
2. Click Stop mid-stream.
3. Inspect the agent logs. Expected: clean generator termination (no traceback, no "ResponseClosedError"-style spam). A single info log about client disconnect is acceptable.
4. If tools were in-flight at abort: confirm the tool call still completes server-side (expected and acceptable per the spec). A half-written doc would be a problem; a fully-written one is fine.

If the agent logs show uncaught exceptions or orphaned tasks: record the finding in a follow-up issue against `submodules/frappe-ai-agent` and leave this plan's scope as-is — the FE work is still correct; the BE fix is a separate spec per the design doc's "Agent-side verification" section.

- [ ] **Step 5: Bump the submodule pointer in the outer repo**

```bash
cd /Users/sarathi/Documents/GitHub/frappe-ai-assistant
git add submodules/frappe_ai
git commit -m "chore(submodule): bump frappe_ai (chat loading UX redesign)"
```

- [ ] **Step 6: Final sanity run**

From the repo root:

```bash
cd /Users/sarathi/Documents/GitHub/frappe-ai-assistant
git log --oneline -8
git submodule status
```

Expected: the new bump commit is at HEAD on `main`; `submodules/frappe_ai` points at the new commit that contains Tasks 1-11; no other submodules changed.

---

## Summary of commits (inside `submodules/frappe_ai`)

1. `types: add Message.pending and ToolCall cancelled status`
2. `test: add SSE fetch mock helper for useChat`
3. `feat(useChat): track placeholder pending until first content chunk`
4. `feat(useChat): clear pending and statusText on SSE done event`
5. `feat(useChat): cancelMessage aborts stream and preserves partial content`
6. `feat(MessageBubble): render in-bubble status block for pending placeholders`
7. `refactor(ChatHeader): remove Thinking indicator and isLoading prop`
8. `refactor(ChatMessages): remove standalone streaming dots and isStreaming prop`
9. `feat(ChatInput): busy prop, Send↔Stop toggle, always-editable textarea`
10. `refactor(ChatSidebar): wire busy + stop; drop legacy loading props`
11. `style(sidebar): swap loading indicator rules for in-bubble status + stop btn`

Plus, in the outer repo: `chore(submodule): bump frappe_ai (chat loading UX redesign)`.
