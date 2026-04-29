[
  # Pre-existing warning in req_llm dep — Unknown type LLMDB.Model.t/0.
  # The dep declares a type that resolves through llm_db, which dialyzer
  # cannot follow without llm_db's PLT. Out-of-tree, not actionable here.
  {"lib/req_llm.ex", :unknown_type}
]
