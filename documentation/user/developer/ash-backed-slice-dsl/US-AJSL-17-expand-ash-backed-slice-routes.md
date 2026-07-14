# US-AJSL-17 — Expand Ash-backed slice routes

**User-type:** developer **Status:** spec

```gherkin
Given a Jido agent mounting an Ash-backed slice resource
When the agent route table is compiled
Then the generated slice routes point to generated reducer actions and retain the agent-owned mount path
```

## Acceptance criteria

- Generated reducer action targets appear in the agent route table.
- `slice_paths_for_action/1` maps generated actions to the path declared by the agent.
- Resource-backed and hand-authored slice mounts can coexist in one agent.

## Tasks

- [Task 08 — Teach Jido.Agent to mount Ash-backed slices](../../../../../../docs/tasks/ash-native-jido-slices/08-teach-jido-agent-to-mount-ash-backed-slices.md)

## See also

- [README](./README.md)
