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

  @translation_source "lib/phoenix_kit_publishing/web/editor/translation.ex"

  setup do
    {:ok, source: File.read!(@editor_source)}
  end

  defp source_for("def do_enqueue_translation" <> _), do: File.read!(@translation_source)
  defp source_for(_site), do: File.read!(@editor_source)

  test "the shared cancel helper exists and clears the assign", %{source: source} do
    assert source =~ "defp cancel_autosave_timer(socket) do"
    assert source =~ "Process.cancel_timer(timer)"
    assert source =~ "assign(socket, :autosave_timer, nil)"
  end

  test "a version switch SAVES outstanding work before replacing the buffer", %{source: source} do
    # Cancelling the timer alone only stops a wrong-context save — the edits are
    # still discarded. The switch has to try to flush first and stay put if it
    # can't, the same policy "preview" uses. (A reviewer rightly called the
    # earlier cancel-only pin out for encoding "dropping the work is fine".)
    [_, after_head] = String.split(source, "def handle_event(\"switch_version\"", parts: 2)
    [switch_clause, _] = String.split(after_head, "def handle_event(", parts: 2)

    assert switch_clause =~ "flush_before_switch(socket)"
    assert switch_clause =~ "{:blocked, socket} ->"

    # The flush must never run for a read-only spectator, whose buffer is stale
    # and would clobber the owner.
    [_, flush] = String.split(source, "defp flush_before_switch(socket) do", parts: 2)
    flush = String.slice(flush, 0, 500)

    assert flush =~ "not socket.assigns[:readonly?]"
    assert flush =~ "Persistence.perform_save(socket)"
    assert flush =~ ":blocked"
  end

  test "every buffer-replacing navigation flushes first", %{source: source} do
    # The gap recurred once already — version switch was fixed and language
    # switch was missed — so pin the whole set rather than one path.
    for site <- [
          "def handle_event(\"switch_language\"",
          "def handle_event(\"create_version_from_source\", _params, socket) do",
          "def do_enqueue_translation(socket, target_languages) do"
        ] do
      [_, after_site] = String.split(source_for(site), site, parts: 2)
      [clause, _] = String.split(after_site <> "\nSENTINEL", "SENTINEL", parts: 2)
      assert clause =~ "flush", "expected #{site} to flush pending edits first"
    end
  end

  test "both buffer-replacing switches still cancel the queued timer", %{source: source} do
    [_, after_version] =
      String.split(source, "defp do_switch_version(socket, version) do", parts: 2)

    assert after_version |> String.slice(0, 300) =~ "cancel_autosave_timer(socket)"

    [_, after_lang] =
      String.split(source, "defp do_switch_language(socket, new_language) do", parts: 2)

    assert after_lang |> String.slice(0, 300) =~ "cancel_autosave_timer(socket)"
  end
end
