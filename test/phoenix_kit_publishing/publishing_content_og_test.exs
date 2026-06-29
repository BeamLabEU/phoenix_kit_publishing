defmodule PhoenixKit.Modules.Publishing.PublishingContentOgTest do
  @moduledoc """
  Unit tests for the `PublishingContent.get_og/1` accessor — the per-language
  OpenGraph override stored under `content.data["og"]`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PublishingContent

  test "returns the og override map when present" do
    content = %PublishingContent{data: %{"og" => %{"title" => "T", "description" => "D"}}}
    assert PublishingContent.get_og(content) == %{"title" => "T", "description" => "D"}
  end

  test "returns nil when the og key is absent, empty, or not a map" do
    assert PublishingContent.get_og(%PublishingContent{data: %{}}) == nil
    assert PublishingContent.get_og(%PublishingContent{data: %{"og" => %{}}}) == nil
    assert PublishingContent.get_og(%PublishingContent{data: %{"og" => nil}}) == nil
    assert PublishingContent.get_og(%PublishingContent{data: %{"other" => 1}}) == nil
  end
end
