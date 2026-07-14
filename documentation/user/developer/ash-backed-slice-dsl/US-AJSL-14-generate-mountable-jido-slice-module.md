# US-AJSL-14 — Generate a mountable Jido slice module

**User-type:** developer **Status:** spec

```gherkin
Given an Ash-backed slice resource with state attributes and signal-bound reducers
When the resource compiles
Then a companion `use Jido.Slice` module exposes the derived state schema and signal routes
```

## Acceptance criteria

- `Jido.Ash.Slice.Info.generated_slice_module/1` returns the companion slice module.
- The companion module is a `Jido.Slice` Spark host.
- `Jido.Dsl.Slice.Info.schema/1`, `signal_routes/1`, and `actions/1` expose the generated state schema and reducer routes.

## Tasks

- [Task 07 — Generate a mountable Jido slice module](../../../../../../docs/tasks/ash-native-jido-slices/07-generate-a-mountable-jido-slice-module.md)

## See also

- [README](./README.md)
