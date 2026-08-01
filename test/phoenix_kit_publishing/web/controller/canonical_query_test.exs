defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalQueryTest do
  @moduledoc """
  A canonical redirect keeps the request's query string, so a `?utm_source=`
  link doesn't lose its campaign on the way to the real URL.

  The listing's canonical URL builds its own `?page=` from that same request
  though, so appending the query string wholesale wrote the key twice —
  `?page=2&page=2` — in the URL search engines are told is the canonical one.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller

  defp merge(url, query_string),
    do: Controller.with_query_string(%{query_string: query_string}, url)

  test "a key the target already set is not written twice" do
    assert merge("/blog?page=2", "page=2") == "/blog?page=2"
  end

  test "campaign params still ride along" do
    merged = merge("/blog?page=2", "page=2&utm_source=x")

    assert merged =~ "utm_source=x"
    assert Regex.scan(~r/\bpage=/, merged) |> length() == 1
  end

  test "a target with no query gets the whole string" do
    assert merge("/blog", "utm_source=x") == "/blog?utm_source=x"
  end

  test "an empty query string leaves the target alone" do
    assert merge("/blog?page=2", "") == "/blog?page=2"
  end

  test "the target wins the value, not the request" do
    # Both name `page`; the canonical URL is the one that decided.
    assert merge("/blog?page=2", "page=9") == "/blog?page=2"
  end
end
