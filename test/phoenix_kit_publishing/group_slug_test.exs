defmodule PhoenixKit.Modules.Publishing.GroupSlugTest do
  @moduledoc """
  Group slug generation after adopting core's `Slug.put_slug/3`.

  The local generator this replaces was DEAD CODE on the path it existed
  for: `validate_required([:name, :slug, :mode])` ran six pipe steps before
  it, so a create without an explicit slug failed "can't be blank" before
  generation could have supplied one. Generation now runs before the
  require, and probes for collisions, which the old code never did.
  """
  use PhoenixKitPublishing.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PublishingGroup

  defp changeset(attrs, group \\ %PublishingGroup{}) do
    PublishingGroup.changeset(group, attrs)
  end

  describe "creation without an explicit slug" do
    test "is now valid — the dead-code path this fixes" do
      cs = changeset(%{name: "My Publication", mode: "timestamp"})

      assert cs.valid?
      assert Changeset.get_change(cs, :slug) == "my-publication"
    end

    test "a Cyrillic name romanizes rather than emptying" do
      cs = changeset(%{name: "Новости компании", mode: "timestamp"})

      assert cs.valid?

      slug = Changeset.get_change(cs, :slug)
      assert is_binary(slug) and slug != ""
      assert slug =~ ~r/^[a-z0-9-]+$/
    end
  end

  describe "existing behaviour preserved" do
    test "an explicit slug wins" do
      cs = changeset(%{name: "My Publication", slug: "chosen", mode: "timestamp"})

      assert Changeset.get_change(cs, :slug) == "chosen"
    end

    test "a rename does not move an existing slug" do
      existing = %PublishingGroup{name: "Old", slug: "old", mode: "timestamp"}
      cs = changeset(%{name: "Renamed"}, existing)

      assert Changeset.get_change(cs, :slug) == nil
      assert Changeset.get_field(cs, :slug) == "old"
    end
  end

  describe "collisions" do
    test "a second group named alike suffixes -2" do
      {:ok, _} =
        %{name: "Same Name", mode: "timestamp"} |> changeset() |> Repo.insert()

      {:ok, second} =
        %{name: "Same Name", mode: "timestamp"} |> changeset() |> Repo.insert()

      assert second.slug == "same-name-2"
    end
  end

  # The tests above drive `PublishingGroup.changeset/2` directly. Nothing in the
  # app does: `Groups.add_group/2` — what the New Group LiveView calls — derives
  # and uniquifies the slug itself and always hands the changeset an explicit
  # one, so `put_slug/3` no-ops on every production create. These pin the
  # context's own generator, which is the one that actually runs.
  describe "Groups.add_group/2 — the path the admin UI takes" do
    test "a trashed group still owns its slug" do
      {:ok, first} = Groups.add_group("News")
      assert first["slug"] == "news"
      {:ok, "news"} = Groups.trash_group("news")

      # idx_publishing_groups_slug has no status predicate, so "news" is still
      # taken. Probing only the ACTIVE groups reported it free and the insert
      # died on the constraint, surfacing as {:error, :already_exists} for a
      # group the admin can no longer see anywhere.
      assert {:ok, second} = Groups.add_group("News")
      assert second["slug"] == "news-2"
    end

    test "an explicit slug taken by a trashed group is refused, not crashed into" do
      {:ok, _} = Groups.add_group("News")
      {:ok, "news"} = Groups.trash_group("news")

      assert {:error, :already_exists} = Groups.add_group("Bulletin", slug: "news")
    end

    test "the suffix counts up from the base rather than nesting" do
      {:ok, _} = Groups.add_group("Same Name")
      {:ok, second} = Groups.add_group("Same Name")
      {:ok, third} = Groups.add_group("Same Name")

      assert second["slug"] == "same-name-2"
      # The old loop recursed on the SUFFIXED slug, so the third was
      # "same-name-2-3".
      assert third["slug"] == "same-name-3"
    end
  end
end
