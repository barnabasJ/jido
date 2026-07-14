# US-AJSL-01 — Declare an Ash-backed slice resource

**User-type:** developer **Status:** spec

```gherkin
Given an Ash resource that uses `extensions: [Jido.Ash.Slice]`
When the resource declares a `jido_slice` block with metadata and a signal binding
Then the resource compiles successfully
And the declaration is available for later slice generation
```

## Acceptance criteria

- A resource can declare `jido_slice do name ... end`.
- A resource can declare `signal "type", :action` inside the block.
- The DSL stores declarations only; it does not generate runtime slice modules in
  this story.

## Notes

- **Reference / related code:** `Jido.Ash.Slice`.
- **Size:** One Spark/Ash resource extension and entity structs.

## Tasks

- [Task 03 — Add Ash-backed slice DSL structs and Info](../../../../../../docs/tasks/ash-native-jido-slices/03-add-ash-backed-slice-dsl-info.md)

## See also

- [README](./README.md)
