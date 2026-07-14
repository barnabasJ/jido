# US-AJSL-15 — Preserve hand-authored slice introspection

**User-type:** developer **Status:** spec

```gherkin
Given existing hand-authored Jido slices
When Ash-backed slice modules are generated elsewhere
Then the existing slice Info APIs continue to return their hand-authored DSL metadata
```

## Acceptance criteria

- Existing `use Jido.Slice` modules remain valid Spark hosts.
- Existing route and action introspection is unchanged by Ash-backed generation.

## Tasks

- [Task 07 — Generate a mountable Jido slice module](../../../../../../docs/tasks/ash-native-jido-slices/07-generate-a-mountable-jido-slice-module.md)

## See also

- [README](./README.md)
