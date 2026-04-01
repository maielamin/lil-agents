# lil-agents Architecture Summary

## 1. Current Session/Provider Architecture

### Three Provider System
The app supports three AI providers via a **factory pattern** (`AgentProvider` enum):

- **Claude** (`ClaudeSession.swift`)
  - Launches local Claude CLI via process (`claude -p --output-format stream-json --input-format stream-json`)
  - Uses NDJSON (newline-delimited JSON) for bidirectional communication
  - Supports MCP (Model Context Protocol) config at `~/.lil-agents-mcp.json`
  - Has special modes: **Power Mode** (skip permission prompts) and **Saver Mode** (concise responses)
  - Includes Gmail hint injection for email-related queries

- **Codex** (`CodexSession.swift`)
  - Launches via `codex exec --json --full-auto`
  - Also uses NDJSON format for output parsing
  - Implements message windowing: keeps recent 14 messages, summarizes older ones
  - Per-message char limit: 420 chars (compaction strategy)

- **Copilot** (`CopilotSession.swift`)
  - Launches via `copilot -p <message> [--continue]` (stateful across turns)
  - Supports both JSON and plain-text output formats
  - Uses `--output-format json` for structured responses

### Provider Selection
- Stored in `UserDefaults` under key `"selectedProvider"`
- Switchable via menu bar (hotkeys 1, 2, 3)
- Each session instance implements the `AgentSession` protocol

---

## 2. How Agents Currently Output Text

### Output Flow Pipeline
```
AgentSession (process.stdout) 
  → NDJSON/JSON parsing line buffer 
  → onText callback 
  → TerminalView.appendStreamingText() 
  → NSTextView + syntax highlighting
```

### Session Protocol (AgentSession.swift)
Each session defines these key callbacks:

```swift
var onText: ((String) -> Void)?              // Streaming text chunks
var onError: ((String) -> Void)?             // Error messages
var onToolUse: ((String, [String: Any]) -> Void)?    // Tool invocations (Claude)
var onToolResult: ((String, Bool) -> Void)? // Tool results
var onSessionReady: (() -> Void)?            // Session initialized
var onTurnComplete: (() -> Void)?            // Turn finished
var onProcessExit: (() -> Void)?             // Process terminated
```

### Text Output Destinations

1. **Main Terminal Display** (NSTextView in popover)
   - Uses `TerminalView.appendStreamingText(text)` for live streaming
   - Non-blocking; accumulates text in real-time as provider responds
   - Called directly from session's `onText` callback

2. **Clipboard (Pasteboard)**
   - **Handoff Summary** (`/handoff` command):
     - Generates structured summary (objective, decisions, files, risks)
     - Copies to `NSPasteboard.general` automatically
     - User is notified: "Handoff summary copied to clipboard."
   
   - **Export Conversation** (`/export` command):
     - Generates markdown export of entire conversation
     - Writes to `~/Documents/lil-agents-export-YYYY-MM-DD-HHmmss.md`
     - **Also copies to clipboard**
     - Uses regex to extract file paths from conversation history

3. **Desktop File System**
   - Export writes markdown to `DocumentsDirectory` as fallback

### Message History
- Stored in session's `history: [AgentMessage]` array
- Max 400 messages per session (see `appendBounded`)
- Each message has: `role` (.user, .assistant, .error, .toolUse, .toolResult), `text`, `timestamp`

---

## 3. Existing Integration & Connection Mechanisms

### External App Communication

Currently **NO direct VS Code or external tool integration exists yet**. The app operates as a standalone macOS tool.

#### What DOES exist:

1. **Clipboard/Pasteboard Bridge** (NSPasteboard)
   - Handoff summaries and exports are copied to system clipboard
   - User must manually paste into target app
   - Location: `WalkerCharacter.copyToClipboard(_:)` method

2. **File System Export**
   - Markdown files written to `~/Documents/`
   - Can be opened in external editors manually

3. **Process Spawning** (for local CLIs)
   - All three providers are launched as local CLI processes
   - Input: STDIN pipe with JSON
   - Output: STDOUT NDJSON stream
   - Error: STDERR capture

4. **Shell Environment Capture** (ShellEnvironment.swift)
   - Resolves user's login shell environment (`zsh -l -i`)
   - Finds binaries in PATH + fallback locations
   - Injects essential paths: `~/.local/bin`, `/opt/homebrew/bin`, etc.

#### What DOES NOT exist for external apps:
- NSWorkspace app launching
- URL schemes
- Inter-process communication (IPC) to external tools
- Applescript/JXA execution
- File system watchers for handoff files

---

## 4. Popover/UI Structure & User Input

### UI Architecture

```
MenuBar (NSStatusBar)
  ↓
LilAgentsController
  ├── WalkerCharacter (x2: Bruce, Jazz)
  │   ├── Character Window (NSWindow)
  │   │   └── CharacterContentView
  │   │       └── AVPlayerLayer (animated character)
  │   │
  │   ├── Popover Window (NSPanel, floating, .nonactivatingPanel)
  │   │   └── TerminalView
  │   │       ├── Scroll View (conversation display)
  │   │       │   └── NSTextView (scrollable chat history)
  │   │       ├── Input Area
  │   │       │   ├── ChatInputTextView (multi-line, responds to completion)
  │   │       │   ├── InputPlaceholderLabel
  │   │       │   └── ModeBadge (shows active command mode)
  │   │       └── Palette (command menu, slides up when `/` typed)
  │   │
  │   ├── Thinking Bubble (optional .nonactivatingPanel)
  │   │   └── "Thinking..." indicator while agent is busy
  │   │
  │   └── Completion Bubble (speech bubble with text)
  │       └── Small popup near character
  │
  └── Debug Window (red line at dock position, dev only)
```

### Click & Drag Behavior

**Single Click (short)**
- If onboarding: opens welcome popover
- If popover open: closes it
- If popover closed: opens it

**Long Press (0.18s)**
- Character "lifts" (animated +18pt)
- Enables dragging across dock area
- Release drops character back

### Input Handling (ChatInputTextView)

```swift
class ChatInputTextView: NSTextView {
    // Keyboard events:
    - Escape (key 53):    Dismiss command palette
    - Up arrow (126):     Move palette selection up
    - Down arrow (125):   Move palette selection down
    - Return (36) / ↵ (76): 
        If palette open: activate selected command
        Else: submit message to session
    - Shift+Return:       New line (no submit)
}
```

### Terminal View Components

1. **Conversation Display** (NSTextView)
   - Receives streaming text via `appendStreamingText()`
   - Color-coded by role:
     - User messages: default color
     - Assistant: styled (role-specific)
     - Errors: red/warning color
     - Tools: compact inline format
   - Syntax highlighting via attributed strings

2. **Input Field**
   - Placeholder: "Ask Claude…" / "Ask Codex…" / "Ask Copilot…"
   - Editable NSTextView with custom cell padding
   - Multi-line with scroll up to max height
   - Triggers on Return key

3. **Command Palette**
   - Appears when user types `/`
   - Shows available commands with hints
   - Keyboard navigation: ↑↓ to select, Return to execute
   - Commands: `/debug`, `/refactor`, `/explore`, `/reflect`, `/brainstorm`, `/clear`, `/export`, `/handoff`, `/wake`, `/mode off`, custom commands

4. **Mode Badge**
   - Small indicator showing active command mode (e.g., "● debug mode")
   - Persists across messages during mode
   - Cleared with `/mode off`

5. **Toast Notifications**
   - Brief text alerts at bottom of popover
   - Auto-dismiss (no manual action)

### Popover Positioning

- Anchored to character's mid-point horizontally
- Positioned just above character window
- Respects screen boundaries (won't clip off screen)
- Uses `NSScreen.main` for bounds checking

### Character Persona & System Prompts

- **Bruce**: "You are Bruce, a direct and concise coding assistant..."
- **Jazz**: "You are Jazz, a friendly and enthusiastic AI assistant..."
- Injected as `SYSTEM:` prefix on first message of session

---

## 5. Command System & Modes

### Built-in Commands

1. **Command Modes** (toggle via `/mode <name>`)
   - `/debug` → Clinical, terse troubleshooting (Bruce)
   - `/refactor` → Code improvement focused (Bruce)
   - `/explore` → Expansive brainstorming (Jazz)
   - `/reflect` → Deep meditation on topic (Jazz)
   - `/brainstorm` → Rapid ideation, 5-7 ideas (Jazz)
   - `/mode off` → Exit current mode

2. **Session Commands**
   - `/clear` → New chat (requires confirmation to prevent data loss)
   - `/handoff` → Generate handoff summary, copy to clipboard
   - `/export` → Export conversation to markdown file + clipboard
   - `/wake` → Resume after sleep mode
   - `/commands` → List available commands

3. **Custom Commands** (user-defined)
   - `/command add /name | hint | response` → Create custom command
   - `/command remove /name` → Delete custom command
   - Stored in `~/Library/Application Support/lil-agents-commands.json`

### Command Execution Flow

```
User types message → TerminalView.onSendMessage
  ↓
WalkerCharacter.handleMessageInput()
  ├─ Check if command (CommandRegistry.shared.handleCommand)
  │  ├─ Built-in command? Execute (debug, refactor, etc.)
  │  ├─ Custom command? Load from disk & execute
  │  └─ No command match? Proceed to agent
  │
  ├─ Handoff flow (if `/handoff` or prompt pending)
  │  └─ Stage message in ConversationOrchestrator
  │  └─ Generate structured summary
  │  └─ Copy to clipboard
  │
  ├─ Orchestration layer (if enabled)
  │  └─ Feed to ConversationOrchestrator
  │  └─ Assemble prompt with compressed history
  │  └─ Send assembled prompt to session
  │
  └─ Direct send (if orchestration disabled)
     └─ Send raw message to session
```

### Active Mode System

When a command mode is active:
- Mode name stored in `activeCommandMode`
- System instruction stored in `activeCommandPrompt`
- **Injected prefix on every message**: `[MODE: DEBUG]\n<instruction>\n\nUser: <message>`
- Until `/mode off` is called

---

## 6. Conversation Orchestration (V1)

### ConversationOrchestrator.swift

Sits between user input and session.send() to manage:

**Budget Management**
- Soft threshold: 12,000 estimated chars
- Hard threshold: 22,000 estimated chars
- Tracks total user + assistant chars
- Switches modes: `fullHistory` → `compressedHistory` → `emergency`

**Session Memory**
- `stableFacts`: Durable constraints
- `recentTurns`: Last 6 user/assistant pairs
- `compressedHistory`: Summary of older turns (refreshed every 4 user turns)

**Prompt Assembly**
- Builds final prompt by combining:
  1. Session objective
  2. Stable facts block
  3. Compressed history
  4. Recent turns
  5. Latest user message
  6. Response style guardrails

**Handoff Summary Generation**
- Extracts objective from first user message
- Highlights last 3 assistant responses
- Uses regex to find file paths in conversation
- Identifies risks from error history
- Structures as: Objective | Decisions | Files | Remaining Tasks | Risks

### Usage Tracking

```swift
struct UsageState {
    var totalUserChars: Int
    var totalAssistantChars: Int
    var turnCount: Int
    var errorStreak: Int
    var limitSignalsSeen: Int
    var sessionStartedAt: Date
}
```

Persisted to `UserDefaults` per provider.

---

## 7. Key Design Patterns

### Provider Abstraction
- `AgentProvider` enum handles switching
- All sessions implement `AgentSession` protocol
- Same callback interface across Claude, Codex, Copilot

### Clipboard Output
- **Single mechanical pattern**: Copy + User notification
- Used for: handoff summaries, exports, any shareable text
- No external app integration; manual copy-paste workflow

### Asynchronous Callback Model
- Sessions emit `onText`, `onError`, `onToolUse` callbacks
- TerminalView subscribed to all callbacks
- Updates flow on main thread via `DispatchQueue.main.async`

### Process Spawning & Pipe IO
- Standard Unix pipes for stdin/stdout/stderr
- Readability handlers for non-blocking reads
- Line-buffered parsing for NDJSON/JSON
- Process termination handlers for cleanup

### Theme & Customization
- PopoverTheme system with multiple color schemes
- Character personas (Bruce vs Jazz) with distinct system prompts
- Mode badges for visual state indication

---

## 8. Data & Persistence

### UserDefaults Storage
- Selected provider
- Character visibility toggle
- Sound toggle
- Theme preference
- Command mode preferences (smart reminder on/off per provider)
- Orchestration mode (full vs compressed vs emergency)
- Power/Saver mode flags (Claude only)

### File Storage
- `~/Documents/lil-agents-export-*.md` (exports)
- `~/Library/Application Support/lil-agents-commands.json` (custom commands)
- `~/.lil-agents-mcp.json` (MCP config, optional)

### Memory Limits
- Session history: max 400 messages (per session)
- Codex recent window: 14 messages
- Copilot message compression: 420 chars/message

---

## 9. External Integration Gaps & Opportunities

### Currently NOT Integrated:
- VS Code / Code editor extensions
- GitHub Copilot (separate from Copilot CLI)
- Slack, Discord, or messaging apps
- IDEs (Xcode, IntelliJ, etc.)
- Git workflows
- Terminal/shell output capture
- File system watching

### Existing Patterns for Future Integration:
1. **Clipboard bridge** (ready to use for handoff to external apps)
2. **Process spawning** (could run scripts that feed data back)
3. **Callback system** (onText, onToolUse extensible to webhooks)
4. **File export** (can be picked up by other tools)
5. **Shell environment** (has PATH setup for external tools)

### Potential Integration Points:
- NSWorkspace to launch external editors with outputs
- File system observer to detect handoff file changes
- Named pipes or sockets for inter-process communication
- Applescript/JXA for tight OS integration
- URL schemes (myapp://command) for deep linking from other apps

---

## Summary Table

| Aspect | Current State |
|--------|---------------|
| **Providers** | Claude, Codex, Copilot (CLI-based) |
| **Output Mechanism** | Clipboard (pasteboard), File export, TerminalView display |
| **External Apps** | None (manual copy-paste workflow required) |
| **UI** | Character window + floating popover with chat |
| **Input** | Text input, command palette, mode selection |
| **Persistence** | UserDefaults, JSON files, markdown exports |
| **Architecture** | Process pipes, callback-driven, single-window per character |

