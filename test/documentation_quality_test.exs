defmodule ElixirMixir.DocumentationQualityTest do
  use ExUnit.Case, async: true

  alias Doctor.{ModuleInformation, ModuleReport, ReportUtils}

  setup do
    {config, _bindings} = Code.eval_file(Path.expand("../.doctor.exs", __DIR__))

    report =
      ElixirMixir
      |> Code.fetch_docs()
      |> ModuleInformation.build(ElixirMixir)
      |> ModuleInformation.load_file_ast()
      |> ModuleInformation.load_user_defined_functions()
      |> ModuleReport.build()

    %{config: config, report: report}
  end

  test "accepts the documented and typed public API", %{config: config, report: report} do
    assert ReportUtils.doctor_report_passed?([report], config)
  end

  test "rejects a public API without function documentation", %{config: config, report: report} do
    undocumented = %{report | doc_coverage: Decimal.new(0), missed_docs: report.functions}

    refute ReportUtils.doctor_report_passed?([undocumented], config)
  end

  test "rejects a public API without typespecs", %{config: config, report: report} do
    untyped = %{report | spec_coverage: Decimal.new(0), missed_specs: report.functions}

    refute ReportUtils.doctor_report_passed?([untyped], config)
  end

  test "rejects a module without documentation", %{config: config, report: report} do
    refute ReportUtils.doctor_report_passed?([%{report | has_module_doc: false}], config)
  end
end
