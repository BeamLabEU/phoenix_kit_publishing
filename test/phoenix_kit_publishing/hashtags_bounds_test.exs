defmodule PhoenixKit.Modules.Publishing.HashtagsBoundsTest do
  @moduledoc """
  Hashtag derivation runs on every save and every public render, so its cost
  must stay linear in the body size, and the bounded link mask must not change
  what a normal body extracts.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Hashtags

  # The masked-region regex as it was before the link alternative got bounded
  # quantifiers. Kept as a reference to prove the bound changes nothing for a
  # body whose links fit the bound.
  @old_masked_regions ~r{```.*?```|~~~.*?~~~|```.*|~~~.*|``[^\n]+?``|`(?:[^`\n]|\n(?!\n))*`|!?\[[^\]\n]*\]\([^)\n]*\)|<(CTA|Headline|Subheadline|Video|Audio|EntityForm)\b[^>]*>.*?</\1>|<[A-Za-z][A-Za-z0-9-]*\b[^>]*>}s
  @hashtag ~r/(^|[\s(])#(\p{L}[\p{L}\p{N}_-]{0,29})(?![\p{L}\p{N}_-])/u

  defp old_extract(content) do
    stripped = Regex.replace(@old_masked_regions, content, "\x00")

    @hashtag
    |> Regex.scan(stripped, capture: :all_but_first)
    |> Enum.map(fn [_lead, tag] -> tag end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(20)
  end

  @representative [
    "#lead mid #two (#three)\n#four",
    "See [jump](#section) and [read about #elixir](https://x.com), then #real.",
    "![alt #pic](/img.png) and #after",
    "[![badge #x](https://b.example/x.svg)](https://example.com) #real",
    "Text [a](http://x.example/a#frag) #one [b](http://x.example/b) #two",
    "`code #no` and ``double #no`` and #yes\n```\n#fenced\n```\n#tail",
    "[unclosed link #tag and more\n#next line",
    "[text](unclosed destination #tag\n#next line",
    "[a [nested] link #hidden](http://x.example) #shown",
    "<Image alt=\"see #elixir\" /> prose #real <Video>cap #hidden</Video>",
    "~~~\n#in\n~~~ #out",
    "plain [bracket] and (paren) #tag",
    "#Uudised #uudised #новости [x](y) #a1-b_2"
  ]

  # Fails fast instead of hanging the suite when the cost is not linear.
  defp within(ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> {:ok, value}
      _ -> :timeout
    end
  end

  describe "bounded link mask" do
    test "extracts exactly what the unbounded mask extracted for representative bodies" do
      for body <- @representative do
        assert Hashtags.extract(body) == old_extract(body), "differs for #{inspect(body)}"
      end
    end

    test "a link whose text and destination are within the bound is still masked" do
      body = "[#{String.duplicate("t", 900)} #hidden](#{String.duplicate("u", 1900)}) #shown"

      assert Hashtags.extract(body) == ["shown"]
    end

    for {name, unit} <- [
          {"[", "["},
          {"![", "!["},
          {"[a](", "[a]("},
          {"[a](b", "[a](b"},
          {"](", "]("}
        ] do
      test "extract stays fast on the largest body of #{name} runs" do
        body = String.duplicate(unquote(unit), div(262_144, String.length(unquote(unit))))

        result = within(3_000, fn -> Hashtags.extract(body) end)
        assert result == {:ok, []}
      end

      test "linkify stays fast on the largest body of #{name} runs" do
        body = String.duplicate(unquote(unit), div(262_144, String.length(unquote(unit))))

        result = within(3_000, fn -> Hashtags.linkify(body, &"/t/#{&1}") end)
        assert result != :timeout
        {:ok, linked} = result
        unchanged? = linked == body
        assert unchanged?
      end
    end
  end

  describe "linkify/2 on a hashtag flood" do
    test "builds the link for a tag once, however often the tag occurs" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      body = String.duplicate("#a ", 5_000)

      linked =
        Hashtags.linkify(body, fn tag ->
          Agent.update(counter, &(&1 + 1))
          "/t/#{tag}"
        end)

      assert Agent.get(counter, & &1) == 1
      linked? = linked == String.duplicate("[#a](/t/a) ", 5_000)
      assert linked?
    end

    test "keeps one link per spelling" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      linked =
        Hashtags.linkify("#Elixir #elixir #Elixir", fn tag ->
          Agent.update(counter, &(&1 + 1))
          "/t/#{tag}"
        end)

      assert linked == "[#Elixir](/t/Elixir) [#elixir](/t/elixir) [#Elixir](/t/Elixir)"
      assert Agent.get(counter, & &1) == 2
    end

    test "a 120 KB flood links in bounded time" do
      body = String.duplicate("#a ", 40_000)

      result = within(3_000, fn -> Hashtags.linkify(body, &"/t/#{&1}") end)
      assert result != :timeout
      {:ok, linked} = result
      linked? = linked == String.duplicate("[#a](/t/a) ", 40_000)
      assert linked?
    end
  end
end
