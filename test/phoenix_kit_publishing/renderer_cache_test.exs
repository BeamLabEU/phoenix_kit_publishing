defmodule PhoenixKit.Modules.Publishing.RendererCacheTest do
  @moduledoc """
  The render cache keeps a finished page and refuses a page whose image
  lookup raised. `invalidate_cache/3` deletes the prefix it builds.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Cache
  alias PhoenixKit.Modules.Publishing.Renderer

  setup do
    start_supervised!({Cache, name: :publishing_posts, ttl: :timer.hours(1), max_size: 200})
    :ok
  end

  test "a published render is stored under the post prefix" do
    post = post("Hello cache")

    assert {:ok, html} = Renderer.render_post(post)
    assert html =~ "Hello cache"
    assert {:ok, 1} = Cache.clear_by_prefix(:publishing_posts, prefix(post))
  end

  test "invalidate_cache/3 deletes that prefix and leaves another post" do
    kept = post("Keep")
    other = post("Other")

    assert {:ok, _} = Renderer.render_post(kept)
    assert {:ok, _} = Renderer.render_post(other)

    assert :ok = Renderer.invalidate_cache(kept.group, kept.uuid, kept.language)

    assert {:ok, 0} = Cache.clear_by_prefix(:publishing_posts, prefix(kept))
    assert {:ok, 1} = Cache.clear_by_prefix(:publishing_posts, prefix(other))
  end

  test "invalidate_cache/3 with the slug does not remove the uuid entry" do
    post = post("Uuid key")

    assert {:ok, _} = Renderer.render_post(post)
    assert :ok = Renderer.invalidate_cache(post.group, post.slug, post.language)

    assert {:ok, 1} = Cache.clear_by_prefix(:publishing_posts, prefix(post))
  end

  test "invalidate_cache/3 does not raise when the cache is down" do
    stop_supervised(Cache)
    assert :ok = Renderer.invalidate_cache("group", "post-slug", "en")
  end

  # The signal ships in core. A publishing suite pinned to an older core
  # has nothing to refuse, and still stores the placeholder.
  if Code.ensure_loaded?(PhoenixKit.Modules.Shared.RenderCache) and
       function_exported?(PhoenixKit.Modules.Shared.RenderCache, :take, 1) do
    test "a raised image lookup is shown and not stored" do
      post = post(~s(<Image file_uuid="not-a-uuid" alt="Boat"/>))

      assert {:ok, html} = Renderer.render_post(post)
      assert html =~ "Image not available"
      assert {:ok, 0} = Cache.clear_by_prefix(:publishing_posts, prefix(post))

      # The article text did not change. A second render tries again
      # rather than replaying the placeholder from the cache.
      assert {:ok, again} = Renderer.render_post(post)
      assert again =~ "Image not available"
      assert {:ok, 0} = Cache.clear_by_prefix(:publishing_posts, prefix(post))
    end
  end

  defp post(content) do
    n = System.unique_integer([:positive])

    %{
      content: content,
      metadata: %{title: "Cache", status: "published"},
      group: "blog-cache-#{n}",
      slug: "post-#{n}",
      uuid: "uuid-#{n}",
      language: "en"
    }
  end

  defp prefix(post) do
    Renderer.cache_prefix(post.group, post.uuid, post.language)
  end
end
