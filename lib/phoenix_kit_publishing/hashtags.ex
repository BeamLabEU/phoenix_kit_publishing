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
  @masked_regions ~r{```.*?```|~~~.*?~~~|```.*|~~~.*|``[^\n]+?``|`(?:[^`\n]|\n(?!\n))*`|!?\[[^\]\n]*\]\([^)\n]*\)|<(CTA|Headline|Subheadline|Video|Audio|EntityForm)\b[^>]*>.*?</\1>|<[A-Za-z][A-Za-z0-9-]*\b[^>]*>}s

  # Start-of-line / whitespace / "(" then #<letter><letter|digit|_|->*.
  # The lookahead makes overlong words fail entirely (plain text) rather
  # than linkifying their first 30 characters.
  @hashtag ~r/(^|[\s(])#(\p{L}[\p{L}\p{N}_-]{0,29})(?![\p{L}\p{N}_-])/u

  # Same, minus the start-of-string branch. `linkify/2` splits the document on
  # masked regions, so `^` would match at every fragment boundary and treat
  # "`code`#tag" as a tag — a boundary `extract/1` does not see, which would
  # link a tag that never got stored.
  @hashtag_mid ~r/([\s(])#(\p{L}[\p{L}\p{N}_-]{0,29})(?![\p{L}\p{N}_-])/u

  # Masked regions collapse to this rather than a space: a space would invent
  # the whitespace boundary the hashtag rule requires, so "`code`#tag" would
  # extract "tag".
  @mask_sentinel "\x00"

  @max_tags 20

  alias PhoenixKit.Modules.Publishing.ListingCache

  @doc "All hashtags in a document, first-spelling-wins, order-preserving."
  def extract(content) when is_binary(content) do
    stripped = Regex.replace(@masked_regions, content, @mask_sentinel)

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
    # Only link what extract/1 would actually STORE. Otherwise the 21st tag in
    # a body (past the cap) renders as a link to an archive that can't find the
    # post — a dead link the author never sees in their tag list.
    allowed = content |> extract() |> MapSet.new(&String.downcase/1)

    @masked_regions
    |> Regex.split(content, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join(fn {part, index} -> linkify_part(part, url_fun, allowed, index == 0) end)
  end

  defp linkify_part(part, url_fun, allowed, first?) do
    if Regex.match?(@masked_regions, part) do
      part
    else
      regex = if first?, do: @hashtag, else: @hashtag_mid

      Regex.replace(regex, part, &link_tag(&1, &2, &3, url_fun, allowed))
    end
  end

  defp link_tag(full, lead, tag, url_fun, allowed) do
    if MapSet.member?(allowed, String.downcase(tag)),
      do: "#{lead}[##{tag}](#{url_fun.(tag)})",
      else: full
  end

  @doc """
  Tags already used in a group, for the editor's `#` autocomplete: the
  distinct tags across the group's posts, ranked prefix-match first, then by
  how often they're used, then alphabetically.

  Reads the listing cache (which already carries each post's tags), so typing
  a `#` costs no database round trip. Returns
  `[%{tag: "elixir", count: 12}]`, capped by `:limit`.
  """
  def suggest(group_slug, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    needle = query |> to_string() |> String.trim() |> String.downcase()

    group_slug
    |> tag_counts()
    # Matching is case-insensitive on both sides: `tag_counts/1` returns the
    # group's own spelling ("Elixir"), and typing "eli" has to find it.
    |> Enum.filter(fn {tag, _count} -> needle == "" or String.contains?(fold(tag), needle) end)
    |> Enum.sort_by(fn {tag, count} ->
      # Prefix matches lead, then the most-used, then alphabetical so the list
      # is stable between keystrokes.
      {if(String.starts_with?(fold(tag), needle), do: 0, else: 1), -count, fold(tag)}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
  end

  defp fold(tag), do: String.downcase(tag)

  # Case-insensitive tally keyed on the downcased tag, keeping the spelling
  # that occurs most often so the popup offers "Elixir" if that's what the
  # group actually writes. Ties go to the spelling seen first, so the list
  # doesn't reshuffle as unrelated posts are published.
  #
  # Returns `[{display_tag, count}]` where the count is the case-insensitive
  # total — `suggest/3` folds both sides before matching, so the returned
  # spelling is a display detail and never affects filtering or ordering.
  #
  # `ListingCache.read/1` hands back a bare list of post maps, never a
  # `%{posts: …}` envelope — the timestamps live under their own term key
  # (see `cache_generated_at_key/1`), which is what the envelope was
  # presumably remembered from.
  defp tag_counts(group_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} when is_list(posts) -> posts
      _ -> []
    end
    |> Enum.flat_map(fn post -> get_in(post, [:metadata, :tags]) || [] end)
    |> Enum.reduce(%{}, fn tag, acc ->
      tag = to_string(tag)
      key = String.downcase(tag)

      Map.update(acc, key, {1, %{tag => 1}}, fn {total, spellings} ->
        {total + 1, Map.update(spellings, tag, 1, &(&1 + 1))}
      end)
    end)
    |> Enum.map(fn {_key, {total, spellings}} -> {most_used_spelling(spellings), total} end)
  rescue
    # The cache is a convenience, not a contract — never break typing over it.
    _ -> []
  end

  # Map iteration order isn't insertion order, so an equally-common pair of
  # spellings would swap between cache rebuilds on count alone; the tag is
  # the tie-break that pins one of them.
  defp most_used_spelling(spellings) do
    spellings
    |> Enum.max_by(fn {tag, count} -> {count, tag} end)
    |> elem(0)
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
