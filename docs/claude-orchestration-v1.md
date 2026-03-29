# Claude Orchestration V1 for lil-agents

## Goal
Improve Claude quality, resilience, and quota efficiency through app-side orchestration without changing the model.

## Product Outcomes
- Fewer hard-stop sessions caused by limit exhaustion
- Better answer quality in long conversations
- Faster recovery and handoff when a limit is reached
- More consistent behavior across Claude, Codex, and Copilot providers

## V1 Scope
- In scope:
  - Stable memory and transient memory split
  - Turn budget estimation and policy switching
  - Prompt assembly pipeline with compact context
  - Better handoff packet generation
  - Session telemetry signals for tuning
- Out of scope:
  - Direct provider quota APIs
  - Model fine-tuning
  - Cloud sync

## Architecture Overview
The orchestration layer sits between Terminal input and provider session send.

### Main Components
1. MemoryStore
- stableFacts: durable constraints and preferences
- recentTurns: short rolling window of recent user and assistant turns
- compressedHistory: evolving summary of older turns

2. BudgetManager
- Estimates conversation growth using character-count heuristics
- Controls policy mode:
  - fullHistory mode
  - compressedHistory mode
  - emergency mode near limit

3. PromptAssembler
- Builds final provider input from:
  - session objective
  - stableFacts
  - compressedHistory
  - recentTurns
  - latest user message
- Applies task-specific wrapper style for debugging, coding, planning, and review

4. HandoffBuilder
- Produces structured packet with:
  - Objective
  - Decisions made and why
  - Files touched and key changes
  - Remaining tasks in priority order
  - Risks and test checklist

5. SignalTracker
- Captures lightweight signals:
  - turn count
  - summary refresh count
  - rate-limit warnings seen
  - error streak

## Data Model V1
1. ConversationTurn
- role: user | assistant | toolUse | toolResult | error
- text: String
- timestamp: Date

2. SessionMemory
- stableFacts: [String]
- compressedHistory: String
- recentTurns: [ConversationTurn]
- objective: String

3. BudgetState
- mode: fullHistory | compressedHistory | emergency
- estimatedChars: Int
- softThreshold: Int
- hardThreshold: Int

## Policy Rules
1. Mode switching
- fullHistory while estimatedChars < softThreshold
- compressedHistory when estimatedChars >= softThreshold
- emergency mode when near hardThreshold or explicit limit signal appears

2. Compression schedule
- Refresh compressedHistory every N user turns or when mode changes
- Keep recentTurns to the most recent K user/assistant pairs

3. Emergency mode behavior
- Aggressive context trimming
- Enable handoff reminder if not already handled
- Prefer concise response instruction to reduce token usage

## Prompt Assembly V1
Order matters and should remain stable:
1. Objective line
2. Stable facts block
3. Compressed history block
4. Recent turns block
5. Latest user message
6. Response style guardrails

## Integration Points in Current Code
1. WalkerCharacter
- Intercept outbound user messages before session.send
- Run BudgetManager update and PromptAssembler build
- Keep existing Y/N smart handoff flow, now fed by richer memory

2. AgentSession implementations
- Keep provider launch and IO parsing unchanged in V1
- Only replace outgoing text payload with assembled prompt string

3. TerminalView
- No major UI changes required for V1
- Optional: add a small mode badge (full, compressed, emergency)

## Minimal File Changes Plan
1. Add new file: LilAgents/ConversationOrchestrator.swift
- Holds MemoryStore, BudgetManager, PromptAssembler, HandoffBuilder, SignalTracker

2. Update: LilAgents/WalkerCharacter.swift
- Create one orchestrator per active session
- On each user message:
  - feed turn into orchestrator
  - get assembled outbound prompt
  - send assembled prompt instead of raw message
- On assistant completion and errors:
  - feed signals back to orchestrator

3. Keep existing provider files mostly untouched
- LilAgents/ClaudeSession.swift
- LilAgents/CodexSession.swift
- LilAgents/CopilotSession.swift

## Suggested Defaults for V1
- recentTurns window: last 6 user+assistant turns
- softThreshold: 12000 estimated chars
- hardThreshold: 22000 estimated chars
- summary refresh: every 4 user turns in compressed mode

## Migration Strategy
1. Phase 1: instrumentation only
- Collect metrics without changing prompt payload

2. Phase 2: soft rollout
- Enable compressed mode for Claude only
- Keep fallback toggle to disable orchestration quickly

3. Phase 3: generalize
- Enable for Codex and Copilot paths
- Tune thresholds per provider

## Success Metrics
- Reduction in sessions ending from limit errors
- Increased average successful turns per session
- Lower user-reported context loss
- Better handoff usefulness score (qualitative)

## Risks and Mitigations
1. Over-compression can remove critical details
- Mitigation: preserve stableFacts and recentTurns window

2. Heuristic budget can be inaccurate
- Mitigation: conservative thresholds and emergency fallback

3. Prompt assembly can become too verbose
- Mitigation: enforce maximum assembled char budget with truncation order

## Next Build Steps
1. Implement ConversationOrchestrator.swift skeleton with unit-testable pure functions
2. Wire WalkerCharacter outbound path to orchestrator
3. Add simple debug logging for mode transitions
4. Validate with long manual conversations and edge-case prompts
