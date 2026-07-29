defmodule PhoenixKit.Modules.Publishing.Web.EditorAutosaveCancelTest do
  @moduledoc """
  Source-level pin: every context switch that REPLACES the editor's buffer
  must cancel a queued autosave first.

  `apply_version_switch` / `do_switch_language` clear `has_pending_changes`
  and swap the content, so a timer still armed across the switch fires into
  the new context and quietly discards up to a second of typing — no error,
  no prompt. The language path always cancelled; the version path did not.

  Pinned at the source like `editor_phx_disable_with_test.exs`, because the
  event itself ends in a `push_patch` to a locale-prefixed path that the test
  router won't accept as the same root view, so the LV can't be driven
  through the switch in a unit test.
  """

  use ExUnit.Case, async: true

  @editor_source "lib/phoenix_kit_publishing/web/editor.ex"

  setup do
    {:ok, source: File.read!(@editor_source)}
  end

  test "the shared cancel helper exists and clears the assign", %{source: source} do
    assert source =~ "defp cancel_autosave_timer(socket) do"
    assert source =~ "Process.cancel_timer(timer)"
    assert source =~ "assign(socket, :autosave_timer, nil)"
  end

  test "both buffer-replacing switches cancel before switching", %{source: source} do
    # switch_version: the cancel must sit between the clause head and the read.
    marker = "def handle_event(\"switch_version\""
    [_, after_head] = String.split(source, marker, parts: 2)
    [switch_clause, _] = String.split(after_head, "def handle_event(", parts: 2)
    assert switch_clause =~ "cancel_autosave_timer(socket)"

    [_, after_lang] =
      String.split(source, "defp do_switch_language(socket, new_language) do", parts: 2)

    assert after_lang |> String.slice(0, 400) =~ "cancel_autosave_timer(socket)"
  end
end
