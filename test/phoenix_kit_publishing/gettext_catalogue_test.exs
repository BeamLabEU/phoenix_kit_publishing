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

  describe "split backend (split_module_by: [:locale, :domain])" do
    # The backend compiles one module per locale and domain, in parallel. If
    # the option were dropped, lookups would still pass, so pin the layout:
    # one split module per shipped catalogue.
    test "has one compiled module per shipped locale catalogue" do
      for locale <- ~w(de en es et fr it pl ru uk zh), domain <- ~w(default leaf) do
        module = Module.concat(PhoenixKitPublishing.Gettext, "T_#{locale}_#{domain}")

        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is missing — is split_module_by still set?"
      end
    end

    test "looks up a translated msgid in each shipped locale" do
      # "Publishing" is the admin tab label; en keeps it, the rest translate it.
      expected = %{
        "de" => "Veröffentlichung",
        "en" => "Publishing",
        "et" => "Avaldamine",
        "fr" => "Publication",
        "it" => "Pubblicazione",
        "ru" => "Публикация",
        "es" => "Publicación",
        "pl" => "Publikowanie",
        "uk" => "Публікації",
        "zh" => "发布"
      }

      for {locale, translated} <- expected do
        assert lookup(locale) == translated
      end
    end

    test "an unshipped locale falls back to the msgid" do
      assert lookup("pt") == "Publishing"
    end
  end

  defp lookup(locale) do
    Gettext.with_locale(PhoenixKitPublishing.Gettext, locale, fn ->
      Gettext.dgettext(PhoenixKitPublishing.Gettext, "default", "Publishing")
    end)
  end

  defp pot_msgids(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(~r/^msgid(?:_plural)? "((?:[^"\\]|\\.)*)"$/m, &1))
    |> Enum.map(fn [_, id] -> unescape(id) end)
    |> MapSet.new()
  end

  defp unescape(id), do: id |> String.replace("\\\"", "\"") |> String.replace("\\n", "\n")

  # Lint of the shipped translations themselves. Each of these reached users:
  # `\\"` in et/it/ru showed a backslash before every quote, and gettext
  # serves `fuzzy` entries (a merge's guess) as if they were reviewed.
  describe "shipped catalogues" do
    for locale <- ~w(de es et fr it pl ru uk zh), domain <- ~w(default leaf) do
      @locale locale
      @domain domain

      test "#{locale}/#{domain}: no fuzzy entry, no empty msgstr, no stray backslash" do
        {:ok, po} = Expo.PO.parse_file("priv/gettext/#{@locale}/LC_MESSAGES/#{@domain}.po")

        for message <- po.messages do
          id = Expo.Message.key(message) |> inspect()
          refute "fuzzy" in List.flatten(message.flags), "#{@locale}: fuzzy entry #{id}"

          for string <- msgstrs(message) do
            assert string != "", "#{@locale}: untranslated #{id}"
            refute string =~ "\\", "#{@locale}: backslash in #{id}: #{inspect(string)}"
          end
        end
      end

      test "#{locale}/#{domain}: every placeholder in a msgstr exists in its msgid" do
        {:ok, po} = Expo.PO.parse_file("priv/gettext/#{@locale}/LC_MESSAGES/#{@domain}.po")

        for message <- po.messages do
          allowed = placeholders(msgids(message))

          for string <- msgstrs(message) do
            extra = MapSet.difference(placeholders([string]), allowed)

            assert MapSet.size(extra) == 0,
                   "#{@locale}: #{inspect(MapSet.to_list(extra))} in #{inspect(string)}"
          end
        end
      end
    end
  end

  # Leaf translates its own UI through this backend, "leaf" domain first. A
  # catalogue that lags `leaf.pot` leaves those strings in English.
  describe "the leaf domain" do
    test "every locale's leaf.po holds every msgid of leaf.pot" do
      {:ok, pot} = Expo.PO.parse_file("priv/gettext/leaf.pot")
      ids = MapSet.new(pot.messages, &Expo.Message.key/1)
      assert MapSet.size(ids) > 100

      for locale <- ~w(de en es et fr it pl ru uk zh) do
        {:ok, po} = Expo.PO.parse_file("priv/gettext/#{locale}/LC_MESSAGES/leaf.po")
        missing = MapSet.difference(ids, MapSet.new(po.messages, &Expo.Message.key/1))
        assert MapSet.size(missing) == 0, "#{locale}: #{inspect(MapSet.to_list(missing))}"
      end
    end

    test "Leaf's strings resolve through the backend" do
      translated =
        Gettext.with_locale(PhoenixKitPublishing.Gettext, "de", fn ->
          Gettext.dgettext(PhoenixKitPublishing.Gettext, "leaf", "Bold")
        end)

      refute translated == "Bold"
    end
  end

  defp msgstrs(%Expo.Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp msgstrs(%Expo.Message.Plural{msgstr: msgstr}),
    do: msgstr |> Map.values() |> Enum.map(&IO.iodata_to_binary/1)

  defp msgids(%Expo.Message.Singular{msgid: id}), do: [IO.iodata_to_binary(id)]

  defp msgids(%Expo.Message.Plural{msgid: id, msgid_plural: plural}),
    do: [IO.iodata_to_binary(id), IO.iodata_to_binary(plural)]

  defp placeholders(strings) do
    strings
    |> Enum.flat_map(&Regex.scan(~r/%\{\w+\}/, &1))
    |> List.flatten()
    |> MapSet.new()
  end
end
