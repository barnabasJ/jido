spark_locals_without_parens = [
  category: 1,
  data: 1,
  default_slices: 1,
  description: 1,
  job_id: 1,
  match: 1,
  name: 1,
  otp_app: 1,
  path: 1,
  priority: 1,
  route: 2,
  route: 3,
  schedule: 2,
  schedule: 3,
  schema: 1,
  static: 1,
  storage: 1,
  tags: 1,
  timezone: 1,
  vsn: 1
]

# Used by "mix format"
[
  import_deps: [:spark],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
