defmodule PhoenixKit.Modules.Publishing.Web.ClientEventsTest do
  @moduledoc """
  Every event this module pushes to the browser has a listener.

  A `push_event/3` is fire-and-forget: when its JavaScript listener goes
  away the call still succeeds, nothing logs, and the suite cannot tell. The
  post editor kept pushing four events of core's MarkdownEditor hook for two
  months after the move to Leaf — "set-content" among them, which is how a
  language switch left the previous text on screen. This pins the set of
  event names to the listeners the admin pages actually mount.
  """

  use ExUnit.Case, async: true

  # Event name => the hook that handles it, and where it is mounted.
  @listeners %{
    # core's SearchPicker hook, via `results_event` on <.search_picker>
    "category_results" => "PhoenixKitHooks.SearchPicker (categories_picker.ex)"
  }

  test "every pushed event name has a listener on the page that pushes it" do
    pushed =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/push_event\(\s*"([^"]+)"/, File.read!(file))
        |> Enum.map(fn [_, name] -> {name, file} end)
      end)

    assert pushed != [], "no push_event calls found — the scan is broken"

    for {name, file} <- pushed do
      assert Map.has_key?(@listeners, name),
             "#{file} pushes #{inspect(name)}, which no hook on these pages handles — " <>
               "talk to Leaf through send_update, or register the listener in @listeners"
    end
  end

  test "the listed listeners exist in core's bundle" do
    bundle = File.read!("deps/phoenix_kit/priv/static/assets/phoenix_kit.js")

    # SearchPicker reads its event names from data attributes rather than
    # literal handleEvent("…") calls, so the hook itself is what must exist.
    assert bundle =~ "SearchPicker"
  end
end
