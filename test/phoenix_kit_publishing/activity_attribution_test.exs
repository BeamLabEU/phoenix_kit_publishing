defmodule PhoenixKit.Modules.Publishing.ActivityAttributionTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts, TranslationManager, Versions}

  @meta %{"via" => "api", "key_prefix" => "abcd1234", "request_id" => "r1", "tool" => "t"}
  @via_keys ~w(via key_prefix request_id tool)

  defp api(extra \\ []) do
    [actor_uuid: Ecto.UUID.generate(), activity_mode: "auto", log_metadata: @meta] ++ extra
  end

  defp group!(opts \\ []) do
    {:ok, g} =
      Groups.add_group("Attr #{System.unique_integer([:positive])}", [mode: "slug"] ++ opts)

    g
  end

  defp assert_via(row) do
    assert row.mode == "auto"
    for key <- @via_keys, do: assert(row.metadata[key] == @meta[key], "missing #{key}")
    row
  end

  defp assert_attributed(action, resource_uuid) do
    row = assert_activity_logged(action, resource_uuid: resource_uuid)
    refute Map.has_key?(row.metadata, "db_pending")
    assert_via(row)
  end

  # A failed mutation row: same action as the success row, `db_pending: true`.
  defp assert_failed_attributed(action, filters) do
    metadata_has = Map.merge(%{"db_pending" => true}, Keyword.get(filters, :metadata_has, %{}))
    row = assert_activity_logged(action, Keyword.put(filters, :metadata_has, metadata_has))
    assert_via(row)
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

  test "version create (the API's create_version site)" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Versions.create_version_from(g["slug"], post[:uuid], 1, %{}, api())

    row = assert_activity_logged("publishing.version.created")
    assert row.metadata["post_uuid"] == post[:uuid]
    assert_via(row)
  end

  test "translation added (the API's set_translation / translate_post site)" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})
    {:ok, _} = TranslationManager.add_language_to_post(g["slug"], post[:uuid], "de", nil, api())

    row = assert_activity_logged("publishing.translation.added")
    assert row.metadata["language"] == "de"
    refute Map.has_key?(row.metadata, "db_pending")
    assert_via(row)
  end

  test "without the options the rows are unchanged (manual, no via)" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})
    row = assert_activity_logged("publishing.post.created", resource_uuid: post[:uuid])
    assert row.mode == "manual"
    refute Map.has_key?(row.metadata, "via")
  end

  describe "failed mutations carry the mode and the via keys" do
    test "posts: create in an unknown group, update, trash and restore of an unknown post" do
      assert {:error, _} = Posts.create_post("no-such-group", [title: "T"] ++ api())
      assert_failed_attributed("publishing.post.created", [])

      g = group!()
      unknown = Ecto.UUID.generate()

      assert {:error, :not_found} = Posts.trash_post(g["slug"], unknown, api())
      assert_failed_attributed("publishing.post.trashed", resource_uuid: unknown)

      assert {:error, :not_found} = Posts.restore_post(g["slug"], unknown, api())
      assert_failed_attributed("publishing.post.restored", resource_uuid: unknown)

      ghost = %{uuid: unknown, slug: "ghost", language: "en", mode: :slug}
      assert {:error, _} = Posts.update_post(g["slug"], ghost, %{"title" => "X"}, api())
      assert_failed_attributed("publishing.post.updated", resource_uuid: unknown)
    end

    test "groups: update, trash and restore of an unknown slug" do
      assert {:error, :not_found} = Groups.update_group("no-such-group", %{"name" => "X"}, api())
      assert_failed_attributed("publishing.group.updated", [])

      assert {:error, :not_found} = Groups.trash_group("no-such-group", api())
      assert_failed_attributed("publishing.group.trashed", [])

      assert {:error, :not_found} = Groups.restore_group("no-such-group", api())
      assert_failed_attributed("publishing.group.restored", [])
    end

    test "groups: a create with a taken slug or a blank name is attributed" do
      g = group!()

      assert {:error, :already_exists} =
               Groups.add_group("Other", [mode: "slug", slug: g["slug"]] ++ api())

      assert_failed_attributed("publishing.group.created",
        metadata_has: %{"reason" => "already_exists"}
      )

      assert {:error, :invalid_name} = Groups.add_group("  ", [mode: "slug"] ++ api())

      assert_failed_attributed("publishing.group.created",
        metadata_has: %{"reason" => "invalid_name"}
      )
    end

    test "groups: a failing update with a known group is attributed" do
      g = group!()
      assert {:error, _} = Groups.update_group(g["slug"], %{"name" => ""}, api())
      assert_failed_attributed("publishing.group.updated", resource_uuid: g["uuid"])
    end

    test "categories: duplicate slug on create, unknown uuid on update and delete" do
      g = group!()
      {:ok, _} = Categories.create_category(g["slug"], %{name: "C", slug: "c"})

      assert {:error, _} = Categories.create_category(g["slug"], %{name: "C", slug: "c"}, api())
      assert_failed_attributed("publishing.category.created", [])

      unknown = Ecto.UUID.generate()

      assert {:error, _} = Categories.update_category(unknown, %{name: "X"}, api())
      assert_failed_attributed("publishing.category.updated", resource_uuid: unknown)

      assert {:error, _} = Categories.delete_category(unknown, api())
      assert_failed_attributed("publishing.category.deleted", resource_uuid: unknown)
    end

    test "versions: publish and unpublish of an unknown post, create_version failures" do
      g = group!()
      unknown = Ecto.UUID.generate()

      assert {:error, :not_found} = Versions.publish_version(g["slug"], unknown, 1, api())
      assert_failed_attributed("publishing.version.published", resource_uuid: unknown)

      assert {:error, :not_found} = Versions.unpublish_post(g["slug"], unknown, api())
      assert_failed_attributed("publishing.post.unpublished", resource_uuid: unknown)

      assert {:error, :post_not_found} =
               Versions.create_version_from(g["slug"], unknown, 1, %{}, api())

      assert_failed_attributed("publishing.version.created", resource_uuid: unknown)
    end

    test "versions: publish of a trashed post or a missing version, unpublish of a draft" do
      g = group!()
      {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})

      assert {:error, :not_published} = Versions.unpublish_post(g["slug"], post[:uuid], api())

      assert_failed_attributed("publishing.post.unpublished",
        resource_uuid: post[:uuid],
        metadata_has: %{"reason" => "not_published"}
      )

      assert {:error, _} = Versions.publish_version(g["slug"], post[:uuid], 99, api())

      assert_failed_attributed("publishing.version.published", resource_uuid: post[:uuid])

      {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
      assert {:error, _} = Versions.publish_version(g["slug"], post[:uuid], 1, api())

      rows =
        list_activities()
        |> Enum.filter(&(&1.action == "publishing.version.published"))

      assert length(rows) == 2

      assert Enum.any?(rows, fn row ->
               row.metadata["reason"] == "post_trashed" and row.mode == "auto" and
                 row.metadata["via"] == "api" and row.metadata["db_pending"] == true
             end)
    end

    test "versions: create_version with params is refused and attributed" do
      g = group!()
      {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})

      assert {:error, :params_not_applied} =
               Versions.create_version_from(g["slug"], post[:uuid], 1, %{"title" => "X"}, api())

      assert_failed_attributed("publishing.version.created", resource_uuid: post[:uuid])
    end

    test "translations: adding a language to an unknown post is attributed" do
      g = group!()
      unknown = Ecto.UUID.generate()

      assert {:error, _} =
               TranslationManager.add_language_to_post(g["slug"], unknown, "de", nil, api())

      row = assert_activity_logged("publishing.translation.added")
      assert row.metadata["db_pending"] == true
      assert_via(row)
    end
  end

  test "the entry's own metadata wins a key clash with log_metadata" do
    g = group!()
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})

    clashing = Map.merge(@meta, %{"group_slug" => "forged", "slug" => "forged"})

    {:ok, _} =
      Posts.trash_post(g["slug"], post[:uuid],
        actor_uuid: Ecto.UUID.generate(),
        activity_mode: "auto",
        log_metadata: clashing
      )

    row = assert_activity_logged("publishing.post.trashed", resource_uuid: post[:uuid])
    assert row.metadata["group_slug"] == g["slug"]
    assert row.metadata["slug"] == "t"
    assert_via(row)
  end

  # The db_pending branches are hard to provoke on all sites: assert statically
  # that every ActivityLog call in the five files passes the function's own
  # options variable as the sixth argument, except the ones in functions that
  # deliberately keep the manual mode.
  @lib Path.expand("../../lib/phoenix_kit_publishing", __DIR__)
  @files ~w(posts versions groups categories translation_manager)
  # The *_post_categories, clear/delete translation and delete functions (and their
  # helpers) keep the manual mode; the API does not call them.
  @untouched ~w(remove_group delete_and_broadcast_group reorder_categories replace_post_categories
                do_replace_post_categories clear_translation delete_language
                log_translation_failure delete_version)a
  @log_calls [:log_manual, :log_failed_mutation]
  # The number of calls the scan checks today. A scan that finds fewer is
  # looking at the wrong thing.
  @min_checked_calls 38

  test "every log call in the touched functions passes its options variable" do
    results =
      for file <- @files do
        path = Path.join(@lib, file <> ".ex")
        source = File.read!(path)
        refute source =~ ~r/import\s+[\w.]*ActivityLog/, "#{file}: ActivityLog is imported"

        {:ok, ast} = Code.string_to_quoted(source)
        {_ast, calls} = Macro.prewalk(ast, [], &collect/2)

        # Every textual call is found by the AST walk (an aliased or qualified
        # call the walk cannot see would make these differ).
        text_count =
          length(Regex.scan(~r/ActivityLog\.(log_manual|log_failed_mutation)\(/, source))

        assert length(calls) == text_count, "#{file}: the scan missed ActivityLog calls"

        checked = Enum.reject(calls, fn {fun, _f, _line, _ok?} -> fun in @untouched end)
        offenders = Enum.reject(checked, fn {_fun, _f, _line, ok?} -> ok? end)

        assert offenders == [],
               "#{file}.ex: ActivityLog calls without their opts: #{inspect(Enum.reverse(offenders))}"

        length(checked)
      end

    assert Enum.sum(results) >= @min_checked_calls
  end

  # Gathers the calls of every def/defp (nested defs do not occur).
  # Returning nil as the node stops the descent into that def.
  defp collect({kind, _, [head | _]} = node, acc) when kind in [:def, :defp],
    do: {nil, find_calls(node, acc, fun_name(head))}

  defp collect(node, acc), do: {node, acc}

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: nil

  defp find_calls(node, acc, fun) do
    {_n, found} =
      Macro.prewalk(node, acc, fn
        {{:., _, [{:__aliases__, _, [:ActivityLog]}, f]}, meta, args} = n, a
        when f in @log_calls ->
          {n, [{fun, f, meta[:line], opts_argument?(args)} | a]}

        n, a ->
          {n, a}
      end)

    found
  end

  # The sixth argument is the bare variable `opts` or `opts_map`.
  defp opts_argument?([_, _, _, _, _, {name, _, ctx}])
       when name in [:opts, :opts_map] and is_atom(ctx),
       do: true

  defp opts_argument?(_args), do: false
end
