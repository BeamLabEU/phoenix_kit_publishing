defmodule PhoenixKit.Modules.Publishing.Hashtags do
  @moduledoc """
  Body hashtags ARE the tag system (boss call, 2026-07-28): writers type
  `#elixir` inline and the post's tags derive from the text on save —
  there is no separate tags field. The public side is unchanged (tag
  archives, feeds, chips); only the source of truth moved into the prose.

  ## What counts as a hashtag

  `#` followed immediately by a letter, at the start of a line or after
  whitespace/`(`. That rule excludes, by construction:

  - Markdown headings (`# Title` — the space after `#` breaks the match);
  - URL fragments (`…/page#section` — no preceding whitespace);
  - code (fenced blocks and inline backticks are stripped before scanning,
    mirroring the Renderer's component-scan mask);
  - Markdown links/images (`[jump](#section)` is an anchor, and a tag
    inside link text would nest links).

  Letters are Unicode (`#uudised` and `#новости` tag fine); digits,
  underscore and hyphen may follow. Dedup is case-insensitive keeping the
  first spelling; capped at #{20} per document (the old input's cap).
  """

  # Mirror of Renderer's @code_region_regex (fences, double- and
  # single-backtick inline code) — keep the two in sync. Also masked:
  # - unclosed fences (the rest of the doc renders as code anyway);
  # - Markdown links/images: `[jump](#section)` is an anchor, not a tag,
  #   and a hashtag inside link text would nest links (invalid MD);
  # - PHK components (`<Image alt="see #elixir" />`, `<Video>…</Video>`):
  #   attribute values must never be rewritten, and block bodies are
  #   emitted as raw HTML, where a Markdown link would show literally.
  @masked_regions ~r{```.*?```|~~~.*?~~~|```.*|~~~.*|``[^\n]+?``|`(?:[^`\n]|\n(?!\n))*`|!?\[[^\]\n]*\]\([^)\n]*\)|<([A-Z][A-Za-z0-9]*)\b[^>]*>.*?</\1>|<[A-Z][A-Za-z0-9]*\b[^>]*>}s

  # Start-of-line / whitespace / "(" then #<letter><letter|digit|_|->*.
  # The lookahead makes overlong words fail entirely (plain text) rather
  # than linkifying their first 30 characters.
  @hashtag ~r/(^|[\s(])#(\p{L}[\p{L}\p{N}_-]{0,29})(?![\p{L}\p{N}_-])/u

  @max_tags 20

  @doc "All hashtags in a document, first-spelling-wins, order-preserving."
  def extract(content) when is_binary(content) do
    stripped = Regex.replace(@masked_regions, content, " ")

    @hashtag
    |> Regex.scan(stripped, capture: :all_but_first)
    |> Enum.map(fn [_lead, tag] -> tag end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max_tags)
  end

  def extract(_), do: []

  @doc """
  Rewrites every hashtag into a Markdown link (`[#tag](url_fun.(tag))`),
  leaving code regions and existing Markdown links untouched — the
  renderer runs this before the Markdown pass so the links pick up the
  prose link styling.
  """
  def linkify(content, url_fun) when is_binary(content) and is_function(url_fun, 1) do
    @masked_regions
    |> Regex.split(content, include_captures: true)
    |> Enum.map_join(&linkify_part(&1, url_fun))
  end

  defp linkify_part(part, url_fun) do
    if Regex.match?(@masked_regions, part) do
      part
    else
      Regex.replace(@hashtag, part, fn _all, lead, tag ->
        "#{lead}[##{tag}](#{url_fun.(tag)})"
      end)
    end
  end

  @doc """
  The tag set for a whole version: the union of hashtags across every
  language's content (per-language bodies may tag differently; the version
  carries one combined list, same storage as before).
  """
  def extract_all(contents) when is_list(contents) do
    contents
    |> Enum.flat_map(fn
      %{content: c} when is_binary(c) -> extract(c)
      _ -> []
    end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max_tags)
  end
end
