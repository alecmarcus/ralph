# Ghosti Implementation Tickets

For high level details, see ARCHITECTURE.md and PLAN.md. Also see DESIGN-SYSTEM.md for details on ds architecture.

## Dependency Graph: Critical Path

```
GH-001 ──► GH-002 ──► GH-003 ──► GH-005 ──► GH-006 ──► GH-008 ──► GH-010
  │           │           │                       │           │
  │           ▼           ▼                       ▼           ▼
  │        GH-004      GH-007                  GH-009      GH-011 ──► GH-012
  │                                                                      │
  ▼                                                                      ▼
GH-013 ──► GH-014 ──► GH-015                                         GH-016
                         │
                         ▼
                       GH-017 ──► GH-018 ──► GH-019
                                                │
                                                ▼
                       GH-020 ──► GH-021 ──► GH-022 ──► GH-023
                                                           │
                                                           ▼
                       GH-024 ──► GH-025 ──► GH-026 ──► GH-027
                                                           │
                                                           ▼
                       GH-028 ──► GH-029 ──► GH-030
                                    │
                                    ▼
                       GH-031 ──► GH-032 ──► GH-033 ──► GH-034
                                                           │
                                                           ▼
                       GH-035 ──► GH-036 ──► GH-037 ──► GH-038
                                                           │
                                                           ▼
                       GH-039 ──► GH-040 ──► GH-041
                                    │
                                    ▼
                       GH-042 ──► GH-043 ──► GH-044 ──► GH-045
                                                           │
                                                           ▼
                       GH-046 ──► GH-047 ──► GH-048
                                    │
                                    ▼
                                 GH-049 ──► GH-050 ──► GH-051 ──► GH-052

CRITICAL PATH (longest chain):
GH-001 → GH-002 → GH-003 → GH-005 → GH-006 → GH-008 → GH-010 → GH-011 →
GH-012 → GH-017 → GH-018 → GH-019 → GH-022 → GH-023 → GH-027 → GH-034
```

### Phase dependency summary

```
Phase 1 (Scaffold + Chat):       GH-001 through GH-012
Phase 2 (Code Execution):        GH-013 through GH-016
Phase 3 (DS Index + Read Tools): GH-017 through GH-023
Phase 4 (Usage + Local Context): GH-024 through GH-027
Phase 5 (Vestige Integration):   GH-028 through GH-034
Phase 6 (Skills + Hooks):        GH-035 through GH-038
Phase 7 (JIT Affordances):       GH-039 through GH-041
Phase 8 (Polish + Enterprise):   GH-042 through GH-052

Cross-cutting (woven into phases):
  Design System Tokens:    GH-004 (Phase 1, feeds all UI tickets)
  Server Abstraction:      GH-009 (Phase 1, feeds GH-028+)
  Accessibility:           GH-046 (Phase 8, depends on all UI)
  Security:                GH-047 (Phase 8, depends on GH-013)
  Multimodal:              GH-042 through GH-045 (Phase 8)
```

---

## Phase 1: Scaffold + Chat

---

### GH-001: Project scaffold -- manifest, package.json, tsconfig, Bun build

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** None
**Estimated Complexity:** M

**Description:**
Initialize the Ghosti project at `/Users/am/Developer/figma/ghosti/`. Create the Figma plugin manifest, package.json with all dependencies, tsconfig for the dual-target setup (plugin sandbox = no DOM; UI iframe = DOM), bunfig.toml for the build, and the directory tree. The build must produce `dist/code.js` (plugin sandbox) and `dist/ui.html` (UI iframe) from separate entry points.

**Key decisions:**
- `manifest.json` needs `"networkAccess": { "allowedDomains": ["api.anthropic.com", "localhost", "*"] }` to support both Claude API and Vestige (user-configurable domain).
- `"capabilities": ["codegen"]` is required for `figma.codegen` if used later.
- Two tsconfig layers: a base, and per-target overrides (sandbox target = `"lib": ["ES2022"]`, UI target = `"lib": ["ES2022", "DOM"]`).
- Bun build script: two entry points, HTML inline bundling for the UI.

**Files to create:**
- `ghosti/manifest.json`
- `ghosti/package.json`
- `ghosti/tsconfig.json`
- `ghosti/tsconfig.plugin.json`
- `ghosti/tsconfig.ui.json`
- `ghosti/bunfig.toml`
- `ghosti/build.ts` (Bun build script)
- `ghosti/.ghosti/GHOSTI.md` (minimal placeholder)
- `ghosti/.ghosti/settings.json` (defaults)
- `ghosti/src/plugin/code.ts` (minimal: `figma.showUI(__html__, { width: 360, height: 600 })`)
- `ghosti/src/ui/ui.html` (minimal shell)
- `ghosti/src/ui/index.ts` (minimal entry)

**Acceptance Criteria:**
- `bun run build` produces `dist/code.js` and `dist/ui.html` without errors.
- Plugin loads in Figma via Plugins > Development > Import from manifest.
- UI panel appears (can be blank).

---

### GH-002: Shared protocol -- message types between sandbox and UI

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-001
**Estimated Complexity:** S

**Description:**
Define the strongly-typed message protocol used by `postMessage` between the plugin sandbox (`code.ts`) and the UI iframe. This is the contract that every feature depends on. Use discriminated unions with a `type` field.

**Message categories to define:**
- `ui-ready` -- UI loaded, sandbox can send initial state
- `selection-changed` -- sandbox notifies UI of selection changes
- `execute-code` -- UI asks sandbox to eval code
- `execution-result` -- sandbox returns result/error
- `read-node` / `read-selection` / `read-page` / `read-styles` / `read-variables` / `read-components` -- context reads
- `context-response` -- sandbox returns context data
- `search-request` / `search-result` -- fuzzy search
- `notify` -- UI asks sandbox to show a Figma toast
- `resize-ui` -- UI requests panel resize

Each message type must have a unique string literal `type`, a typed `payload`, and an optional `requestId` for request/response correlation.

**Files to create:**
- `ghosti/src/shared/protocol.ts`

**Acceptance Criteria:**
- All message types are exported as TypeScript discriminated unions.
- Both `PluginMessage` (sandbox-to-UI) and `UIMessage` (UI-to-sandbox) union types exist.
- A `MessageMap` type allows type-safe handlers.
- No runtime dependencies (types only, with string literal constants).

---

### GH-003: Bridge service -- type-safe postMessage wrapper

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-002
**Estimated Complexity:** M

**Description:**
Build the communication bridge for both sides. On the UI side, a `BridgeService` class wraps `parent.postMessage` and `window.addEventListener('message', ...)`. On the sandbox side, a `SandboxBridge` wraps `figma.ui.postMessage` and `figma.ui.on('message', ...)`. Both must provide:

1. `send(message)` -- type-safe, fire-and-forget.
2. `request(message): Promise<ResponseType>` -- sends a message with a `requestId`, returns a promise that resolves when the response arrives (with timeout).
3. `on(type, handler)` -- subscribe to a message type.
4. `off(type, handler)` -- unsubscribe.

Request/response correlation via UUID `requestId` with a 30-second timeout and cleanup.

**Files to create:**
- `ghosti/src/ui/services/bridge.ts`
- `ghosti/src/plugin/bridge.ts`
- `ghosti/src/shared/ids.ts` (UUID generator, no crypto dependency -- use `Math.random` fallback for sandbox)

**Acceptance Criteria:**
- UI can send a message and receive a typed response via `await bridge.request(...)`.
- Sandbox receives, processes, and responds.
- Timeout fires if no response within 30 seconds.
- TypeScript catches mismatched message/response types at compile time.

---

### GH-004: Design tokens and internal design system foundation

**Phase:** 1
**Priority:** P1 (core)
**Dependencies:** GH-001
**Estimated Complexity:** M

**Description:**
Create the internal design token system for Ghosti's own UI. This is NOT the user's design system -- it is the plugin's own visual language. Define tokens as CSS custom properties that reference Figma's built-in CSS variables (for automatic dark/light mode), with fallbacks.

**Token categories:**
- **Color:** surface, surface-raised, surface-overlay, text-primary, text-secondary, text-tertiary, text-disabled, accent, accent-hover, accent-pressed, border, border-subtle, error, warning, success, info
- **Spacing:** 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48 (px)
- **Typography:** font-family (inherit from Figma), sizes (11, 12, 13, 14, 16, 20, 24), weights (400, 500, 600), line-heights (1.2, 1.4, 1.5)
- **Radii:** none, sm (4), md (6), lg (8), xl (12), full (9999)
- **Shadows:** sm, md, lg (for affordance cards, popovers)
- **Motion:** duration-fast (100ms), duration-normal (200ms), duration-slow (300ms), easing-default, easing-spring
- **Z-index:** base, dropdown, modal, toast

**Dark/light mode:** Map tokens to `figma-style` variables. Figma's iframe gets `figma-light` or `figma-dark` class on `<html>`. Use `var(--figma-color-bg)` etc. as base, overlay Ghosti-specific tokens.

Also create a CSS reset and base styles for the plugin iframe.

**Files to create:**
- `ghosti/src/ui/styles/tokens.css` (all CSS custom properties)
- `ghosti/src/ui/styles/reset.css` (normalize + plugin-specific resets)
- `ghosti/src/ui/styles/typography.css` (type scale classes)
- `ghosti/src/ui/styles/utilities.css` (spacing, flex, grid helpers)
- `ghosti/src/ui/styles/animations.css` (shared keyframes and transitions)
- `ghosti/src/ui/styles/index.css` (barrel import)

**Acceptance Criteria:**
- Tokens render correctly in both Figma light and dark mode.
- All color tokens have proper contrast ratios (WCAG 2.1 AA: 4.5:1 for text, 3:1 for UI).
- Motion tokens define `prefers-reduced-motion` overrides.
- No hardcoded colors, font sizes, or spacing values anywhere in subsequent UI code.

---

### GH-005: App state management with Lit reactive controllers

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-002
**Estimated Complexity:** M

**Description:**
Build the reactive state layer for the UI. Use Lit's `ReactiveController` pattern (not a separate state library). The `AppState` is a singleton that holds all application state and notifies subscribed Lit components when state changes.

**State shape:**
```typescript
interface AppState {
  // Connection
  apiKey: string | null;
  model: string;
  vestigeEndpoint: string | null;

  // Conversation
  conversation: ConversationState;

  // Canvas context
  selection: SerializedNode[] | null;
  pageInfo: PageInfo | null;

  // Design system
  dsIndex: DesignSystemIndex | null;
  usageModel: UsageModel | null;

  // UI state
  view: 'chat' | 'settings' | 'prompt-studio';
  isStreaming: boolean;
  error: AppError | null;
  inputDraft: string;
}
```

Provide `subscribe(path, callback)` for fine-grained reactivity. Provide `update(partial)` for immutable updates. Persist `apiKey`, `model`, `vestigeEndpoint` to `figma.clientStorage` via the bridge.

**Files to create:**
- `ghosti/src/ui/state/app-state.ts`
- `ghosti/src/ui/state/types.ts` (all state interfaces)
- `ghosti/src/ui/state/persistence.ts` (clientStorage read/write via bridge)

**Acceptance Criteria:**
- Components using the `StateController` re-render only when their subscribed state paths change.
- API key persists across plugin sessions via `figma.clientStorage`.
- State updates are immutable (no mutation of existing objects).

---

### GH-006: Conversation state and message model

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-005
**Estimated Complexity:** M

**Description:**
Define the conversation data model and state management. Messages must support Claude API format (for sending) while also carrying UI-specific metadata (for rendering).

**Data model:**
```typescript
interface ConversationMessage {
  id: string;
  role: 'user' | 'assistant';
  content: ContentBlock[];  // text, image, tool_use, tool_result, thinking
  timestamp: number;
  status: 'pending' | 'streaming' | 'complete' | 'error';
  // UI metadata
  isCollapsed: boolean;
  executionResults: ExecutionResult[];
}

type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: { type: 'base64'; media_type: string; data: string } }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; tool_use_id: string; content: string; is_error?: boolean }
  | { type: 'thinking'; thinking: string; budget_tokens?: number };
```

**ConversationState methods:**
- `addUserMessage(content)` -- append user message
- `startAssistantMessage()` -- create streaming placeholder
- `appendToStream(delta)` -- append text/thinking delta
- `completeMessage(id)` -- finalize
- `addToolUse(messageId, toolUse)` -- record tool call
- `addToolResult(messageId, toolResult)` -- record tool result
- `toApiFormat()` -- convert to Claude API messages array
- `getTokenEstimate()` -- rough token count for compaction decisions
- `clear()` -- reset conversation

**Files to create:**
- `ghosti/src/ui/state/conversation.ts`
- `ghosti/src/ui/state/message-types.ts`

**Acceptance Criteria:**
- `toApiFormat()` produces valid Anthropic Messages API format.
- Streaming deltas append correctly to the in-progress message.
- Tool use/result pairs are correctly paired by `tool_use_id`.
- Token estimation is within 20% accuracy (count chars / 4 as approximation).

---

### GH-007: Settings panel component

**Phase:** 1
**Priority:** P1 (core)
**Dependencies:** GH-004, GH-005
**Estimated Complexity:** M

**Description:**
Build the settings panel as a Lit web component. Clean, minimal UI following the internal design token system. This is the first screen users see (no API key yet).

**Settings sections:**
1. **API Key** -- password input, validate button (makes a trivial API call), status indicator (valid/invalid/checking)
2. **Model** -- dropdown: claude-sonnet-4-20250514, claude-opus-4-20250514 (default sonnet)
3. **Vestige** -- endpoint URL input, connection status indicator, org ID input, design system name
4. **About** -- version, links

**Interactions:**
- API key masked by default, reveal toggle
- Validate button tests the key with a minimal `messages.create` call
- Vestige endpoint tests with a health check
- All settings save to `figma.clientStorage` on change (debounced 500ms)
- Keyboard: Tab between fields, Enter to validate, Escape to close

**Files to create:**
- `ghosti/src/ui/components/settings-panel.ts`
- `ghosti/src/ui/components/shared/text-input.ts`
- `ghosti/src/ui/components/shared/select-input.ts`
- `ghosti/src/ui/components/shared/button.ts`
- `ghosti/src/ui/components/shared/status-badge.ts`

**Acceptance Criteria:**
- Settings persist and restore on plugin reopen.
- API key validation shows success/error state.
- All inputs are keyboard accessible.
- Dark mode renders correctly.
- No API key ever appears in console logs or error messages.

---

### GH-008: Chat message components -- text, markdown, thinking

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-004, GH-006
**Estimated Complexity:** L

**Description:**
Build the core chat message rendering components. Each message is a `<chat-message>` that delegates to sub-renderers based on content block type.

**Components:**

1. **`<chat-message>`** -- Container. Shows avatar (user "U" or Ghosti icon), role label, timestamp. Renders content blocks in sequence. User messages show raw text. Assistant messages render markdown + tool calls + thinking.

2. **`<markdown-block>`** -- Renders markdown to HTML using `marked`. Must support: headings, bold, italic, code (inline + fenced), lists, links, tables, blockquotes, horizontal rules. Fenced code blocks get syntax highlighting class names and a copy button. Sanitize output (no raw HTML passthrough -- strip `<script>`, `<iframe>`, event handlers).

3. **`<thinking-block>`** -- Collapsible section with "Thinking..." header. Shows thinking text in a muted, monospace style. Collapsed by default once complete, expanded while streaming.

**Streaming rendering:**
- Text streams character by character -- must parse partial markdown gracefully (marked handles this).
- Thinking blocks show a pulsing indicator while streaming.
- Smooth scroll-to-bottom as new content appears (unless user has scrolled up).

**Performance:**
- Virtualize rendering for conversations > 50 messages (only render visible + buffer).
- Markdown parsing is debounced during streaming (parse every 100ms, not every character).

**Files to create:**
- `ghosti/src/ui/components/chat-message.ts`
- `ghosti/src/ui/components/markdown-block.ts`
- `ghosti/src/ui/components/thinking-block.ts`
- `ghosti/src/ui/components/shared/copy-button.ts`
- `ghosti/src/ui/components/shared/avatar.ts`

**Acceptance Criteria:**
- Markdown renders correctly for all supported elements.
- Code blocks have copy-to-clipboard functionality.
- Streaming text appears smoothly without layout thrash.
- Thinking blocks collapse/expand with animation.
- No XSS possible through markdown content.
- Performance: 100 messages render without visible jank.

---

### GH-009: Server abstraction layer -- NetworkService interface

**Phase:** 1
**Priority:** P1 (core)
**Dependencies:** GH-002
**Estimated Complexity:** M

**Description:**
Create the abstraction layer for all network communication. Every HTTP call in the plugin (to Claude API, to Vestige, to any future service) must go through this abstraction. This enables localhost/hosted flexibility, offline graceful degradation, and testability.

**Core abstractions:**

```typescript
interface NetworkService {
  fetch(url: string, options: RequestOptions): Promise<NetworkResponse>;
  stream(url: string, options: RequestOptions): AsyncIterable<Uint8Array>;
  isOnline(): boolean;
  onStatusChange(callback: (online: boolean) => void): () => void;
}

interface RequestOptions {
  method: 'GET' | 'POST' | 'PUT' | 'DELETE';
  headers?: Record<string, string>;
  body?: string | ArrayBuffer;
  timeout?: number;
  retries?: number;
  retryDelay?: number;
}

interface NetworkResponse {
  ok: boolean;
  status: number;
  headers: Record<string, string>;
  json<T>(): Promise<T>;
  text(): Promise<string>;
}
```

**Offline queue:**
- Write operations (Vestige stores, promotions) queue when offline.
- Queue persists to `figma.clientStorage`.
- Flushes automatically when connection restored.
- Read operations return cached results when offline, with a staleness indicator.

**Error handling:**
- Retry with exponential backoff (3 retries, 1s/2s/4s).
- Distinguish network errors from API errors.
- Rate limit detection (429) with respect for `Retry-After`.

**Files to create:**
- `ghosti/src/ui/services/network.ts` (interface + implementation)
- `ghosti/src/ui/services/offline-queue.ts`
- `ghosti/src/ui/services/cache.ts` (in-memory LRU cache for reads)

**Acceptance Criteria:**
- All network calls route through `NetworkService`.
- Offline mode: writes queue, reads serve cache, UI shows offline indicator.
- Retry logic handles transient failures.
- Rate limiting is respected.
- Localhost and remote URLs work identically.

---

### GH-010: Claude service -- streaming API client

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-005, GH-006, GH-009
**Estimated Complexity:** L

**Description:**
Build the Claude API client that handles streaming responses using the Anthropic SDK in browser mode. This is the heart of the chat -- it sends messages and streams responses back into the conversation state.

**Implementation details:**
- Use `@anthropic-ai/sdk` with `dangerouslyAllowBrowser: true` (Figma plugin runs in an iframe, this is the documented approach).
- Streaming via `client.messages.stream()`.
- Handle all event types: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_stop`, `message_delta`.
- Parse `text_delta`, `thinking_delta`, `input_json_delta` (for tool use).
- Support extended thinking (pass `thinking` parameter with `budget_tokens`).
- Stop button support: `AbortController` integration, clean cancellation.

**ClaudeService interface:**
```typescript
class ClaudeService {
  constructor(networkService: NetworkService, state: AppState);
  async sendMessage(
    userContent: ContentBlock[],
    tools: ToolDefinition[],
    systemPrompt: string,
    onDelta: (delta: StreamDelta) => void
  ): Promise<AssistantMessage>;
  cancel(): void;
  isStreaming(): boolean;
}
```

**Error handling:**
- Invalid API key: clear error message, redirect to settings.
- Rate limit: show retry countdown.
- Overloaded: show "Claude is busy, retrying..."
- Network error: show offline state.
- Context too long: trigger compaction, retry.

**Files to create:**
- `ghosti/src/ui/services/claude.ts`
- `ghosti/src/ui/services/claude-types.ts` (stream event types, tool definitions)

**Acceptance Criteria:**
- "Hello" produces a streamed response visible in the UI.
- Stop button cancels in-flight requests cleanly.
- All error cases show user-friendly messages.
- Extended thinking works when enabled.
- Token usage is tracked from `message.usage`.

---

### GH-011: Chat panel and chat input components

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-008, GH-010
**Estimated Complexity:** L

**Description:**
Build the main chat interface: a scrollable message list and an input area at the bottom.

**`<chat-panel>` component:**
- Scrollable message list with auto-scroll to bottom on new messages.
- Auto-scroll pauses when user scrolls up; "Jump to bottom" FAB appears.
- Empty state: Ghosti introduction with suggested prompts ("Create a button", "Analyze my selection", "Help me with spacing").
- Loading state: typing indicator with three-dot animation while waiting for first token.
- Error state: inline error card with retry button.

**`<chat-input>` component:**
- Auto-resizing textarea (1 to 6 lines, then scroll).
- Send button (arrow icon) -- enabled only when input is non-empty and not streaming.
- Stop button -- replaces send when streaming.
- Keyboard: Enter to send, Shift+Enter for newline, Cmd+K to clear conversation.
- Character count / token estimate shown subtly at right.
- Drag-and-drop zone for images (visual affordance on dragover).
- Paste handler for images (Cmd+V with image on clipboard).

**Layout:**
- Flex column: chat panel fills available space, input pinned to bottom.
- Smooth resize animation when input grows/shrinks.
- 360px default width, 600px height, resizable.

**Files to create:**
- `ghosti/src/ui/components/chat-panel.ts`
- `ghosti/src/ui/components/chat-input.ts`
- `ghosti/src/ui/components/shared/scroll-anchor.ts`
- `ghosti/src/ui/components/shared/typing-indicator.ts`

**Acceptance Criteria:**
- Full send/receive cycle works: type message, press Enter, see streamed response.
- Auto-scroll works but pauses when user scrolls up.
- Input resizes smoothly.
- Stop button cancels streaming.
- Empty state renders with suggested prompts.
- Keyboard navigation: Tab to input, Enter to send, Escape to cancel.

---

### GH-012: Root app shell -- routing, layout, initialization

**Phase:** 1
**Priority:** P0 (blocking)
**Dependencies:** GH-007, GH-011
**Estimated Complexity:** M

**Description:**
Build the root `<ghosti-app>` component that orchestrates the entire plugin UI. Handles view routing, initialization sequence, and top-level layout.

**Initialization sequence:**
1. UI loads, sends `ui-ready` to sandbox.
2. Load persisted settings from `figma.clientStorage` (via bridge).
3. If no API key: show settings panel.
4. If API key exists: validate it (background), show chat panel.
5. Subscribe to selection changes from sandbox.

**Layout:**
- Header bar: Ghosti logo/name, current view indicator, settings gear icon.
- Main area: switches between chat, settings, prompt-studio views.
- View transitions: slide animation (200ms ease).
- Global keyboard shortcuts: Cmd+, for settings, Cmd+/ for keyboard shortcut help, Cmd+L to focus input.

**Error boundary:**
- Top-level try/catch renders a fallback error UI instead of a blank panel.
- Error UI shows the error message and a "Reload Plugin" button.

**Files to create:**
- `ghosti/src/ui/components/ghosti-app.ts`
- `ghosti/src/ui/components/shared/header-bar.ts`
- `ghosti/src/ui/components/shared/icon.ts` (SVG icon system, inline)
- `ghosti/src/ui/components/shared/keyboard-shortcuts.ts`

**Acceptance Criteria:**
- Plugin opens to settings if no API key, chat if API key exists.
- Navigation between views works with keyboard shortcuts.
- Selection changes from canvas propagate to UI state.
- Error boundary catches and displays rendering errors.
- Header shows current view and provides navigation.

---

## Phase 2: Code Execution

---

### GH-013: Sandbox executor -- safe async IIFE eval

**Phase:** 2
**Priority:** P0 (blocking)
**Dependencies:** GH-003
**Estimated Complexity:** L

**Description:**
Build the code execution engine in the plugin sandbox. This is the most security-sensitive component. Claude generates JavaScript code that manipulates the Figma canvas; the executor runs it safely.

**Execution model:**
- Wrap code in an async IIFE: `(async () => { ... })()`.
- Capture console output (override `console.log/warn/error` within scope).
- Capture return value (last expression or explicit return).
- Serialize results for transport (Figma nodes become serialized snapshots, not live references).
- Timeout: 30 seconds max execution time.
- Error capture: try/catch wrapping with stack trace extraction.

**Result serialization:**
- Primitive values: pass through.
- Figma nodes: serialize to `{ id, name, type, x, y, width, height }`.
- Arrays: serialize each element.
- Objects: JSON.stringify with circular reference handling.
- Functions: `"[Function]"`.

**Safety constraints:**
- No `eval` within eval (block nested eval).
- No `importScripts`.
- No access to `figma.clientStorage` from generated code (API key lives there).
- No `figma.closePlugin()`.
- Code runs with full `figma` API access (this is intentional -- it needs to create/modify nodes).

**Console capture:**
```typescript
interface ConsoleEntry {
  level: 'log' | 'warn' | 'error';
  args: unknown[];
  timestamp: number;
}
```

**Files to create:**
- `ghosti/src/plugin/executor.ts`
- `ghosti/src/plugin/serializer.ts` (result serialization)
- `ghosti/src/plugin/safety.ts` (code validation, blocked patterns)

**Acceptance Criteria:**
- `execute("figma.createRectangle()")` creates a rectangle and returns its serialized form.
- Console output is captured and returned.
- Errors are caught with meaningful stack traces.
- Timeout fires for infinite loops.
- Blocked patterns (`eval`, `importScripts`, `closePlugin`, `clientStorage`) are rejected before execution.
- Return values are properly serialized (no circular references crash).

---

### GH-014: Tool definitions and tool dispatch

**Phase:** 2
**Priority:** P0 (blocking)
**Dependencies:** GH-013, GH-003
**Estimated Complexity:** M

**Description:**
Define all Claude tools in the Anthropic tool format and build the dispatch system that routes tool calls to their implementations. Start with `execute_code` and `notify` -- other tools come in later phases.

**Tool definition format (for Claude API):**
```typescript
interface ToolDefinition {
  name: string;
  description: string;
  input_schema: JSONSchema;
}
```

**Tool registry pattern:**
```typescript
class ToolRegistry {
  register(name: string, definition: ToolDefinition, handler: ToolHandler): void;
  getDefinitions(): ToolDefinition[];
  async dispatch(name: string, input: unknown): Promise<ToolResult>;
}

type ToolHandler = (input: unknown) => Promise<ToolResult>;
interface ToolResult {
  content: string;
  is_error?: boolean;
}
```

**Initial tools:**
1. **`execute_code`** -- `{ code: string }` -- sends to sandbox executor, returns result.
2. **`notify`** -- `{ message: string }` -- shows a Figma toast notification.

**Dispatch flow:**
1. Claude returns a `tool_use` content block.
2. Agentic loop extracts `name` and `input`.
3. `ToolRegistry.dispatch(name, input)` routes to the handler.
4. Handler executes (may involve bridge round-trip to sandbox).
5. Result returned as `tool_result` content block.
6. Conversation continues.

**Files to create:**
- `ghosti/src/ui/services/tools/registry.ts`
- `ghosti/src/ui/services/tools/types.ts`
- `ghosti/src/ui/services/tools/execute-code.ts`
- `ghosti/src/ui/services/tools/notify.ts`

**Acceptance Criteria:**
- `execute_code` tool calls correctly route through bridge to sandbox executor.
- `notify` shows a Figma toast.
- Unknown tool names return an error tool result (not a crash).
- Tool definitions serialize to valid Anthropic API format.
- Multiple tool calls in one response are processed sequentially.

---

### GH-015: Agentic loop -- multi-turn tool use cycle

**Phase:** 2
**Priority:** P0 (blocking)
**Dependencies:** GH-010, GH-014
**Estimated Complexity:** L

**Description:**
Build the agentic loop that enables Claude to use tools iteratively until the task is complete. This is the core intelligence -- Claude calls tools, observes results, and decides whether to continue or finish.

**Loop logic:**
1. Send user message + system prompt + tools to Claude.
2. If response contains `tool_use` blocks: execute each tool, collect results.
3. Append tool results as a new `user` message (with `tool_result` content blocks).
4. Send again (Claude sees the results).
5. Repeat until Claude responds with only text (no tool calls) or max iterations hit.
6. Max iterations: 25 (configurable). Show warning at 20.

**Error recovery:**
- If a tool call fails, send the error as a `tool_result` with `is_error: true`.
- Claude should analyze the error and retry with corrected code.
- After 3 consecutive errors on the same tool, suggest the user intervene.
- Network errors during a loop iteration: pause, show retry, resume.

**State management during loop:**
- Each iteration updates the conversation state (visible in UI).
- Tool calls show as collapsible blocks in the chat.
- Execution results show inline with copy and expand/collapse.
- "Working..." indicator shows which tool is executing.

**Cancellation:**
- Stop button cancels at any point: during API call, during tool execution.
- Clean cancellation: partial results are preserved in conversation.

**Files to create:**
- `ghosti/src/ui/services/agentic-loop.ts`
- `ghosti/src/ui/services/loop-types.ts`

**Acceptance Criteria:**
- "Create a blue rectangle 200x100" works end-to-end: Claude calls `execute_code`, rectangle appears.
- Self-correction: if code has an error, Claude analyzes the error and retries.
- Max iterations prevent infinite loops.
- Each step is visible in the chat UI.
- Stop button works mid-loop.
- "Create 5 rectangles in a row" requires multi-step planning and works.

---

### GH-016: Code result UI component

**Phase:** 2
**Priority:** P1 (core)
**Dependencies:** GH-008, GH-015
**Estimated Complexity:** M

**Description:**
Build the `<code-result>` component that renders tool call/result pairs inline in chat messages. This replaces the raw tool_use/tool_result blocks with a user-friendly visualization.

**Rendering:**
- **Tool call header:** Icon + tool name + collapsible chevron. Default: collapsed for `execute_code`, expanded for errors.
- **Code block:** Syntax-highlighted JavaScript in a fenced code block. Copy button. Line numbers for code > 5 lines.
- **Result block:** Formatted output. For node creation, show: "Created Rectangle 'name' (id)". For errors, show red error card with stack trace.
- **Console output:** Collapsible section showing captured console.log entries, styled by level (log=normal, warn=yellow, error=red).
- **Duration:** Show execution time in subtle text (e.g., "ran in 45ms").

**Interaction:**
- Click header to expand/collapse.
- "Show code" toggle to reveal the generated code (hidden by default for non-error results).
- Keyboard: Enter/Space to toggle, Tab to navigate between results.

**Files to create:**
- `ghosti/src/ui/components/code-result.ts`
- `ghosti/src/ui/components/console-output.ts`

**Acceptance Criteria:**
- Successful tool calls show a compact summary (collapsed).
- Failed tool calls show expanded with error details.
- Code is syntax-highlighted and copyable.
- Console output renders with correct level styling.
- Multiple tool calls in one message render as a vertical stack.

---

## Phase 3: Design System Index + Read Tools

---

### GH-017: Design system indexer -- components, styles, variables

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** GH-003
**Estimated Complexity:** L

**Description:**
Build the design system indexer that runs in the plugin sandbox and catalogs all available design system assets. This gives Claude awareness of what exists in the user's design system.

**Index targets:**

1. **Components:** `figma.root.findAllWithCriteria({ types: ['COMPONENT', 'COMPONENT_SET'] })`. For each: name, description, key, variant properties (if component set), default variant. Index remote (library) components separately from local ones.

2. **Styles:** `figma.getLocalPaintStyles()`, `figma.getLocalTextStyles()`, `figma.getLocalEffectStyles()`, `figma.getLocalGridStyles()`. For each: name, key, type, description, and the actual values (colors, font families, effects).

3. **Variables:** `figma.variables.getLocalVariables()`, `figma.variables.getLocalVariableCollections()`. For each: name, collection, resolvedType, valuesByMode. Group by collection, show mode values.

**Index format:**
```typescript
interface DesignSystemIndex {
  components: ComponentEntry[];
  paintStyles: StyleEntry[];
  textStyles: StyleEntry[];
  effectStyles: StyleEntry[];
  gridStyles: StyleEntry[];
  variables: VariableEntry[];
  variableCollections: CollectionEntry[];
  indexedAt: number;
}
```

**Performance:**
- Indexing can be slow for large DS files (1000+ components). Run asynchronously.
- Cache the index. Re-index only when the file changes (compare `figma.root.children` hash).
- Send a compact summary to UI (not every property of every component).

**Files to create:**
- `ghosti/src/plugin/design-system.ts`
- `ghosti/src/plugin/ds-types.ts`

**Acceptance Criteria:**
- All local components, styles, and variables are indexed.
- Remote (library) components used on the page are included.
- Index is serializable (no circular references).
- Re-indexing detects changes correctly.
- Performance: indexing completes in < 3 seconds for a file with 500 components.

---

### GH-018: Selection and node serializer

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** GH-003
**Estimated Complexity:** M

**Description:**
Build the context engine's node serialization layer. When Claude needs to understand a node or the current selection, this serializer converts Figma nodes into a detailed but compact JSON representation.

**Serialization depth levels:**
1. **Shallow:** id, name, type, x, y, width, height, visible, locked (for lists, nearby nodes).
2. **Standard:** + fills, strokes, effects, opacity, blendMode, constraints, layoutMode, padding, itemSpacing, cornerRadius, componentPropertyValues (for selection context).
3. **Deep:** + children (recursively at shallow), text content (for text nodes), variant properties, bound variables, applied styles (for detailed read).

**Special node types:**
- **Text:** Include `characters`, `fontName`, `fontSize`, `fills`, `lineHeight`, `letterSpacing`, `paragraphSpacing`, `textAlignHorizontal`.
- **Instance:** Include `mainComponent.name`, `mainComponent.key`, overridden properties.
- **Frame with auto-layout:** Include `layoutMode`, `primaryAxisSizingMode`, `counterAxisSizingMode`, `paddingLeft/Right/Top/Bottom`, `itemSpacing`, `counterAxisSpacing`.
- **Vector:** Include `vectorNetwork` summary (path count, not full paths).

**Variable resolution:**
- If a property has a bound variable, include both the resolved value AND the variable name/collection.

**Files to create:**
- `ghosti/src/plugin/context.ts`
- `ghosti/src/plugin/context-types.ts`

**Acceptance Criteria:**
- Selection with 1 node returns standard-depth serialization.
- Selection with 10+ nodes returns shallow serialization.
- Text nodes include full text properties.
- Auto-layout frames include all layout properties.
- Instances include component references.
- Bound variables are resolved and named.

---

### GH-019: Read tools -- node, selection, page, styles, variables, components

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** GH-014, GH-017, GH-018
**Estimated Complexity:** M

**Description:**
Implement all `read_*` tools that Claude uses to inspect the canvas and design system. Each tool is registered in the ToolRegistry and routes through the bridge to the sandbox.

**Tools:**

1. **`read_node`** -- `{ id: string, depth?: 'shallow' | 'standard' | 'deep' }` -- Returns serialized node by ID.
2. **`read_selection`** -- `{}` -- Returns serialized current selection (standard depth).
3. **`read_page`** -- `{ depth?: 'shallow' | 'standard' }` -- Returns page structure. Shallow: top-level frames only. Standard: two levels deep.
4. **`read_styles`** -- `{ type?: 'paint' | 'text' | 'effect' | 'grid' }` -- Returns styles from DS index.
5. **`read_variables`** -- `{ collection?: string }` -- Returns variables from DS index.
6. **`read_components`** -- `{ query?: string }` -- Returns components from DS index.

**Each tool handler:**
1. Validates input.
2. Sends bridge request to sandbox.
3. Sandbox reads from Figma API / DS index.
4. Returns serialized result as tool_result string.

**Files to create:**
- `ghosti/src/ui/services/tools/read-node.ts`
- `ghosti/src/ui/services/tools/read-selection.ts`
- `ghosti/src/ui/services/tools/read-page.ts`
- `ghosti/src/ui/services/tools/read-styles.ts`
- `ghosti/src/ui/services/tools/read-variables.ts`
- `ghosti/src/ui/services/tools/read-components.ts`
- `ghosti/src/plugin/handlers/read-handlers.ts` (sandbox-side handlers)

**Acceptance Criteria:**
- "What's selected?" causes Claude to call `read_selection` and describe the node.
- "What components are available?" triggers `read_components` and lists them.
- "Read the page structure" triggers `read_page` and summarizes.
- Each tool returns well-formatted, concise results.
- Missing nodes / empty selection return informative messages (not errors).

---

### GH-020: Fuzzy search tool

**Phase:** 3
**Priority:** P2 (important)
**Dependencies:** GH-017, GH-014
**Estimated Complexity:** M

**Description:**
Implement the `search` tool that lets Claude fuzzy-search across components, styles, and variables by name. This is critical for Claude to find the right DS asset (e.g., "find the primary button component").

**Search algorithm:**
- Simple substring match + scoring by position (earlier match = higher score).
- Case-insensitive.
- Search across: component names, style names, variable names.
- Optional type filter: `{ query: string, type?: 'component' | 'style' | 'variable' }`.
- Return top 10 matches with relevance score.

**Result format:**
```typescript
interface SearchResult {
  name: string;
  type: 'component' | 'paint-style' | 'text-style' | 'effect-style' | 'variable';
  key: string;
  score: number;
  // Additional context
  description?: string;
  collection?: string; // for variables
  variants?: string[]; // for component sets
}
```

**Files to create:**
- `ghosti/src/ui/services/tools/search.ts`
- `ghosti/src/plugin/handlers/search-handler.ts`
- `ghosti/src/shared/fuzzy-match.ts` (reusable fuzzy matching)

**Acceptance Criteria:**
- `search("button")` finds Button components.
- `search("primary", type: "variable")` finds Primary color variables.
- Results are ranked by relevance.
- Empty results return a helpful message (not an error).
- Performance: < 100ms for a 1000-item index.

---

### GH-021: DS index context injection into system prompt

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** GH-017, GH-010
**Estimated Complexity:** M

**Description:**
Build the system prompt assembler that injects design system awareness into Claude's context. The DS index summary becomes part of the system prompt so Claude knows what design assets are available without needing to call tools first.

**System prompt structure:**
```
[GHOSTI.md content]

## Available Design System

### Components (N total)
- Button (variants: primary, secondary, tertiary)
- Card (variants: elevated, outlined)
...top 30, summarized

### Color Styles
- Primary/500: #2563EB
- Neutral/100: #F5F5F5
...

### Text Styles
- Heading/H1: Inter 32px Bold
- Body/Regular: Inter 16px Regular
...

### Variables (N collections)
Collection "Colors": Brand/Primary, Brand/Secondary, ...
Collection "Spacing": spacing/xs, spacing/sm, ...
...

## Current Context
[Selection info]
[Page info]
```

**Budget management:**
- DS summary should not exceed ~2000 tokens.
- If DS is large, show top items by usage frequency (most instances on current page first).
- Full DS available via search tool (mentioned in system prompt).

**Files to create:**
- `ghosti/src/ui/services/prompt-builder.ts`
- `ghosti/src/ui/services/ds-summarizer.ts`

**Acceptance Criteria:**
- System prompt includes DS summary automatically.
- Summary stays within 2000 token budget.
- Large design systems are summarized (not truncated mid-entry).
- Claude uses DS assets by name without being told to search first.

---

### GH-022: GHOSTI.md -- core system prompt document

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** None (content only)
**Estimated Complexity:** M

**Description:**
Write the GHOSTI.md system prompt that defines Claude's persona, capabilities, and constraints as a Figma design agent. This is the identity document -- equivalent to Claude Code's CLAUDE.md.

**Sections:**

1. **Identity:** You are Ghosti, an AI designer embedded in Figma. You have direct access to the canvas through code execution.

2. **Capabilities:** What tools are available, when to use each, the agentic loop behavior.

3. **Design principles:** Always use design system tokens. Prefer auto-layout. Respect existing conventions. Layouts should match ideal CSS implementations. Name layers semantically. Group related elements. Use consistent and even spacing between sides, unless otherwise instructed or source does differently.

4. **Code execution guidelines:** Use the Figma Plugin API. Always `figma.createX()` for new nodes. Always check if components/styles exist before creating. Use `figma.loadFontAsync()` before setting text. Always set `name` on created nodes.

5. **Constraints:** Never delete nodes without confirmation. Never change styles that are shared. Ask before making large changes. Explain what you're about to do before doing it.

6. **Communication style:** Be concise. Show, don't just tell. Use visual descriptions when relevant.

7. **Error handling:** If code fails, analyze the error and retry. If stuck after 3 retries, explain the issue and ask for guidance.

**Files to create:**
- `ghosti/.ghosti/GHOSTI.md`

**Acceptance Criteria:**
- Claude behaves as a knowledgeable Figma designer when given this prompt.
- Claude uses design system assets by default.
- Claude explains its plan before executing code.
- Claude handles errors gracefully.
- Prompt is under 3000 tokens.

---

### GH-023: Selection change listener and context refresh

**Phase:** 3
**Priority:** P1 (core)
**Dependencies:** GH-018, GH-005
**Estimated Complexity:** S

**Description:**
Wire up the `figma.on('selectionchange', ...)` listener in the sandbox to notify the UI whenever the user selects different nodes. The UI updates its context state, which feeds into the next message to Claude.

**Implementation:**
- Sandbox listens to `selectionchange` event.
- Debounce by 250ms (rapid clicks during selection should not spam).
- Serialize current selection at standard depth.
- Send `selection-changed` message to UI.
- UI updates `appState.selection`.
- Selection context is included in the next user message automatically (as a system-level context note, not user text).

**Edge cases:**
- Empty selection (user clicks canvas background): send `null`.
- Large selection (50+ nodes): send shallow serialization only.
- Selection during streaming: update state but don't interrupt current response.

**Files to modify:**
- `ghosti/src/plugin/code.ts` (add listener)
- `ghosti/src/ui/state/app-state.ts` (handle selection updates)

**Acceptance Criteria:**
- Selecting a node in Figma updates the selection state in the UI.
- Claude knows what's selected when the user asks "change this to red".
- Rapid selection changes are debounced.
- Large selections are handled without performance issues.

---

## Phase 4: Usage Pattern Analysis + Local Context

---

### GH-024: Usage pattern analyzer -- spacing, color, typography conventions

**Phase:** 4
**Priority:** P1 (core)
**Dependencies:** GH-017, GH-018
**Estimated Complexity:** XL

**Description:**
Build the usage pattern analyzer that scans the current page and infers design conventions from how tokens are actually used. This is the "learn by observation" engine -- it discovers that "all cards use 16px padding" by examining actual instances, not just what tokens exist.

**Analysis categories:**

1. **Spacing patterns:** Scan auto-layout frames for padding and itemSpacing values. Group by parent frame type/name. Report: "Frames named 'Card*' use padding 16px, itemSpacing 8px" type patterns.

2. **Color usage map:** Scan fills across all nodes. Map colors to usage roles: "This blue (#2563EB) is used on 45 button fills, 12 link texts" = likely primary CTA color. Detect: which colors are used for backgrounds, text, borders, accents.

3. **Typography hierarchy:** Scan text nodes. Group by fontSize + fontWeight. Report: "32px Bold appears in 5 page headers, 16px Regular appears in 120 body text nodes" = type scale in use.

4. **Corner radius conventions:** Group cornerRadius values by node type. "Buttons: 8px, Cards: 12px, Avatars: 9999px (full)".

5. **Component usage frequency:** Count instances of each component on the page. "Button/Primary: 23 instances, Card/Elevated: 8 instances".

**Output:**
```typescript
interface UsageModel {
  spacing: SpacingPattern[];
  colors: ColorUsageMap;
  typography: TypeHierarchy[];
  radii: RadiusPattern[];
  componentFrequency: ComponentFrequency[];
  analyzedAt: number;
  nodeCount: number;
}
```

**Performance:**
- Scan is expensive on large pages (1000+ nodes). Run asynchronously with progress updates.
- Cache results. Re-analyze only when page content changes (hash of node count + top-level structure).
- Skip hidden nodes, locked layers, and components (analyze instances, not definitions).

**Files to create:**
- `ghosti/src/plugin/usage-analyzer.ts`
- `ghosti/src/plugin/usage-types.ts`
- `ghosti/src/plugin/analyzers/spacing-analyzer.ts`
- `ghosti/src/plugin/analyzers/color-analyzer.ts`
- `ghosti/src/plugin/analyzers/typography-analyzer.ts`
- `ghosti/src/plugin/analyzers/radius-analyzer.ts`
- `ghosti/src/plugin/analyzers/component-frequency.ts`

**Acceptance Criteria:**
- Analyzer correctly identifies the most common spacing values on a page.
- Analyzer maps colors to usage roles.
- Analyzer produces a coherent typography hierarchy.
- Performance: < 5 seconds for a page with 500 nodes.
- Results are cached and invalidation works.

---

### GH-025: Local context builder -- siblings, parents, nearby nodes

**Phase:** 4
**Priority:** P1 (core)
**Dependencies:** GH-018
**Estimated Complexity:** M

**Description:**
Build the "neighborhood" context engine that gives Claude awareness of what's around the current selection. When the user says "add a subtitle below this", Claude needs to know what "this" is, what's above and below it, and what the parent container's layout is.

**Context layers:**

1. **Selected node(s):** Standard-depth serialization.
2. **Parent chain:** Walk up from selection to page root. For each parent: name, type, layout mode, padding, sizing. (Shallow, max 5 levels.)
3. **Siblings:** All children of the direct parent, in order. Shallow serialization. Indicate which is the selected node.
4. **Nearby nodes:** If parent is not an auto-layout frame, find nodes within 100px of selection (spatial proximity). Shallow serialization. This helps with absolute-positioned layouts.

**Output:**
```typescript
interface LocalContext {
  selection: SerializedNode[];
  parentChain: ParentEntry[];
  siblings: SiblingEntry[];
  nearbyNodes?: NearbyEntry[];
  pageInfo: { name: string; nodeCount: number };
}
```

**Tools:**
- Register `read_context` tool that returns the full local context.

**Files to create:**
- `ghosti/src/plugin/local-context.ts`
- `ghosti/src/ui/services/tools/read-context.ts`

**Acceptance Criteria:**
- "Move this to the right of its sibling" works because Claude knows the sibling layout.
- Auto-layout parents include full layout properties.
- Nearby nodes are detected for free-form layouts.
- Large sibling lists (100+ children) are truncated to nearest 10 + selection.

---

### GH-026: Usage pattern read tool

**Phase:** 4
**Priority:** P1 (core)
**Dependencies:** GH-024, GH-014
**Estimated Complexity:** S

**Description:**
Register the `read_usage` tool that exposes usage pattern analysis results to Claude. Claude calls this to understand conventions before making design decisions.

**Tool definition:**
```typescript
{
  name: 'read_usage',
  description: 'Get usage patterns for a design category on the current page',
  input_schema: {
    type: 'object',
    properties: {
      category: {
        type: 'string',
        enum: ['spacing', 'color', 'typography', 'radius', 'components', 'all']
      }
    },
    required: ['category']
  }
}
```

**Handler:** Returns the relevant section of the UsageModel, formatted as readable text. For example:
```
Spacing patterns on this page:
- Card containers: padding 16px, itemSpacing 8px (observed in 12 instances)
- List items: padding 12px 16px, itemSpacing 4px (observed in 34 instances)
- Button containers: padding 8px 16px (observed in 23 instances)
```

**Files to create:**
- `ghosti/src/ui/services/tools/read-usage.ts`

**Acceptance Criteria:**
- `read_usage("spacing")` returns human-readable spacing conventions.
- `read_usage("all")` returns a summary across all categories.
- Results reference actual page content.

---

### GH-027: Usage patterns injected into system prompt context

**Phase:** 4
**Priority:** P1 (core)
**Dependencies:** GH-024, GH-021
**Estimated Complexity:** S

**Description:**
Extend the system prompt builder to include a "Usage Conventions" section automatically. This means Claude already knows the page's patterns before the user even asks.

**Injection format:**
```
## Observed Usage Patterns (current page)

### Spacing
- Card containers: 16px padding, 8px itemSpacing
- ...

### Colors in Use
- Primary accent (#2563EB): 45 button fills, 12 link texts
- Background (#FFFFFF): 23 frame fills
- ...

### Typography
- 32px/Bold: Page headers (5 instances)
- 16px/Regular: Body text (120 instances)
- ...
```

**Budget:** Usage patterns section capped at ~1000 tokens. Prioritize by frequency (most common patterns first).

**Files to modify:**
- `ghosti/src/ui/services/prompt-builder.ts` (extend with usage section)

**Acceptance Criteria:**
- System prompt includes usage patterns.
- Claude creates new elements that match observed conventions without being told.
- Token budget is respected.

---

## Phase 5: Vestige Integration

---

### GH-028: Vestige HTTP client service

**Phase:** 5
**Priority:** P1 (core)
**Dependencies:** GH-009
**Estimated Complexity:** M

**Description:**
Build the `MemoryService` that communicates with a Vestige server over HTTP. This wraps the Vestige REST API and provides typed methods for all memory operations.

**Vestige API endpoints (based on Vestige MCP protocol, adapted to HTTP):**
- `POST /api/search` -- semantic search
- `POST /api/ingest` -- store new memory
- `POST /api/smart-ingest` -- intelligent store (dedup/update/create)
- `POST /api/promote` -- promote a memory
- `POST /api/demote` -- demote a memory
- `GET /api/health` -- health check
- `POST /api/consolidate` -- trigger consolidation

**MemoryService class:**
```typescript
class MemoryService {
  constructor(networkService: NetworkService, config: VestigeConfig);
  async search(query: string, tags?: string[], limit?: number): Promise<MemoryResult[]>;
  async remember(content: string, type: NodeType, tags: string[], source?: string): Promise<string>;
  async smartRemember(content: string, type: NodeType, tags: string[]): Promise<string>;
  async promote(id: string, reason?: string): Promise<void>;
  async demote(id: string, reason?: string): Promise<void>;
  async healthCheck(): Promise<HealthStatus>;
  async consolidate(): Promise<void>;
  isConnected(): boolean;
}
```

**Tag conventions:**
- Automatically add `org:<orgId>` tag from config.
- Automatically add `ds:<designSystem>` tag from config.
- Automatically add `file:<figma.root.name>` tag for file-specific patterns.

**Offline behavior (via NetworkService):**
- Reads return cached results with staleness indicator.
- Writes queue for later flush.
- Health check determines connected status.

**Files to create:**
- `ghosti/src/ui/services/memory.ts`
- `ghosti/src/ui/services/memory-types.ts`

**Acceptance Criteria:**
- `search("button spacing")` returns results from Vestige.
- `remember("Cards use 16px padding", "pattern", ["spacing"])` stores to Vestige.
- Health check works and updates connection status.
- Offline mode queues writes and serves cached reads.
- All requests include org-scoped tags automatically.

---

### GH-029: Memory tools -- remember_pattern and recall_patterns

**Phase:** 5
**Priority:** P1 (core)
**Dependencies:** GH-028, GH-014
**Estimated Complexity:** M

**Description:**
Register the two Vestige-facing tools that Claude uses to store and retrieve organizational design knowledge.

**Tool 1: `remember_pattern`**
```typescript
{
  name: 'remember_pattern',
  description: 'Store a design pattern, decision, or fact in organizational memory. Use when you observe a consistent convention or the user confirms a design decision.',
  input_schema: {
    type: 'object',
    properties: {
      content: { type: 'string', description: 'The pattern or decision to remember' },
      type: { type: 'string', enum: ['pattern', 'decision', 'fact', 'concept'] },
      tags: { type: 'array', items: { type: 'string' }, description: 'Category tags' }
    },
    required: ['content', 'type', 'tags']
  }
}
```

**Tool 2: `recall_patterns`**
```typescript
{
  name: 'recall_patterns',
  description: 'Search organizational memory for relevant design patterns and conventions.',
  input_schema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'What to search for' },
      tags: { type: 'array', items: { type: 'string' } }
    },
    required: ['query']
  }
}
```

**Handler logic:**
- `remember_pattern`: calls `memoryService.smartRemember()` (uses Vestige's prediction error gating to avoid duplicates).
- `recall_patterns`: calls `memoryService.search()`, formats results as readable text with relevance scores.

**Auto-tagging:**
- Tools automatically add org/DS scope tags.
- Claude's provided tags are added on top.

**Files to create:**
- `ghosti/src/ui/services/tools/remember-pattern.ts`
- `ghosti/src/ui/services/tools/recall-patterns.ts`

**Acceptance Criteria:**
- Claude can store a pattern and later retrieve it.
- Stored patterns include org-scoped tags.
- Recall results are formatted as readable text.
- Duplicate patterns are handled by smart ingestion.

---

### GH-030: Vestige patterns in system prompt context

**Phase:** 5
**Priority:** P1 (core)
**Dependencies:** GH-028, GH-021
**Estimated Complexity:** M

**Description:**
Extend the prompt builder to query Vestige at conversation start and inject relevant organizational knowledge into Claude's context. This makes Claude aware of org-wide patterns before the user asks anything.

**Implementation:**
1. On conversation start (or context refresh): query Vestige with the current task context.
2. Use 3 parallel queries:
   - General design patterns for this org: `search("design patterns", tags: [org, ds])`
   - Context-specific patterns (if selection exists): `search("[node type] conventions", tags: [org])`
   - Component-specific (if component selected): `search("[component name] usage", tags: [org])`
3. Deduplicate and rank results.
4. Inject top 10 results into system prompt under "## Organizational Design Knowledge".

**Budget:** Vestige section capped at ~1000 tokens. If more results, keep highest-relevance ones.

**Caching:** Cache Vestige results for 5 minutes (same queries return same results without re-querying).

**Files to modify:**
- `ghosti/src/ui/services/prompt-builder.ts` (extend with Vestige section)
- `ghosti/src/ui/services/memory.ts` (add context query method)

**Acceptance Criteria:**
- Conversation starts with relevant org patterns in context.
- Claude references organizational conventions in its responses.
- Vestige queries are cached to avoid redundant calls.
- If Vestige is offline, section is omitted gracefully.

---

### GH-031: Auto-learn -- pattern discovery after code execution

**Phase:** 5
**Priority:** P2 (important)
**Dependencies:** GH-029, GH-024
**Estimated Complexity:** M

**Description:**
After Claude successfully executes code that creates or modifies design elements, analyze the result and automatically suggest patterns to remember. This is the "learning by doing" mechanism.

**Trigger:** After a successful `execute_code` that creates/modifies nodes.

**Analysis:**
1. Read the created/modified nodes.
2. Compare with usage patterns on the page.
3. If the new elements follow a convention that isn't yet in Vestige, suggest storing it.
4. If `autoLearn` is enabled in settings, store automatically (via `smartRemember`).
5. If `autoLearn` is disabled, Claude mentions: "I noticed [pattern]. Would you like me to remember this for the team?"

**Pattern extraction heuristics:**
- Consistent spacing across created elements: "This component uses 8px itemSpacing".
- Color token usage: "Primary buttons use Brand/500 fill".
- Typography: "Card titles use Heading/H3 style".

**Files to create:**
- `ghosti/src/ui/services/auto-learn.ts`

**Acceptance Criteria:**
- After creating a card, Ghosti identifies the spacing/color pattern.
- With `autoLearn: true`, patterns store automatically.
- With `autoLearn: false`, patterns are suggested to the user.
- Duplicate patterns are not stored (smart ingest handles this).

---

### GH-032: Pattern promotion/demotion on user feedback

**Phase:** 5
**Priority:** P2 (important)
**Dependencies:** GH-028
**Estimated Complexity:** S

**Description:**
When the user corrects Claude ("No, we use 12px not 16px"), or confirms a result ("Perfect!"), update the relevant patterns in Vestige.

**Correction detection:**
- Claude detects corrections in the conversation naturally (it's in GHOSTI.md).
- When Claude corrects itself: demote the wrong pattern, store/promote the correction.
- When user says "perfect", "looks good", etc.: promote the patterns used in the last action.

**Manual promotion/demotion:**
- Expose in UI: on each code-result or pattern mention, show subtle thumbs up/down icons.
- Thumbs up → promote the pattern in Vestige.
- Thumbs down → demote the pattern.

**Files to create:**
- `ghosti/src/ui/services/feedback.ts`
- `ghosti/src/ui/components/shared/feedback-buttons.ts`

**Acceptance Criteria:**
- User corrections lead to pattern demotion.
- User confirmations lead to pattern promotion.
- UI shows feedback buttons on relevant messages.
- Feedback actions are reflected in Vestige.

---

### GH-033: Vestige settings UI -- endpoint, org, connection status

**Phase:** 5
**Priority:** P2 (important)
**Dependencies:** GH-007, GH-028
**Estimated Complexity:** S

**Description:**
Extend the settings panel with a Vestige configuration section.

**UI elements:**
- **Endpoint URL** -- text input with validation (must be valid URL).
- **Connection status** -- live indicator (green dot = connected, yellow = degraded, red = offline, gray = not configured).
- **Org ID** -- text input (or auto-detect from Figma if possible via `figma.payments?.getUserFirstRankedTeam()`).
- **Design System name** -- text input.
- **Auto-learn toggle** -- switch with explanation tooltip.
- **Test connection** -- button that calls health check.
- **Memory stats** -- show count of stored patterns, last consolidation time.

**Files to modify:**
- `ghosti/src/ui/components/settings-panel.ts` (extend)

**Acceptance Criteria:**
- Vestige endpoint can be configured and tested.
- Connection status updates in real-time.
- Settings persist across sessions.
- Invalid endpoints show clear error messages.

---

### GH-034: Vestige offline queue and cache layer

**Phase:** 5
**Priority:** P2 (important)
**Dependencies:** GH-009, GH-028
**Estimated Complexity:** M

**Description:**
Harden the offline support for Vestige operations. Writes queue when offline and flush when reconnected. Reads serve from an in-memory + persisted cache.

**Write queue:**
- Each write operation (remember, promote, demote) is added to a persistent queue.
- Queue stored in `figma.clientStorage` (via bridge).
- On reconnection: flush queue in order, with retry.
- Queue UI: show pending write count in settings.
- Max queue size: 100 items. Oldest dropped if exceeded.

**Read cache:**
- In-memory LRU cache (100 entries) for search results.
- TTL: 5 minutes for online, infinite for offline.
- Cache key: hash of query + tags.
- Stale indicator: results show "cached" badge in UI.

**Connection monitoring:**
- Poll health endpoint every 30 seconds when configured.
- Update connection status in app state.
- Emit events on status change.

**Files to modify:**
- `ghosti/src/ui/services/offline-queue.ts` (extend for Vestige)
- `ghosti/src/ui/services/cache.ts` (extend for Vestige)
- `ghosti/src/ui/services/memory.ts` (integrate queue + cache)

**Acceptance Criteria:**
- Pattern stores work offline and flush when reconnected.
- Reads return cached results with staleness indicator.
- Queue survives plugin restart (persisted).
- Connection status is accurate and updates.

---

## Phase 6: JIT Skills + Hooks + Context-Aware Prompting

---

### GH-035: Skill loader and JIT skill injection

**Phase:** 6
**Priority:** P1 (core)
**Dependencies:** GH-021
**Estimated Complexity:** M

**Description:**
Build the JIT (Just-In-Time) skill loading system. Skills are markdown files in `.ghosti/skills/` that contain domain-specific knowledge and instructions. They are loaded on-demand based on the current task context.

**Skill files to create (content):**
- `layout.md` -- Auto-layout, constraints, responsive patterns, spacing systems.
- `components.md` -- Creating/using components, variants, instances, overrides.
- `typography.md` -- Text nodes, font loading, type scale, text styles.
- `color.md` -- Fills, paints, gradients, variables, color styles, opacity.
- `effects.md` -- Shadows, blurs, layer effects.
- `responsive.md` -- Constraints, auto-layout, min/max sizing, responsive patterns.
- `design-system.md` -- Working with design system tokens, naming conventions, publishing.

**JIT loading logic:**
1. Analyze user message + current selection.
2. Keyword matching: "spacing", "padding", "auto-layout" -> load `layout.md`.
3. Selection type matching: text node selected -> load `typography.md`.
4. Multiple skills can load simultaneously (cap: 3 to stay within token budget).
5. Loaded skills are added to the system prompt for that turn.

**Skill format:**
```markdown
# Skill: Layout

## When to use
Load this skill when the user's task involves spacing, alignment, padding, auto-layout, or positioning.

## Key Figma API patterns
...

## Common mistakes to avoid
...
```

**Files to create:**
- `ghosti/src/ui/services/capabilities.ts` (skill loader)
- `ghosti/.ghosti/skills/layout.md`
- `ghosti/.ghosti/skills/components.md`
- `ghosti/.ghosti/skills/typography.md`
- `ghosti/.ghosti/skills/color.md`
- `ghosti/.ghosti/skills/effects.md`
- `ghosti/.ghosti/skills/responsive.md`
- `ghosti/.ghosti/skills/design-system.md`

**Acceptance Criteria:**
- "Fix the spacing" loads layout skill and Claude uses auto-layout correctly.
- "Change the color" loads color skill and Claude uses color variables.
- Skill loading is transparent to the user.
- Token budget for skills is capped at ~2000 tokens total.

---

### GH-036: Hook system -- pre-create, post-create, on-error, on-selection-change

**Phase:** 6
**Priority:** P2 (important)
**Dependencies:** GH-035
**Estimated Complexity:** M

**Description:**
Build the hook system that injects behavioral modifications into Claude's workflow. Hooks are markdown files that define rules for specific trigger points.

**Hook types:**
1. **`pre-create.md`** -- Before creating any new nodes. Rules like: "Always check if a component exists before creating from scratch. Always use auto-layout for containers."
2. **`post-create.md`** -- After creating nodes. Rules like: "Always name layers semantically. Always group related elements."
3. **`on-error.md`** -- When code execution fails. Rules like: "If font not found, try loading it with `figma.loadFontAsync()`. If node not found, re-read selection."
4. **`on-selection-change.md`** -- When selection changes. Rules like: "Update your context. If the user just selected what you created, they may want to refine it."

**Hook loading:**
- Hooks are always loaded (not JIT).
- Injected into system prompt in a "## Active Hooks" section.
- Hooks are smaller than skills (each < 500 tokens).

**Hook execution:**
- `pre-create`: Claude reads this before every `execute_code` call that creates nodes.
- `post-create`: Claude reads this after successful node creation.
- `on-error`: Claude reads this when a tool_result has `is_error: true`.
- `on-selection-change`: Claude considers this when selection context updates.

**Files to create:**
- `ghosti/.ghosti/hooks/pre-create.md`
- `ghosti/.ghosti/hooks/post-create.md`
- `ghosti/.ghosti/hooks/on-error.md`
- `ghosti/.ghosti/hooks/on-selection-change.md`
- `ghosti/src/ui/services/hooks.ts` (hook loader and injector)

**Acceptance Criteria:**
- pre-create hook causes Claude to check for existing components.
- on-error hook causes Claude to try `loadFontAsync` on font errors.
- Hooks are visible in the prompt studio (GH-038).
- Custom hooks can be added to the hooks directory.

---

### GH-037: Context compaction -- summarize older messages

**Phase:** 6
**Priority:** P1 (core)
**Dependencies:** GH-006, GH-010
**Estimated Complexity:** M

**Description:**
Build the context compaction system that prevents conversations from exceeding Claude's context window. When the conversation gets long, older messages are summarized to free up space while preserving important context.

**Compaction strategy:**
1. Monitor token count after each message.
2. When total tokens exceed 80% of model limit (e.g., 80K for 100K context): trigger compaction.
3. Keep: system prompt (always), last 10 messages (always), design system context (always).
4. Compact: older messages get summarized into a single "Conversation Summary" message.
5. Summary includes: key decisions made, elements created/modified (with IDs), user preferences expressed, patterns learned.
6. The summary is generated by Claude itself (with a separate, cheap API call using the compaction prompt).

**Compaction prompt:**
```
Summarize this conversation, preserving:
1. All node IDs that were created or modified
2. Design decisions the user made
3. Patterns or preferences expressed
4. Current state of the task
Keep it under 500 words.
```

**UI indication:**
- When compaction occurs, show a subtle divider: "Earlier messages summarized" with expand option.
- Expanded view shows the summary text.

**Files to create:**
- `ghosti/src/ui/services/compactor.ts`

**Acceptance Criteria:**
- Long conversations (50+ messages) trigger compaction.
- Compacted conversations still work (Claude remembers what was created).
- Token count stays within 80% of model limit.
- UI clearly indicates where compaction occurred.
- No loss of node IDs or critical decisions.

---

### GH-038: Prompt studio -- view and edit assembled system prompt

**Phase:** 6
**Priority:** P2 (important)
**Dependencies:** GH-021, GH-035, GH-036
**Estimated Complexity:** M

**Description:**
Build a "Prompt Studio" view in settings that shows the fully assembled system prompt that Claude receives. This is a power-user/debug tool that makes the prompt pipeline transparent.

**UI:**
- Accordion sections showing each prompt component:
  1. GHOSTI.md (editable in-place, hot-reloadable)
  2. Active hooks (list, each expandable)
  3. Loaded skills (list, each expandable)
  4. Design system summary
  5. Usage patterns
  6. Vestige patterns
  7. Current context (selection + page)
- Total token count for the assembled prompt.
- "Refresh" button to re-assemble.
- "Copy Full Prompt" button for debugging.

**GHOSTI.md hot-reload:**
- Edit GHOSTI.md in the prompt studio textarea.
- Changes apply immediately to the next message (no plugin restart).
- Save button persists changes back to `.ghosti/GHOSTI.md` (via bridge to sandbox, which writes the file).
- Alternatively, detect external file changes and reload (if feasible in plugin context).

**Files to create:**
- `ghosti/src/ui/components/prompt-studio.ts`
- `ghosti/src/ui/components/shared/accordion.ts`
- `ghosti/src/ui/components/shared/code-editor.ts` (simple textarea with line numbers)

**Acceptance Criteria:**
- All prompt components are visible and labeled.
- Token count is shown and updated on refresh.
- GHOSTI.md edits take effect on the next message.
- Copy button copies the full assembled prompt.
- Each section can be expanded/collapsed independently.

---

## Phase 7: JIT Affordances

---

### GH-039: Affordance host and suggest_affordance tool

**Phase:** 7
**Priority:** P2 (important)
**Dependencies:** GH-014, GH-008
**Estimated Complexity:** M

**Description:**
Build the affordance system -- rich UI widgets that Claude can inject into the chat. When Claude asks the user to pick a color, instead of asking in text, it renders an interactive color swatch grid.

**`suggest_affordance` tool:**
```typescript
{
  name: 'suggest_affordance',
  description: 'Show an interactive UI widget in the chat for user input',
  input_schema: {
    type: 'object',
    properties: {
      type: { type: 'string', enum: ['color-picker', 'dimension-input', 'action-buttons', 'swatch-grid', 'node-list', 'component-picker', 'style-picker'] },
      config: { type: 'object', description: 'Configuration for the widget' },
      prompt: { type: 'string', description: 'Question or instruction shown with the widget' }
    },
    required: ['type', 'config']
  }
}
```

**Affordance host:**
- Renders inside a chat message.
- Takes the affordance type + config and renders the appropriate component.
- Captures user interaction and sends it back as the next user message automatically.

**Interaction flow:**
1. Claude calls `suggest_affordance({ type: 'swatch-grid', config: { colors: [...] }, prompt: 'Pick a color' })`.
2. Tool result returns `"Affordance rendered. Awaiting user input."`.
3. UI renders the swatch grid in the chat.
4. User clicks a color.
5. The selection is sent as a new user message: `"Selected color: Brand/Primary (#2563EB)"`.
6. Claude continues with that input.

**Files to create:**
- `ghosti/src/ui/services/tools/suggest-affordance.ts`
- `ghosti/src/ui/components/affordances/affordance-host.ts`

**Acceptance Criteria:**
- Claude can trigger an affordance widget.
- Widget renders in the chat.
- User interaction feeds back into the conversation.
- Affordance type not found: falls back to text prompt.

---

### GH-040: Affordance widgets -- color picker, dimension input, action buttons

**Phase:** 7
**Priority:** P2 (important)
**Dependencies:** GH-039
**Estimated Complexity:** L

**Description:**
Build the individual affordance widget components.

**Widgets:**

1. **`<color-picker>`** -- Color input with preset swatches from the DS. Click a swatch to select, or enter a custom hex value. Shows the selected color preview. Config: `{ swatches: Color[], current?: string }`.

2. **`<dimension-input>`** -- Numeric input with increment/decrement buttons and slider. Unit selector (px, %, auto). Config: `{ label: string, min: number, max: number, step: number, value: number, unit: string }`.

3. **`<action-buttons>`** -- Row of labeled buttons for quick choices. Config: `{ options: { label: string, value: string, icon?: string }[] }`. Supports single-select and multi-select modes.

4. **`<swatch-grid>`** -- Grid of color swatches from the DS color styles/variables. Grouped by collection. Config: `{ colors: { name: string, hex: string }[] }`.

5. **`<node-list>`** -- List of nodes with thumbnails (if available) and names. Clickable to select in Figma. Config: `{ nodes: { id: string, name: string, type: string }[] }`.

6. **`<component-picker>`** -- Searchable list of components from the DS index. Shows component name, description, variant count. Config: `{ components: ComponentEntry[] }`.

7. **`<style-picker>`** -- List of styles grouped by type. Shows style preview (color swatch, font preview, etc). Config: `{ styles: StyleEntry[] }`.

**Shared patterns:**
- All widgets emit a `ghosti-affordance-select` custom event with the selected value.
- All widgets support keyboard navigation.
- All widgets use the design token system for consistent styling.

**Files to create:**
- `ghosti/src/ui/components/affordances/color-picker.ts`
- `ghosti/src/ui/components/affordances/dimension-input.ts`
- `ghosti/src/ui/components/affordances/action-buttons.ts`
- `ghosti/src/ui/components/affordances/swatch-grid.ts`
- `ghosti/src/ui/components/affordances/node-list.ts`
- `ghosti/src/ui/components/affordances/component-picker.ts`
- `ghosti/src/ui/components/affordances/style-picker.ts`

**Acceptance Criteria:**
- Each widget renders correctly and captures user input.
- Keyboard navigation works on all widgets.
- Widgets are visually consistent with the plugin's design system.
- Dark mode works on all widgets.
- Component and style pickers load from the DS index.

---

### GH-041: Affordance feedback loop -- selection to conversation

**Phase:** 7
**Priority:** P2 (important)
**Dependencies:** GH-039, GH-040
**Estimated Complexity:** S

**Description:**
Wire up the complete feedback loop: user interacts with an affordance widget, the result is automatically sent as the next user message, and Claude continues the conversation with that input.

**Implementation:**
- `AffordanceHost` listens for `ghosti-affordance-select` events from child widgets.
- On selection: formats the value as a human-readable message.
- Appends the message to the conversation as a user message.
- Triggers the agentic loop to continue.
- The affordance widget shows a "selected" state (checkmark on the chosen option).
- The widget becomes non-interactive after selection (read-only).

**Message formatting examples:**
- Color: `"I chose Brand/Primary (#2563EB)"`
- Dimension: `"Set width to 200px"`
- Action button: `"Go with option: Create from scratch"`
- Component: `"Use the Button/Primary component"`

**Files to modify:**
- `ghosti/src/ui/components/affordances/affordance-host.ts` (extend)
- `ghosti/src/ui/components/chat-panel.ts` (auto-send affordance selections)

**Acceptance Criteria:**
- Selecting a color swatch sends the selection and Claude continues.
- Widgets become read-only after selection.
- The feedback message is formatted naturally.
- Multiple affordances in one conversation work independently.

---

## Phase 8: Polish + Enterprise Quality

---

### GH-042: Multimodal chat -- image paste and drop

**Phase:** 8
**Priority:** P1 (core)
**Dependencies:** GH-011, GH-006
**Estimated Complexity:** M

**Description:**
Enable users to paste or drop images into the chat input. Images are sent to Claude as image content blocks (base64-encoded).

**Implementation:**

**Paste (Cmd+V):**
- Listen for `paste` event on the chat input.
- Check `clipboardData.items` for image types (image/png, image/jpeg, image/gif, image/webp).
- Read as base64 via `FileReader`.
- Show image preview in the input area (thumbnail, removable).
- On send: include as `{ type: 'image', source: { type: 'base64', media_type, data } }` content block.

**Drag and drop:**
- `dragover` on chat input shows drop zone overlay ("Drop image here").
- `drop` reads the file, same base64 conversion.
- Support multiple images.

**Constraints:**
- Max image size: 5MB (Claude API limit).
- Supported formats: PNG, JPEG, GIF, WebP.
- Show error for unsupported formats or oversized images.
- Strip EXIF data before sending (privacy).

**Files to create:**
- `ghosti/src/ui/services/image-handler.ts`
- `ghosti/src/ui/components/shared/image-preview.ts`
- `ghosti/src/ui/components/shared/drop-zone.ts`

**Files to modify:**
- `ghosti/src/ui/components/chat-input.ts` (add paste/drop handlers)
- `ghosti/src/ui/state/conversation.ts` (support image content blocks)

**Acceptance Criteria:**
- Pasting a screenshot into chat shows a preview and sends it to Claude.
- Drag-and-drop works with the same result.
- Claude can see and describe the image.
- Oversized images show a clear error.
- Image previews are removable before sending.

---

### GH-043: Multimodal chat -- Figma node screenshot capture

**Phase:** 8
**Priority:** P2 (important)
**Dependencies:** GH-042, GH-003
**Estimated Complexity:** M

**Description:**
Enable capturing a screenshot of a Figma node and sending it to Claude as an image. This lets users say "look at this" and have Claude visually inspect their work.

**Implementation:**
- Use `node.exportAsync({ format: 'PNG', constraint: { type: 'SCALE', value: 2 } })` in the sandbox.
- Returns `Uint8Array`, convert to base64 in UI.
- Triggered by: a "Capture selection" button in chat input, or Claude calling a `capture_screenshot` tool.

**Tool definition:**
```typescript
{
  name: 'capture_screenshot',
  description: 'Capture a screenshot of a Figma node by ID or the current selection',
  input_schema: {
    type: 'object',
    properties: {
      nodeId: { type: 'string', description: 'Node ID to capture. Omit for current selection.' }
    }
  }
}
```

**UI:** Button with camera icon in chat input toolbar. Click captures selection, shows preview, includes in next message.

**Files to create:**
- `ghosti/src/ui/services/tools/capture-screenshot.ts`
- `ghosti/src/plugin/handlers/screenshot-handler.ts`

**Files to modify:**
- `ghosti/src/ui/components/chat-input.ts` (add capture button)

**Acceptance Criteria:**
- "Capture selection" button produces a screenshot in the chat.
- Claude can analyze the screenshot and give visual feedback.
- `capture_screenshot` tool works when called by Claude.
- Large nodes are captured at reasonable resolution (max 2048px dimension).

---

### GH-044: Multimodal chat -- URL/link parsing and web content extraction

**Phase:** 8
**Priority:** P3 (polish)
**Dependencies:** GH-009, GH-042
**Estimated Complexity:** M

**Description:**
When a user pastes a URL into the chat, automatically fetch metadata (title, description, OG image) and optionally extract page content for design reference.

**URL detection:**
- Regex scan input text for URLs.
- On detection: fetch metadata via a lightweight proxy or direct fetch (if CORS allows).
- Show a link preview card: title, description, favicon, OG image thumbnail.

**Content extraction:**
- For design reference URLs (Dribbble, Behance, landing pages): offer to "Extract content" button.
- Fetches the page HTML, strips to meaningful text + images.
- Sends extracted content as context to Claude.

**Limitations:**
- Many URLs will be CORS-blocked from the iframe. Show a graceful fallback (just the URL, no preview).
- For authenticated URLs: show a message explaining the limitation.
- Max extracted content: 2000 tokens.

**Files to create:**
- `ghosti/src/ui/services/link-preview.ts`
- `ghosti/src/ui/components/shared/link-card.ts`

**Acceptance Criteria:**
- Pasting a URL shows a preview card (when fetchable).
- CORS-blocked URLs gracefully degrade to plain text.
- Extracted content is sent to Claude as context.
- OG images display in the preview card.

---

### GH-045: Multimodal chat -- file attachments (PDF, brand guidelines)

**Phase:** 8
**Priority:** P3 (polish)
**Dependencies:** GH-042
**Estimated Complexity:** M

**Description:**
Allow users to attach files (PDFs, text files, brand guidelines) to the chat. PDF content is extracted as text; images within PDFs are extracted if possible.

**Implementation:**
- File input button in chat input toolbar (paperclip icon).
- Accepted types: `.pdf`, `.txt`, `.md`, `.json`, `.csv`.
- PDF: Use a lightweight PDF text extractor (pdf.js or similar, bundled). Extract text content page by page. Cap at 10 pages / 5000 tokens.
- Text files: Read as UTF-8 text.
- Show file attachment card: file name, size, type icon, remove button.
- Content included in the user message as a text content block with a "File: filename.pdf" header.

**Constraints:**
- Max file size: 10MB.
- No executable files (.js, .exe, etc.).
- PDF images: extract as base64 image blocks if small enough.

**Files to create:**
- `ghosti/src/ui/services/file-handler.ts`
- `ghosti/src/ui/components/shared/file-attachment.ts`

**Files to modify:**
- `ghosti/src/ui/components/chat-input.ts` (add file input)

**Acceptance Criteria:**
- Attaching a PDF extracts text and sends to Claude.
- Claude can reference the file content in its responses.
- File cards show in the input area before sending.
- Oversized files show a clear error.
- Unsupported file types are rejected.

---

### GH-046: WCAG 2.1 AA accessibility audit and fixes

**Phase:** 8
**Priority:** P1 (core)
**Dependencies:** GH-012 (all UI components must exist)
**Estimated Complexity:** L

**Description:**
Comprehensive accessibility pass across all UI components. Every interactive element must be keyboard accessible, screen-reader friendly, and meet WCAG 2.1 AA standards.

**Audit checklist:**

1. **Focus management:** Visible focus rings on all interactive elements. Logical tab order. Focus trapped in modals/settings panel. Focus returned after closing overlays.

2. **ARIA attributes:** All custom components have appropriate `role` attributes. `aria-label` on icon-only buttons. `aria-expanded` on collapsible sections. `aria-live` regions for streaming content. `aria-busy` during loading states.

3. **Keyboard navigation:** All actions reachable via keyboard. Enter/Space activates buttons. Escape closes modals. Arrow keys navigate lists. Home/End in text inputs. Full keyboard shortcut documentation.

4. **Color contrast:** All text meets 4.5:1 ratio. UI elements meet 3:1 ratio. Error states don't rely solely on color (add icons). Tested in both light and dark mode.

5. **Motion:** `prefers-reduced-motion` disables animations. No essential information conveyed only through motion.

6. **Screen reader announcements:** New messages announced. Tool execution status announced. Errors announced. Affordance selections announced.

**Files to modify:**
- All component files in `ghosti/src/ui/components/` (add ARIA attributes, focus management)
- `ghosti/src/ui/styles/tokens.css` (verify contrast ratios)
- `ghosti/src/ui/components/shared/keyboard-shortcuts.ts` (comprehensive shortcut map)

**Files to create:**
- `ghosti/src/ui/services/focus-manager.ts` (focus trap, focus return utilities)
- `ghosti/src/ui/services/announcer.ts` (aria-live region manager)

**Acceptance Criteria:**
- All interactive elements are keyboard accessible.
- Screen reader can navigate the entire plugin.
- Color contrast meets AA ratios in both themes.
- Focus is managed correctly in all flows.
- `prefers-reduced-motion` is respected.
- No accessibility warnings from automated audit tools.

---

### GH-047: Security hardening -- API keys, XSS, code execution safety

**Phase:** 8
**Priority:** P1 (core)
**Dependencies:** GH-013, GH-007
**Estimated Complexity:** M

**Description:**
Comprehensive security review and hardening across all attack surfaces.

**API key security:**
- Stored in `figma.clientStorage` only (not in-memory longer than needed).
- Never logged to console.
- Never included in error messages or reports.
- Never sent to Vestige or any server other than api.anthropic.com.
- Masked in settings UI.
- Clear button to remove key from storage.

**XSS prevention:**
- Markdown renderer uses DOMPurify (or equivalent) to sanitize HTML output.
- No `innerHTML` with unsanitized content anywhere.
- All user-generated content is escaped before rendering.
- Markdown code blocks cannot contain executable HTML.
- Affordance configs from Claude are validated against schemas.

**Code execution safety:**
- Blocklist patterns validated before execution.
- Generated code cannot access `figma.clientStorage`.
- Generated code cannot close the plugin.
- Generated code cannot make network requests (no fetch/XMLHttpRequest in sandbox).
- Execution timeout enforced.
- Console output sanitized before display.

**Network security:**
- All network requests use HTTPS (HTTP rejected with clear error).
- API keys sent only as `Authorization` or `x-api-key` headers.
- CORS handled gracefully.

**Files to create:**
- `ghosti/src/ui/services/sanitizer.ts` (HTML sanitization)
- `ghosti/src/shared/security.ts` (validation, blocklists)

**Files to modify:**
- `ghosti/src/ui/components/markdown-block.ts` (add sanitization)
- `ghosti/src/plugin/safety.ts` (extend blocklist)
- `ghosti/src/ui/services/network.ts` (HTTPS enforcement)

**Acceptance Criteria:**
- API key never appears in console, error messages, or network requests to non-Anthropic servers.
- `<script>` tags in markdown are stripped.
- Malicious code patterns are blocked before execution.
- HTTPS is enforced for all external requests.
- Affordance configs are schema-validated.

---

### GH-048: Error handling and error boundary system

**Phase:** 8
**Priority:** P1 (core)
**Dependencies:** GH-012
**Estimated Complexity:** M

**Description:**
Build a comprehensive error handling system that catches, categorizes, and displays errors at every layer.

**Error categories:**
1. **Network errors** -- connection failed, timeout, rate limit. Recovery: retry with backoff.
2. **API errors** -- invalid key, overloaded, context too long. Recovery: user action or automatic compaction.
3. **Execution errors** -- code failed in sandbox. Recovery: Claude self-corrects.
4. **Plugin errors** -- Figma API error (node not found, read-only file). Recovery: informative message.
5. **UI errors** -- rendering failed. Recovery: error boundary catches and shows fallback.

**Error boundary pattern (Lit):**
- Wrap top-level component in a try/catch renderer.
- On render error: show a fallback UI with error message and "Reload" button.
- Log error details to console for debugging.

**Error display:**
- Toast notifications for transient errors (auto-dismiss after 5s).
- Inline error cards for persistent errors (in chat).
- Modal error dialog for fatal errors (API key invalid).
- Error messages are user-friendly (not stack traces).

**Error reporting:**
- All errors logged with context (what was the user doing, what was Claude doing).
- No PII or API keys in error logs.

**Files to create:**
- `ghosti/src/ui/services/error-handler.ts`
- `ghosti/src/ui/components/shared/error-boundary.ts`
- `ghosti/src/ui/components/shared/error-toast.ts`
- `ghosti/src/ui/components/shared/error-card.ts`
- `ghosti/src/shared/errors.ts` (error types, categorization)

**Acceptance Criteria:**
- No unhandled exceptions crash the plugin.
- Network errors show retry UI.
- API errors show clear resolution steps.
- Execution errors are displayed inline and Claude self-corrects.
- Fatal errors show a recoverable error screen.

---

### GH-049: Conversation persistence and history

**Phase:** 8
**Priority:** P2 (important)
**Dependencies:** GH-006
**Estimated Complexity:** M

**Description:**
Persist conversations across plugin sessions. Users can resume a previous conversation or start a new one.

**Storage:**
- Conversations stored in `figma.clientStorage` (via bridge).
- Each conversation: ID, title (auto-generated from first message), messages, creation time, last updated time.
- Max stored conversations: 20 (oldest auto-deleted).
- Max conversation size: 500KB per conversation (large ones compacted or truncated).

**UI:**
- Conversation list sidebar (slide-in from left).
- Each entry: title, last message preview, timestamp, delete button.
- "New conversation" button.
- Current conversation highlighted.
- Swipe or keyboard Delete to remove.

**Auto-title:**
- After first assistant response, generate a title from the user's first message (truncate to 50 chars, smart word boundary).

**Files to create:**
- `ghosti/src/ui/services/conversation-store.ts`
- `ghosti/src/ui/components/conversation-list.ts`

**Files to modify:**
- `ghosti/src/ui/components/ghosti-app.ts` (add conversation switcher)
- `ghosti/src/ui/components/shared/header-bar.ts` (add conversation toggle)

**Acceptance Criteria:**
- Conversation persists after closing and reopening the plugin.
- Previous conversations are listed and selectable.
- New conversation button works.
- Deletion removes the conversation from storage.
- Storage limits are enforced.

---

### GH-050: Model selector and extended thinking toggle

**Phase:** 8
**Priority:** P2 (important)
**Dependencies:** GH-010, GH-007
**Estimated Complexity:** S

**Description:**
Add model selection and extended thinking configuration to settings and as a quick-toggle in the chat UI.

**Model selector:**
- Dropdown in settings: claude-sonnet-4-20250514 (default), claude-opus-4-20250514, and future models.
- Quick-toggle in chat input area (small model badge, clickable to change).
- Model change takes effect on the next message.

**Extended thinking:**
- Toggle switch in settings: "Enable extended thinking".
- When enabled: pass `thinking: { type: 'enabled', budget_tokens: N }` to the API.
- Budget slider: 1024 to 32768 tokens (default 4096).
- Thinking blocks render in the chat (GH-008 already handles this).

**Files to modify:**
- `ghosti/src/ui/components/settings-panel.ts` (add model + thinking settings)
- `ghosti/src/ui/components/chat-input.ts` (add model badge)
- `ghosti/src/ui/services/claude.ts` (apply model + thinking settings)

**Acceptance Criteria:**
- Model selection changes which Claude model is called.
- Extended thinking shows thinking blocks in the chat.
- Budget slider adjusts thinking token budget.
- Settings persist across sessions.

---

### GH-051: Keyboard shortcuts system and help dialog

**Phase:** 8
**Priority:** P2 (important)
**Dependencies:** GH-012
**Estimated Complexity:** M

**Description:**
Build a comprehensive keyboard shortcut system for power users. All major actions are keyboard-accessible.

**Shortcuts:**
| Shortcut | Action |
|----------|--------|
| `Enter` | Send message |
| `Shift+Enter` | New line in input |
| `Cmd+K` | Clear conversation |
| `Cmd+,` | Open settings |
| `Cmd+/` | Show keyboard shortcut help |
| `Cmd+L` | Focus chat input |
| `Escape` | Cancel streaming / close panel / deselect |
| `Cmd+N` | New conversation |
| `Cmd+[` | Previous conversation |
| `Cmd+]` | Next conversation |
| `Cmd+Shift+C` | Capture selection screenshot |
| `Tab` / `Shift+Tab` | Navigate focusable elements |
| `ArrowUp` (in empty input) | Edit last message |

**Implementation:**
- Global keyboard event listener on the plugin iframe.
- Shortcut registry with conflict detection.
- Shortcuts are configurable (future: stored in settings).
- Help dialog shows all available shortcuts in a clean grid.

**Files to create:**
- `ghosti/src/ui/services/keyboard.ts` (shortcut registry + listener)
- `ghosti/src/ui/components/keyboard-help.ts` (help dialog)

**Files to modify:**
- `ghosti/src/ui/components/ghosti-app.ts` (register global listener)

**Acceptance Criteria:**
- All listed shortcuts work.
- Shortcuts don't fire when focus is in a text input (except Enter, Shift+Enter, Escape).
- Help dialog is accessible via Cmd+/.
- No shortcut conflicts with Figma's own shortcuts.

---

### GH-052: Performance optimization and rendering budget

**Phase:** 8
**Priority:** P1 (core)
**Dependencies:** GH-008, GH-011
**Estimated Complexity:** L

**Description:**
Performance pass across the entire plugin to ensure smooth interaction even with long conversations and large design systems.

**Targets:**
1. **Message rendering:** Virtualize the message list for conversations > 50 messages. Only render visible messages + 5 above/below buffer. Use `IntersectionObserver`.

2. **Markdown parsing:** Debounce during streaming (100ms intervals). Cache parsed HTML for completed messages. Use `requestIdleCallback` for non-urgent parsing.

3. **DS indexing:** Run in chunks using `setTimeout(fn, 0)` to avoid blocking the sandbox main thread. Show progress indicator.

4. **Usage analysis:** Same chunked approach. Limit to 500 nodes per analysis pass.

5. **State updates:** Batch updates during streaming (accumulate deltas, flush every 100ms).

6. **Memory:** Monitor and cap in-memory conversation size. Compact aggressively for conversations > 100 messages.

7. **Initial load:** Lazy-load non-critical components (settings, prompt studio, affordances). Critical path: app shell + chat panel + input.

**Performance budgets:**
- First meaningful paint: < 500ms.
- Message send to first token: < 1500ms (network dependent).
- Input keystroke latency: < 50ms.
- Scroll smoothness: 60fps.
- DS index for 500 components: < 3s.
- Plugin memory usage: < 100MB.

**Files to create:**
- `ghosti/src/ui/services/virtual-list.ts` (message list virtualization)
- `ghosti/src/ui/services/render-scheduler.ts` (batching, idle callbacks)

**Files to modify:**
- `ghosti/src/ui/components/chat-panel.ts` (virtualized list)
- `ghosti/src/ui/components/markdown-block.ts` (debounced parsing)
- `ghosti/src/plugin/design-system.ts` (chunked indexing)
- `ghosti/src/plugin/usage-analyzer.ts` (chunked analysis)
- `ghosti/src/ui/index.ts` (lazy loading)

**Acceptance Criteria:**
- 100-message conversation scrolls at 60fps.
- Streaming text does not cause layout thrash.
- DS indexing doesn't freeze the Figma UI.
- Plugin initial load is under 500ms.
- Memory stays under 100MB in sustained use.

---

## Cross-Cutting Concerns Summary

| Concern | Primary Tickets | Touches |
|---------|----------------|---------|
| Design tokens / theming | GH-004 | Every UI component |
| Server abstraction | GH-009 | GH-010, GH-028, GH-044 |
| Accessibility | GH-046 | Every UI component |
| Security | GH-047 | GH-008, GH-013, GH-009 |
| Error handling | GH-048 | Every service, every component |
| Performance | GH-052 | GH-008, GH-011, GH-017, GH-024 |
| Dark/light mode | GH-004 | Every UI component |
| Keyboard navigation | GH-051 | Every interactive component |
| Offline support | GH-034 | GH-009, GH-028, GH-030 |
| Multimodal | GH-042-045 | GH-006, GH-011 |

---

## Ticket Count Summary

| Phase | Tickets | IDs |
|-------|---------|-----|
| Phase 1: Scaffold + Chat | 12 | GH-001 through GH-012 |
| Phase 2: Code Execution | 4 | GH-013 through GH-016 |
| Phase 3: DS Index + Read Tools | 7 | GH-017 through GH-023 |
| Phase 4: Usage + Local Context | 4 | GH-024 through GH-027 |
| Phase 5: Vestige Integration | 7 | GH-028 through GH-034 |
| Phase 6: Skills + Hooks | 4 | GH-035 through GH-038 |
| Phase 7: JIT Affordances | 3 | GH-039 through GH-041 |
| Phase 8: Polish + Enterprise | 11 | GH-042 through GH-052 |
| **Total** | **52** | |

---

### Critical Files for Implementation

- `/Users/am/Developer/figma/ghosti/src/shared/protocol.ts` - The message protocol contract between sandbox and UI; every feature depends on these types.
- `/Users/am/Developer/figma/ghosti/src/ui/services/claude.ts` - Claude API streaming client; the core intelligence service that powers all chat and agentic behavior.
- `/Users/am/Developer/figma/ghosti/src/plugin/executor.ts` - Sandbox code execution engine; the most security-sensitive component enabling Claude to manipulate the canvas.
- `/Users/am/Developer/figma/ghosti/src/ui/services/prompt-builder.ts` - System prompt assembler; orchestrates GHOSTI.md, skills, hooks, DS context, Vestige patterns, and local context into Claude's system prompt.
- `/Users/am/Developer/figma/ghosti/src/ui/state/app-state.ts` - Central reactive state; every UI component subscribes to this for data flow.
