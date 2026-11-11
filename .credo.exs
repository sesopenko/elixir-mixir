%{
  configs: [
    %{
      name: "default",
      files: %{included: ["mix.exs", "lib/", "test/", "config/"], excluded: []},
      strict: true
    }
  ]
}
