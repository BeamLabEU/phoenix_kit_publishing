defmodule PhoenixKit.Modules.Publishing.ActivityAttributionTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts, Versions}

  @meta %{"via" => "api", "key_prefix" => "abcd1234", "request_id" => "r1", "tool" => "t"}
  @uuid "00000000-0000-7000-8000-000000000001"

  defp api(extra \\ []),
    do: [actor_uuid: @uuid, activity_mode: "auto", log_metadata: @meta] ++ extra

  defp group!(opts \\ []) do
    {:ok, g} =
      Groups.add_group("Attr #{System.unique_integer([:positive])}", [mode: "slug"] ++ opts)

    g
  end

  defp assert_attributed(action, resource_uuid) do
    row = assert_activity_logged(action, resource_uuid: resource_uuid)
    assert row.mode == "auto"
    assert row.metadata["via"] == "api"
    row
  end

  test "group create, update, trash, restore" do
    g = group!(api())
    assert_attributed("publishing.group.created", g["uuid"])
    assert g["mode"] == "slug"
    {:ok, _} = Groups.update_group(g["slug"], %{"name" => "Renamed"}, api())
    assert_attributed("publishing.group.updated", g["uuid"])
    {:ok, _} = Groups.trash_group(g["slug"], api())
    assert_attributed("publishing.group.trashed", g["uuid"])
    {:ok, _} = Groups.restore_group(g["slug"], api())
    assert_attributed("publishing.group.restored", g["uuid"])
  end

  test "post create, update, trash, restore, version publish and unpublish" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], [title: "T", slug: "t"] ++ api())
    assert_attributed("publishing.post.created", post[:uuid])
    {:ok, _} = Posts.update_post(g["slug"], post, %{"title" => "T2"}, api(publish: false))
    assert_attributed("publishing.post.updated", post[:uuid])
    :ok = Versions.publish_version(g["slug"], post[:uuid], 1, api())
    assert_attributed("publishing.version.published", post[:uuid])
    :ok = Versions.unpublish_post(g["slug"], post[:uuid], api())
    assert_attributed("publishing.post.unpublished", post[:uuid])
    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid], api())
    assert_attributed("publishing.post.trashed", post[:uuid])
    {:ok, _} = Posts.restore_post(g["slug"], post[:uuid], api())
    assert_attributed("publishing.post.restored", post[:uuid])
  end

  test "category create, update, delete" do
    g = group!()
    {:ok, cat} = Categories.create_category(g["slug"], %{name: "C", slug: "c"}, api())
    assert_attributed("publishing.category.created", cat.uuid)
    {:ok, _} = Categories.update_category(cat.uuid, %{name: "C2"}, api())
    assert_attributed("publishing.category.updated", cat.uuid)
    {:ok, _} = Categories.delete_category(cat.uuid, api())
    assert_attributed("publishing.category.deleted", cat.uuid)
  end

  test "without the options the rows are unchanged (manual, no via)" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})
    row = assert_activity_logged("publishing.post.created", resource_uuid: post[:uuid])
    assert row.mode == "manual"
    refute Map.has_key?(row.metadata, "via")
  end

  # The db_pending branches are hard to provoke: assert statically that every
  # ActivityLog call in the five files passes a sixth argument, except the ones
  # in functions that deliberately keep the manual mode.
  @files ~w(posts versions groups categories translation_manager)
  # The *_post_categories, clear/delete translation and delete functions (and their
  # helpers) keep the manual mode; the API does not call them.
  @untouched ~w(remove_group delete_and_broadcast_group reorder_categories replace_post_categories
                do_replace_post_categories clear_translation delete_language
                log_translation_failure delete_version)a

  test "every log call in the touched functions passes opts" do
    for file <- @files do
      path = Path.join("lib/phoenix_kit_publishing", file <> ".ex")
      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()
      {_ast, offenders} = Macro.prewalk(ast, [], &collect/2)

      assert offenders == [],
             "#{path}: ActivityLog calls without opts: #{inspect(Enum.reverse(offenders))}"
    end
  end

  # Walks defs; skips the functions that keep the manual mode.
  defp collect({kind, _, [head | _]} = node, acc) when kind in [:def, :defp] do
    name = fun_name(head)
    if name in @untouched, do: {nil, acc}, else: {node, find_calls(node, acc, name)}
  end

  defp collect(node, acc), do: {node, acc}

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: nil

  defp find_calls(node, acc, fun) do
    {_n, found} =
      Macro.prewalk(node, acc, fn
        {{:., _, [{:__aliases__, _, [:ActivityLog]}, f]}, meta, args} = n, a
        when f in [:log_manual, :log_failed_mutation] ->
          # 5 positional args = no opts; a 6th is the opts
          if length(args) >= 6, do: {n, a}, else: {n, [{fun, f, meta[:line]} | a]}

        n, a ->
          {n, a}
      end)

    found
  end
end
