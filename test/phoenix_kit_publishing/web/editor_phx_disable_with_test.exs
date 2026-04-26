defmodule PhoenixKit.Modules.Publishing.Web.EditorPhxDisableWithTest do
  @moduledoc """
  Source-level pinning test for `phx-disable-with` on every async +
  destructive `phx-click` button in `editor.ex`.

  The Editor LV is too coupled (Presence, multi-language post fetch,
  draft graph) to fully boot in a unit test, so we read the heex source
  and verify each `phx-click="<destructive_event>"` line is followed by
  a `phx-disable-with=` attribute. C12 agent #1 caught two
  `clear_featured_image` buttons missing this; the regression would be
  silent without a structural pin.

  Add new entries here when you wire a new destructive `phx-click` —
  keeping the list explicit avoids accidental coverage gaps.
  """

  use ExUnit.Case, async: true

  @editor_source "lib/phoenix_kit_publishing/web/editor.ex"

  # Each entry must appear in editor.ex paired with a `phx-disable-with=` attr
  # within ~10 lines (button blocks are typically 4-8 lines). The pairing is
  # what's load-bearing — the catch-all `clear_featured_image` regression was
  # the desktop+mobile copy each missing the attr.
  @destructive_events ~w(
    clear_featured_image
    clear_translation
  )

  setup do
    {:ok, source} = File.read(@editor_source)
    %{source: source}
  end

  for event <- @destructive_events do
    test "every phx-click=#{inspect(event)} has phx-disable-with within 10 lines",
         %{source: source} do
      lines = String.split(source, "\n")

      indices =
        lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _idx} -> line =~ ~s|phx-click="#{unquote(event)}"| end)
        |> Enum.map(fn {_, idx} -> idx end)

      assert indices != [],
             "expected at least one phx-click=\"#{unquote(event)}\" in #{@editor_source}; " <>
               "remove this entry from @destructive_events if the event is gone"

      for idx <- indices do
        window = Enum.slice(lines, idx, 10) |> Enum.join("\n")

        assert window =~ "phx-disable-with",
               "phx-click=\"#{unquote(event)}\" at line #{idx + 1} of #{@editor_source} " <>
                 "lacks phx-disable-with within 10 lines\n\nwindow:\n#{window}"
      end
    end
  end
end
