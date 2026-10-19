defmodule PhoenixKit.Modules.Publishing.API.ToolsConformanceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.API
  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKit.Modules.Publishing.API.Schemas
  alias PhoenixKit.Modules.Publishing.API.Tools
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.GroupSettings

  # The declared order of the tool list: translate_post sits after set_translation.
  @tool_order ~w(list_groups get_group_settings_schema list_posts get_post list_categories
                 create_post update_post create_version set_translation translate_post
                 publish_post unpublish_post schedule_post trash_posts restore_posts
                 upsert_categories delete_categories upsert_groups trash_groups restore_groups)

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

  test "the declared tools are the 20 tools, in the declared order" do
    names = Tools.all() |> Enum.map(&String.replace_prefix(&1.name, "publishing.", ""))
    assert names == @tool_order
    assert length(names) == 20
  end

  test "every declared tool is in the table" do
    for tool <- Tools.all() do
      short = String.replace_prefix(tool.name, "publishing.", "")
      assert Map.has_key?(@table, short), "#{short} is missing from the table"
    end

    assert Enum.sort(Map.keys(@table)) == Enum.sort(@tool_order)
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

  test "scope, read-only flag, max_items and danger kind follow the declared table" do
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

  test "the settings object of upsert_groups mirrors GroupSettings: its keys, types and allowed values" do
    schema = Schemas.group_settings()
    entries = Map.new(GroupSettings.schema(), &{&1.key, &1})

    assert Enum.sort(Map.keys(schema["properties"])) == Enum.sort(GroupSettings.keys())
    assert schema["additionalProperties"] == false

    for {key, property} <- schema["properties"] do
      case entries[key] do
        %{type: :boolean} -> assert property == %{"type" => "boolean"}, key
        %{type: :enum, allowed: allowed} -> assert property["enum"] == allowed, key
      end
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

  # The literal reason of every `invalid(path, message, reason, ...)` call, the literal code of
  # every `row_error(ref, code, ...)` call and of every `{:error, "code", message}` tuple, read from
  # the syntax tree so a comma in the message or a multi-line call cannot hide one.
  defp call_reasons(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {name, _, [_path, _message, reason | _]} = node, acc
        when name == :invalid and is_binary(reason) ->
          {node, [reason | acc]}

        {{:., _, [_module, :invalid]}, _, [_path, _message, reason | _]} = node, acc
        when is_binary(reason) ->
          {node, [reason | acc]}

        {:{}, _, [:error, code, _message]} = node, acc when is_binary(code) ->
          {node, [code | acc]}

        {:row_error, _, [_ref, code | _]} = node, acc when is_binary(code) ->
          {node, [code | acc]}

        {{:., _, [_module, :row_error]}, _, [_ref, code | _]} = node, acc when is_binary(code) ->
          {node, [code | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  test "every reason string in the handlers is in the error contract" do
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
        source = File.read!(path)

        keyed =
          ~r/(?:reason|code):\s*"([a-z_]+)"/
          |> Regex.scan(source)
          |> Enum.map(fn [_all, reason] -> reason end)

        keyed ++ call_reasons(source)
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
