# session-persistence Specification

## Purpose
Define the persisted ACP session model used by Agentic.nvim.

## Requirements
### Requirement: Persisted Session Storage

The system SHALL persist ACP session state as a `PersistedSession` identified by
session ID and session timestamp.

#### Scenario: Persist session metadata

- **WHEN** a session is saved
- **THEN** the persisted payload includes `session_id`, `title`, `timestamp`,
  and `current_mode_id`

#### Scenario: Persist ACP config context

- **WHEN** a session is saved
- **THEN** the persisted payload includes `config_options` and
  `available_commands`

#### Scenario: Persist interaction turns

- **WHEN** a session is saved
- **THEN** the persisted payload stores `turns`
- **AND** each turn contains a request, response nodes, and turn result

### Requirement: ACP-Shaped Interaction Model

The system SHALL model session history as ACP prompt turns, not as a flat
message log.

#### Scenario: Request shape

- **WHEN** a user or review request is recorded
- **THEN** it is stored as one interaction request with ACP `content`

#### Scenario: Response shape

- **WHEN** agent output arrives
- **THEN** it is stored under the current turn response as semantic nodes such
  as `message`, `thought`, `plan`, and `tool_call`

#### Scenario: Tool call shape

- **WHEN** a tool call is updated
- **THEN** the interaction tree upserts the corresponding `tool_call` node
- **AND** tool output remains nested under that node rather than flattened into
  sibling transcript entries

### Requirement: Async Disk Persistence

The system SHALL save persisted sessions to disk asynchronously.

#### Scenario: Save asynchronously with callback

- **WHEN** `save(callback)` is called
- **THEN** JSON is written through non-blocking `vim.uv.fs_*` APIs

#### Scenario: Save payload format

- **WHEN** serialization succeeds
- **THEN** the JSON payload includes session metadata, ACP config context, and
  persisted turns

#### Scenario: Load payload format

- **WHEN** a session is loaded from disk
- **THEN** the same persisted turn/config structure is restored into
  `PersistedSession`

### Requirement: Project-Isolated Storage

The system SHALL store persisted sessions under a project-specific cache path.

#### Scenario: Path layout

- **WHEN** generating a save path
- **THEN** the file path is
  `<cache>/agentic/sessions/<normalized_path_hash>/<session_id>.json`

#### Scenario: Per-project discovery

- **WHEN** listing saved sessions
- **THEN** only the current project's normalized cache folder is scanned

### Requirement: Session Restoration

The system SHALL restore persisted ACP turns into runtime session state.

#### Scenario: Restore conflict detection

- **WHEN** the current tab already has a non-empty interaction tree
- **THEN** restoration prompts before replacing the current session

#### Scenario: Restore runtime state

- **WHEN** a persisted session is restored
- **THEN** session state is loaded from persisted metadata, config options,
  available commands, and turns

#### Scenario: Render restored transcript

- **WHEN** restoration completes
- **THEN** `AgenticChat` renders from the interaction tree
- **AND** the interaction tree is the only runtime transcript model

### Requirement: First-Submit Resend

The system SHALL resend restored ACP turns to a fresh provider session on the
next prompt when needed.

#### Scenario: Restore schedules resend

- **WHEN** a persisted session is restored into a fresh ACP session
- **THEN** restored turns are queued for resend on the next submit

#### Scenario: Provider switch schedules resend

- **WHEN** the provider is switched mid-session
- **THEN** the current persisted turns are queued for resend to the new provider

#### Scenario: Resend uses turn content

- **WHEN** resend occurs
- **THEN** the prompt builder prepends restored turns through
  `prepend_restored_turns`
- **AND** the current prompt remains the last request in the submission

### Requirement: Provider Switch Preservation

The system SHALL preserve the current ACP interaction transcript when switching
providers.

#### Scenario: Switch preserves interaction tree

- **WHEN** provider switch completes
- **THEN** the chat transcript remains derived from the same persisted turns
- **AND** a new ACP session is created for the selected provider

#### Scenario: Switch clears provider-local runtime state

- **WHEN** provider switch completes
- **THEN** provider-local runtime state such as active todo items is cleared
- **AND** the prior ACP session is cancelled
