defmodule PhoenixKit.Modules.Publishing.API.MappingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.API.Common

  # code, reason (nil = none), for each module error of spec §6.6
  @mapped %{
    not_found: {:not_found, nil},
    post_not_found: {:not_found, nil},
    group_not_found: {:not_found, nil},
    resource_not_found: {:not_found, nil},
    no_post: {:not_found, nil},
    source_not_found: {:validation_failed, "version_not_found"},
    invalid_version: {:validation_failed, "version_not_found"},
    version_not_found: {:validation_failed, "version_not_found"},
    title_required: {:validation_failed, "title_required"},
    slug_already_exists: {:validation_failed, "slug_taken"},
    slug_taken: {:validation_failed, "slug_taken"},
    already_exists: {:validation_failed, "slug_taken"},
    conflicts_with_post_slug: {:validation_failed, "slug_taken"},
    conflicts_with_previous_slug: {:validation_failed, "slug_taken"},
    invalid_slug: {:validation_failed, "invalid_slug"},
    invalid_format: {:validation_failed, "invalid_slug"},
    reserved_language_code: {:validation_failed, "reserved_language_code"},
    reserved_route_word: {:validation_failed, "reserved_route_word"},
    invalid_name: {:validation_failed, "invalid_name"},
    invalid_mode: {:validation_failed, "invalid_mode"},
    invalid_type: {:validation_failed, "invalid_type"},
    post_trashed: {:validation_failed, "post_trashed"},
    not_published: {:validation_failed, "not_published"},
    no_published_version: {:validation_failed, "not_published"},
    category_cycle: {:validation_failed, "category_cycle"},
    parent_not_found: {:validation_failed, "parent_not_found"},
    parent_wrong_group: {:validation_failed, "parent_wrong_group"},
    timestamp_collision_unresolvable: {:validation_failed, "slot_taken"},
    ai_disabled: {:validation_failed, "ai_not_configured"},
    ai_no_prompt: {:validation_failed, "ai_not_configured"},
    ai_endpoint_not_found: {:validation_failed, "ai_not_configured"},
    ai_endpoint_disabled: {:validation_failed, "ai_not_configured"},
    went_live: {:revision_mismatch, nil},
    locked_check_failed: {:internal_error, nil}
  }

  # Everything else is internal_error (spec §6.6, last two rows)
  @internal ~w(db_update_failed content_copy_failed params_not_applied no_uuid cache_miss no_active_version no_version
               invalid_content invalid_path invalid_order invalid_status cannot_delete_live cannot_delete_primary_language
               last_language last_version destination_exists version_access_disabled unpublished)a

  # A literal copy of Errors.error_atom() (lib/phoenix_kit_publishing/errors.ex) plus the extras of spec §6.6.
  @error_atoms ~w(already_exists cache_miss cannot_delete_live category_cycle conflicts_with_post_slug db_update_failed
    destination_exists group_not_found invalid_content invalid_format invalid_mode invalid_name invalid_order invalid_path
    invalid_slug invalid_status invalid_type invalid_version cannot_delete_primary_language last_language last_version no_post
    no_published_version no_uuid not_found not_published params_not_applied parent_not_found parent_wrong_group post_not_found
    post_trashed resource_not_found reserved_language_code reserved_route_word slug_already_exists slug_taken
    timestamp_collision_unresolvable title_required unpublished version_access_disabled ai_disabled ai_no_prompt
    ai_endpoint_not_found ai_endpoint_disabled)a ++
                 ~w(source_not_found no_active_version no_version conflicts_with_previous_slug version_not_found
                     content_copy_failed went_live locked_check_failed)a

  test "every module error atom is mapped or listed as internal" do
    for atom <- Enum.uniq(@error_atoms) do
      assert Map.has_key?(@mapped, atom) or atom in @internal, "#{atom} is not classified"
    end
  end

  test "mapped atoms classify as the table says" do
    for {atom, {code, reason}} <- @mapped do
      assert {^code, ^reason, _message, _context} = Common.classify(atom), inspect(atom)
    end
  end

  test "unclassified atoms and odd shapes are internal_error, and the reason is never returned" do
    for reason <- @internal ++ [:something_new, {:publish_failed, :x}, "string", nil, %{}] do
      assert {:internal_error, nil, message, context} = Common.classify(reason)
      refute message =~ "something_new"
      assert context == %{}
    end
  end

  test "went_live carries its reason in the context" do
    assert {:revision_mismatch, nil, _, %{reason: "went_live"}} = Common.classify(:went_live)
  end

  test "a changeset becomes validation_failed with field paths, never inspect output" do
    changeset =
      {%{}, %{slug: :string}}
      |> Ecto.Changeset.cast(%{slug: "x"}, [:slug])
      |> Ecto.Changeset.add_error(:slug, "is bad", validation: :format)

    assert {:validation_failed, nil, _msg, %{errors: [%{path: "slug", message: "is bad"}]}} =
             Common.classify(changeset)
  end

  test "a unique-constraint changeset is classified by constraint NAME" do
    slug = %Ecto.Changeset{
      valid?: false,
      data: %{},
      errors: [
        group_uuid:
          {"has already been taken",
           [constraint: :unique, constraint_name: "idx_publishing_posts_group_slug"]}
      ]
    }

    slot = %Ecto.Changeset{
      valid?: false,
      data: %{},
      errors: [
        group_uuid:
          {"has already been taken",
           [constraint: :unique, constraint_name: "idx_publishing_posts_group_date_time_unique"]}
      ]
    }

    assert {:validation_failed, "slug_taken", _, _} = Common.classify(slug)
    assert {:validation_failed, "slot_taken", _, _} = Common.classify(slot)
  end

  test "a static scan finds no {:error, atom} or rollback(atom) in the sources that the table does not cover" do
    known =
      MapSet.new(
        @error_atoms ++
          ~w(group_not_active wrong_group no_translated_name not_configured other_library miss comments_unavailable)a
      )

    atoms =
      for path <- Path.wildcard("lib/phoenix_kit_publishing/**/*.ex"),
          not String.contains?(path, "/web/"),
          not String.contains?(path, "/api/"),
          [_full | groups] <-
            Regex.scan(~r/\{:error, :([a-z_]+)\}|rollback\(:([a-z_]+)\)/, File.read!(path)),
          atom <- groups,
          atom != "",
          do: String.to_atom(atom)

    unknown = atoms |> Enum.uniq() |> Enum.reject(&MapSet.member?(known, &1))

    assert unknown == [],
           "new error atoms upstream: #{inspect(unknown)}; classify them in Common and this test"
  end
end
