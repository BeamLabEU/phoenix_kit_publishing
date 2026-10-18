defmodule PhoenixKit.Modules.Publishing.API.ToolsConformanceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.API
  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKit.Modules.Publishing.API.Tools
  alias PhoenixKit.Modules.Publishing.Constants

  # Tool names in the order of spec §6.2, by phase. @phase is the last COMPLETED phase; the
  # task that closes a phase bumps it. Inside a phase the declared tools must be a prefix of
  # the phase's list, so the test is green after every task.
  @phases [
    p0: [],
    p1: ~w(list_groups get_group_settings_schema list_posts get_post list_categories),
    p2: ~w(create_post update_post create_version set_translation),
    p3: ~w(publish_post unpublish_post schedule_post trash_posts restore_posts),
    p4: ~w(upsert_categories delete_categories),
    p5: ~w(upsert_groups trash_groups restore_groups),
    p6: ~w(translate_post)
  ]
  @phase :p0

  # name => {scope, read_only?, max_items, danger kind}. :always | :fn | nil
  @table %{
    "list_groups" => {"publishing.groups:read", true, nil, nil},
    "get_group_settings_schema" => {"publishing.groups:read", true, nil, nil},
    "list_posts" => {"publishing.posts:read", true, nil, nil},
    "get_post" => {"publishing.posts:read", true, nil, nil},
    "list_categories" => {"publishing.categories:read", true, nil, nil},
    "create_post" => {"publishing.posts:write", false, nil, :fn},
    "update_post" => {"publishing.posts:write", false, nil, :fn},
    "create_version" => {"publishing.posts:write", false, nil, nil},
    "set_translation" => {"publishing.posts:write", false, nil, :fn},
    "translate_post" => {"publishing.translations:ai", false, nil, :always},
    "publish_post" => {"publishing.posts:publish", false, nil, :always},
    "unpublish_post" => {"publishing.posts:publish", false, nil, :always},
    "schedule_post" => {"publishing.posts:publish", false, nil, :always},
    "trash_posts" => {"publishing.posts:delete", false, 50, :always},
    "restore_posts" => {"publishing.posts:delete", false, 50, :fn},
    "upsert_categories" => {"publishing.categories:write", false, 100, :fn},
    "delete_categories" => {"publishing.categories:delete", false, 100, :always},
    "upsert_groups" => {"publishing.groups:write", false, 20, :fn},
    "trash_groups" => {"publishing.groups:delete", false, 20, :always},
    "restore_groups" => {"publishing.groups:delete", false, 20, :always}
  }

  defp expected_names do
    {done, rest} = Enum.split_while(@phases, fn {phase, _} -> phase != @phase end)
    done = done ++ Enum.take(rest, 1)
    next = Enum.at(rest, 1)
    {Enum.flat_map(done, &elem(&1, 1)), if(next, do: elem(next, 1), else: [])}
  end

  test "the declared tools are the finished phases plus a prefix of the current one, in order" do
    {finished, next} = expected_names()
    names = Tools.all() |> Enum.map(&String.replace_prefix(&1.name, "publishing.", ""))
    assert Enum.take(names, length(finished)) == finished
    extra = Enum.drop(names, length(finished))
    assert extra == Enum.take(next, length(extra))
  end

  test "every declared tool is in the phase map and the table" do
    all = @phases |> Keyword.values() |> List.flatten()

    for tool <- Tools.all() do
      short = String.replace_prefix(tool.name, "publishing.", "")
      assert short in all, "#{short} is missing from the phase map"
      assert Map.has_key?(@table, short)
    end
  end

  test "at the last phase all 20 tools are declared" do
    if @phase == :p6, do: assert(length(Tools.all()) == 20)
  end

  test "every tool is a valid admin tool of the publishing permission" do
    for tool <- Tools.all() do
      assert {:ok, _} = Tool.validate(tool), "#{tool.name} is not valid"
      assert tool.audience == :admin
      assert tool.permission == "publishing"
      assert is_binary(tool.title) and tool.title != ""
      assert String.length(tool.description) > 80
      assert is_map(tool.output_schema)
      assert match?({mod, :call} when is_atom(mod), tool.handler)
      {mod, :call} = tool.handler

      assert Code.ensure_loaded?(mod) and function_exported?(mod, :call, 2),
             "#{tool.name}: handler is not exported"
    end
  end

  test "scope, read-only flag, max_items and danger kind follow the table of spec §6.2" do
    for tool <- Tools.all() do
      short = String.replace_prefix(tool.name, "publishing.", "")
      {scope, read_only?, max, danger} = Map.fetch!(@table, short)
      assert tool.scope == scope, tool.name
      assert tool.annotations[:read_only] == true == read_only?, tool.name
      assert tool.max_items == max, tool.name

      case danger do
        nil ->
          assert tool.danger == nil, tool.name

        :always ->
          assert tool.danger == :always, tool.name

        :fn ->
          assert match?(
                   {Danger, f} when is_atom(f),
                   tool.danger
                 ),
                 tool.name
      end
    end
  end

  test "no WRITE tool takes status, published_at, tags, url_slug, force or delete" do
    for tool <- Tools.all(), tool.annotations[:read_only] != true do
      props = tool.input_schema |> collect_properties() |> MapSet.new()

      for forbidden <- ~w(status published_at tags url_slug force delete) do
        refute forbidden in props, "#{tool.name} accepts #{forbidden}"
      end
    end
  end

  test "schemas use only the keywords core's validator implements and close every object" do
    keywords =
      ~w(type enum required properties additionalProperties minimum maximum minLength maxLength pattern minItems maxItems items description default)

    for tool <- Tools.all() do
      assert_keywords(tool.input_schema, keywords, tool.name)

      assert tool.input_schema["additionalProperties"] == false,
             "#{tool.name}: root is not closed"
    end
  end

  test "a title property carries the module's length limit" do
    max_title = Constants.max_title_length()

    for tool <- Tools.all(),
        %{"maxLength" => max} <- [get_in(tool.input_schema, ["properties", "title"])] do
      assert max == max_title, tool.name
    end
  end

  test "delete_categories says what it does" do
    case Enum.find(Tools.all(), &(&1.name == "publishing.delete_categories")) do
      nil ->
        :ok

      tool ->
        assert tool.description =~ "Permanently"
        assert tool.description =~ "no undo"
        assert tool.annotations[:destructive] == true
        assert tool.scope == "publishing.categories:delete"
    end
  end

  test "every reason string in the handlers is in the contract of spec §6.6" do
    reasons =
      ~w(invalid_ref empty_update no_draft_version version_not_found language_not_enabled group_trashed post_trashed
      slug_not_allowed slug_taken invalid_slug reserved_language_code reserved_route_word invalid_name invalid_mode invalid_type
      title_required unknown_category content_too_large not_published not_timestamp_group slot_taken schedule_in_past mode_locked
      immutable_field invalid_setting parent_not_found parent_wrong_group category_cycle ai_not_configured nothing_to_translate
      cursor_stale empty_translation language_missing)

    warnings = ~w(language_missing limit_trimmed unfile_incomplete)

    allowed =
      MapSet.new(
        reasons ++
          warnings ++ ~w(not_found internal_error revision_mismatch validation_failed went_live)
      )

    used =
      Path.wildcard("lib/phoenix_kit_publishing/api/**/*.ex")
      |> Enum.flat_map(fn path ->
        Regex.scan(
          ~r/(?:reason|code):\s*"([a-z_]+)"|invalid\([^,]+,[^,]+,\s*"([a-z_]+)"/,
          File.read!(path)
        )
        |> Enum.flat_map(fn [_all | groups] -> Enum.reject(groups, &(&1 == "")) end)
      end)

    assert Enum.reject(used, &MapSet.member?(allowed, &1)) == []
  end

  @tag :core_api
  test "ToolLint finds nothing wrong with the tools" do
    assert :ok = ToolLint.check_tools(Tools.all())
  end

  test "api_tools/0 hands core the tools of API.tools/0" do
    assert Enum.map(Publishing.api_tools(), & &1.name) ==
             Enum.map(API.tools(), & &1.name)
  end

  defp collect_properties(%{"properties" => props}), do: Map.keys(props)
  defp collect_properties(_), do: []

  # A schema node: its own keys are validator keywords; recurse into `properties` values (whose
  # KEYS are free names) and `items`.
  defp assert_keywords(%{} = schema, allowed, name) do
    for key <- Map.keys(schema),
        do:
          assert(key in allowed, "#{name}: keyword #{key} is not implemented by core's validator")

    Enum.each(schema["properties"] || %{}, fn {_property, sub} ->
      assert_keywords(sub, allowed, name)
    end)

    if is_map(schema["items"]), do: assert_keywords(schema["items"], allowed, name)
  end

  defp assert_keywords(_other, _allowed, _name), do: :ok
end
