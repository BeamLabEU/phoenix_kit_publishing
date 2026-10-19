defmodule PhoenixKit.Modules.Publishing.API.TextScan do
  @moduledoc false
  # The text danger rule of the Publishing API: a fail-closed
  # scan of a SUBMITTED string. It renders nothing and parses no markdown. A write of body
  # text is dangerous when the text holds raw HTML or a component (`<` + letter, `/`, `!`,
  # `?`), the `[[post:` token, `javascript:` / `vbscript:` / `data:` (whitespace removed, any
  # case), a markdown link / image destination outside http, https, mailto, tel and
  # relative (`//host` is another site, not relative), or a bare `scheme://` (or `xmpp:`)
  # in the text: the renderer enables the GFM autolink extension, which turns those into
  # live links. O(n) time and memory.

  @max_body_bytes 262_144
  @max_scan_bytes 2_097_152
  @max_findings 20
  @fragment_chars 80
  @schemes ~w(http https mailto tel)
  @scheme_needles ["javascript:", "vbscript:", "data:"]

  @doc "The cap on one body field the handlers enforce before the scan."
  def max_body_bytes, do: @max_body_bytes

  @doc "Stored bodies longer than this are not scanned (reported as `not_scanned`)."
  def max_scan_bytes, do: @max_scan_bytes

  @spec dangerous?(term()) :: boolean()
  def dangerous?(text) when is_binary(text) and byte_size(text) <= @max_scan_bytes do
    html(text) != [] or post_link(text) != [] or scheme(text) != [] or link_scheme(text) != [] or
      autolink_scheme(text) != []
  end

  def dangerous?(_other), do: true

  @spec scan(term()) :: map()
  def scan(text) when is_binary(text) and byte_size(text) <= @max_scan_bytes do
    lists = [
      {"html", html(text)},
      {"post_link", post_link(text)},
      {"scheme", scheme(text)},
      {"link_scheme", link_scheme(text)},
      {"autolink_scheme", autolink_scheme(text)}
    ]

    count = lists |> Enum.map(fn {_kind, offsets} -> length(offsets) end) |> Enum.sum()

    # Each list is already in text order, so the first 20 of the union are inside the
    # first 20 of each list: no sort of a 262,144-element list.
    findings =
      lists
      |> Enum.flat_map(fn {kind, offsets} ->
        offsets |> Enum.take(@max_findings) |> Enum.map(&{&1, kind})
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(@max_findings)
      |> Enum.map(fn {offset, kind} -> finding(text, offset, kind) end)

    result(count, findings)
  end

  def scan(_other) do
    result(1, [%{"kind" => "not_scanned", "line" => 1, "fragment" => ""}])
  end

  defp result(count, findings) do
    %{
      "dangerous" => count > 0,
      "count" => count,
      "truncated" => count > length(findings),
      "findings" => findings
    }
  end

  # --- rule 1: html ----------------------------------------------------------------

  # `<` followed by an ASCII letter, `/`, `!` or `?`. `:binary.matches/2` is native, so a body
  # that is all `<a<a...` costs a fraction of a global regex run with index captures.
  defp html(text) do
    size = byte_size(text)

    for {pos, 1} <- :binary.matches(text, "<"),
        pos + 1 < size,
        html_start?(:binary.at(text, pos + 1)),
        do: pos
  end

  defp html_start?(b) when b in ?A..?Z or b in ?a..?z or b in [?/, ?!, ??], do: true
  defp html_start?(_b), do: false

  # --- rule 2: post_link -----------------------------------------------------------

  defp post_link(text), do: offsets(text, ~S"\[\[post:", [:caseless])

  defp offsets(text, pattern, opts) do
    case :re.run(text, pattern, [:global, {:capture, :first, :index}] ++ opts) do
      {:match, matches} -> for [{start, _len}] <- matches, do: start
      :nomatch -> []
    end
  end

  # --- rule 3: scheme --------------------------------------------------------------

  defp scheme(text) do
    {stripped, breakpoints} = strip(text)

    case :binary.matches(stripped, @scheme_needles) do
      [] -> []
      matches -> for {pos, _len} <- matches, do: original_offset(pos, breakpoints)
    end
  end

  # The text without whitespace, C0 controls, DEL, U+200B..U+200D, U+2060 and U+FEFF, with
  # ASCII letters lower-cased (byte length is preserved for every kept character). The second
  # element maps stripped positions back to original offsets: a tuple of `{stripped_pos,
  # removed_bytes_so_far}` breakpoints, one per run of removed characters.
  defp strip(text) do
    {iodata, breaks, _removed} = strip(text, 0, [], [], 0, 0)
    {IO.iodata_to_binary(Enum.reverse(iodata)), breaks |> Enum.reverse() |> List.to_tuple()}
  end

  defp strip(<<>>, _kept, acc, breaks, removed, _off), do: {acc, breaks, removed}

  defp strip(<<c::utf8, rest::binary>> = bin, kept, acc, breaks, removed, off) do
    size = byte_size(bin) - byte_size(rest)

    if ignorable?(c) do
      removed = removed + size
      breaks = put_break(breaks, kept, removed)
      strip(rest, kept, acc, breaks, removed, off + size)
    else
      chunk = if c in ?A..?Z, do: <<c + 32>>, else: binary_part(bin, 0, size)
      strip(rest, kept + size, [chunk | acc], breaks, removed, off + size)
    end
  end

  # An invalid byte is kept as it is.
  defp strip(<<b, rest::binary>>, kept, acc, breaks, removed, off),
    do: strip(rest, kept + 1, [<<b>> | acc], breaks, removed, off + 1)

  defp put_break([{kept, _old} | rest], kept, removed), do: [{kept, removed} | rest]
  defp put_break(breaks, kept, removed), do: [{kept, removed} | breaks]

  defp original_offset(pos, breakpoints) do
    pos + removed_before(pos, breakpoints, 0, tuple_size(breakpoints) - 1, 0)
  end

  # Binary search for the last breakpoint with stripped_pos <= pos.
  defp removed_before(_pos, _bp, lo, hi, best) when lo > hi, do: best

  defp removed_before(pos, bp, lo, hi, best) do
    mid = div(lo + hi, 2)
    {kept, removed} = elem(bp, mid)

    if kept <= pos,
      do: removed_before(pos, bp, mid + 1, hi, removed),
      else: removed_before(pos, bp, lo, mid - 1, best)
  end

  defp ignorable?(c) when c in 0x00..0x20, do: true
  defp ignorable?(0x7F), do: true

  defp ignorable?(c) when c in [0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000],
    do: true

  defp ignorable?(c) when c in 0x2000..0x200D, do: true
  defp ignorable?(c) when c in [0x2060, 0xFEFF], do: true
  defp ignorable?(_c), do: false

  # --- rule 4: link_scheme ---------------------------------------------------------

  defp link_scheme(text) do
    inline = destinations(text, ~S"\]\(\s*([^\s)]*)")
    reference = destinations(text, ~S"\]:\s*(\S*)")

    (inline ++ reference)
    |> Enum.filter(fn {_start, dest} -> bad_destination?(dest) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # `{match_start, destination}` for each match of `pattern` (group 1 is the destination).
  defp destinations(text, pattern) do
    case :re.run(text, pattern, [:global, {:capture, [0, 1], :index}]) do
      {:match, matches} ->
        for [{start, _}, {dstart, dlen}] <- matches, do: {start, binary_part(text, dstart, dlen)}

      :nomatch ->
        []
    end
  end

  defp bad_destination?(dest) do
    zone = dest |> :binary.split(["/", "?", "#"]) |> hd()

    cond do
      # `//host/path` is not a path of this site: the visitor lands on another host
      String.starts_with?(dest, ["//", "<//"]) ->
        true

      String.contains?(zone, ["&", "\\"]) or control?(zone) ->
        true

      String.contains?(zone, ":") ->
        zone |> :binary.split(":") |> hd() |> String.downcase() |> then(&(&1 not in @schemes))

      true ->
        false
    end
  end

  defp control?(zone), do: :re.run(zone, "[\\x00-\\x1F\\x7F]", [{:capture, :none}]) == :match

  # --- rule 5: autolink_scheme ------------------------------------------------------

  # The renderer decodes entities before it autolinks, and the GFM autolink extension links
  # a bare `scheme://...` of ANY scheme and an email address with `mailto:` / `xmpp:` in front
  # of it, keeping the local-part characters `[A-Za-z0-9.+_-]` that precede the word (so
  # `x-mailto:a@b.c` becomes a link with the scheme `x-mailto`). The rule therefore reads the
  # text with the entities that stand for printable ASCII decoded, and flags:
  #
  #   * a bare URL whose scheme is not http or https: the scheme is the run of `[a-z0-9+.-]`
  #     before each `://`, trimmed to start at a letter; the runs cannot overlap, so the scan
  #     is linear;
  #   * `xmpp:` in any letter case;
  #   * `mailto:` directly preceded by a local-part character.
  #
  # Offsets are mapped back to the submitted text, so a finding shows what the writer sent.
  defp autolink_scheme(text) do
    {decoded, breaks} = decode_entities(text)

    bare =
      for {pos, _len} <- :binary.matches(decoded, "://"),
          {start, scheme} = scheme_before(decoded, pos),
          scheme != "" and String.downcase(scheme) not in ["http", "https"],
          do: start

    Enum.sort(bare ++ email_schemes(decoded))
    |> Enum.map(&original_offset(&1, breaks))
  end

  defp email_schemes(decoded) do
    case :re.run(decoded, "xmpp:|[A-Za-z0-9+._-]mailto:", [
           :global,
           :caseless,
           {:capture, :first, :index}
         ]) do
      {:match, matches} -> for [{start, _len}] <- matches, do: local_part_start(decoded, start)
      :nomatch -> []
    end
  end

  # A finding starts at the first character of the address, not in the middle of it. The runs
  # cannot overlap (each match ends in a colon, which is not a local-part character).
  defp local_part_start(_decoded, 0), do: 0

  defp local_part_start(decoded, pos) do
    if local_part_byte?(:binary.at(decoded, pos - 1)),
      do: local_part_start(decoded, pos - 1),
      else: pos
  end

  defp local_part_byte?(b), do: letter?(b) or b in ?0..?9 or b in [?+, ?., ?_, ?-]

  # An entity that stands for one printable ASCII character: a decimal reference of up to
  # seven digits, a hexadecimal one of up to six (leading zeros included), or one of the
  # named references of the characters an address can hold. Names are case-sensitive.
  @entity "&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|colon|period|plus|lowbar|commat);"
  @named_entities %{"colon" => ?:, "period" => ?., "plus" => ?+, "lowbar" => ?_, "commat" => ?@}

  # The text with those entities replaced by their character, and the breakpoints that map a
  # position in it back to the submitted text (same shape as `strip/1`). Entities that stand
  # for a control character or a space stay as they are, so lines and word breaks do not move.
  defp decode_entities(text) do
    case :re.run(text, @entity, [:global, {:capture, :first, :index}]) do
      :nomatch -> {text, {}}
      {:match, matches} -> decode_entities(matches, text, 0, 0, 0, [], [])
    end
  end

  defp decode_entities([], text, cursor, _kept, _removed, acc, breaks) do
    tail = binary_part(text, cursor, byte_size(text) - cursor)
    {IO.iodata_to_binary(Enum.reverse([tail | acc])), breaks |> Enum.reverse() |> List.to_tuple()}
  end

  defp decode_entities([[{start, len}] | rest], text, cursor, kept, removed, acc, breaks) do
    case entity_char(binary_part(text, start, len)) do
      nil ->
        decode_entities(rest, text, cursor, kept, removed, acc, breaks)

      char ->
        before = binary_part(text, cursor, start - cursor)
        kept = kept + byte_size(before) + 1
        removed = removed + len - 1

        decode_entities(rest, text, start + len, kept, removed, [<<char>>, before | acc], [
          {kept, removed} | breaks
        ])
    end
  end

  defp entity_char("&#" <> reference), do: reference |> codepoint() |> printable()

  defp entity_char("&" <> name), do: Map.get(@named_entities, String.trim_trailing(name, ";"))

  defp codepoint(reference) do
    digits = String.trim_trailing(reference, ";")

    case digits do
      <<x, hex::binary>> when x in [?x, ?X] -> String.to_integer(hex, 16)
      decimal -> String.to_integer(decimal)
    end
  end

  defp printable(cp) when cp in 0x21..0x7E, do: cp
  defp printable(_cp), do: nil

  defp scheme_before(text, pos) do
    start = scheme_run_start(text, pos)
    start = skip_non_letters(text, start, pos)
    {start, binary_part(text, start, pos - start)}
  end

  defp scheme_run_start(_text, 0), do: 0

  defp scheme_run_start(text, pos) do
    if scheme_byte?(:binary.at(text, pos - 1)),
      do: scheme_run_start(text, pos - 1),
      else: pos
  end

  defp skip_non_letters(_text, pos, pos), do: pos

  defp skip_non_letters(text, start, stop) do
    if letter?(:binary.at(text, start)), do: start, else: skip_non_letters(text, start + 1, stop)
  end

  defp scheme_byte?(b), do: letter?(b) or b in ?0..?9 or b in [?+, ?., ?-]
  defp letter?(b), do: b in ?a..?z or b in ?A..?Z

  # --- findings ---------------------------------------------------------------------

  defp finding(text, offset, kind) do
    %{"kind" => kind, "line" => line_of(text, offset), "fragment" => fragment(text, offset)}
  end

  defp line_of(_text, 0), do: 1
  defp line_of(text, offset), do: length(:binary.matches(binary_part(text, 0, offset), "\n")) + 1

  # From the match start to the end of its line, at most 80 characters, control characters
  # (and bytes that are not valid UTF-8) shown as \xNN so the fragment is JSON-safe.
  defp fragment(text, offset) do
    rest = binary_part(text, offset, min(byte_size(text) - offset, 4 * @fragment_chars + 8))
    line = rest |> :binary.split(["\r\n", "\n", "\r"]) |> hd()
    line |> take_chars(@fragment_chars, []) |> IO.iodata_to_binary()
  end

  defp take_chars(_bin, 0, acc), do: Enum.reverse(acc)
  defp take_chars(<<>>, _n, acc), do: Enum.reverse(acc)

  defp take_chars(<<c::utf8, rest::binary>>, n, acc) when c < 0x20 or c == 0x7F,
    do: take_chars(rest, n - 1, [escape(c) | acc])

  defp take_chars(<<c::utf8, rest::binary>>, n, acc),
    do: take_chars(rest, n - 1, [<<c::utf8>> | acc])

  defp take_chars(<<b, rest::binary>>, n, acc), do: take_chars(rest, n - 1, [escape(b) | acc])

  defp escape(byte),
    do: "\\x" <> String.upcase(String.pad_leading(Integer.to_string(byte, 16), 2, "0"))
end
