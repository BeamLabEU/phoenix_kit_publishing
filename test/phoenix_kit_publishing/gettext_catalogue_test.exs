defmodule PhoenixKitPublishing.GettextCatalogueTest do
  @moduledoc """
  Every string the code translates exists in the catalogue.

  Comparing `.po` files to each other, or counting empty `msgstr`s, cannot
  see a string that never reached any catalogue: it renders raw English in
  every locale while every count says "complete". This diffs the literal
  msgids in `lib/` against `priv/gettext/default.pot`, so a new string that
  was not followed by `mix gettext.extract --merge` fails here.

  Only literal calls are visible to the extractor AND to this scan; a
  `gettext(variable)` is invisible to both and must become a literal-call
  helper (AGENTS.md, Gettext).
  """

  use ExUnit.Case, async: true

  @call ~r/\b(?:d|dn|n|dp|p|dpn|pn)?gettext(?:_noop)?\(\s*(?:"[^"]+"\s*,\s*)?"((?:[^"\\]|\\.)*)"/

  test "every literal msgid in lib/ is in the .pot" do
    known = pot_msgids("priv/gettext/default.pot")
    assert MapSet.size(known) > 100, "the .pot did not parse"

    missing =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> then(&Regex.scan(@call, &1))
        |> Enum.map(fn [_, id] -> {unescape(id), file} end)
      end)
      |> Enum.reject(fn {id, _} -> MapSet.member?(known, id) end)
      |> Enum.uniq()

    assert missing == [],
           "msgids used in code but absent from default.pot (run `mix gettext.extract --merge`, " <>
             "then diff the new msgids against the pre-merge .po files):\n" <>
             Enum.map_join(missing, "\n", fn {id, file} -> "  #{file}: #{inspect(id)}" end)
  end

  defp pot_msgids(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(~r/^msgid(?:_plural)? "((?:[^"\\]|\\.)*)"$/m, &1))
    |> Enum.map(fn [_, id] -> unescape(id) end)
    |> MapSet.new()
  end

  defp unescape(id), do: id |> String.replace("\\\"", "\"") |> String.replace("\\n", "\n")
end
