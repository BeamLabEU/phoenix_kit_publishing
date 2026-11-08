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
  alias PhoenixKit.Modules.Publishing.Errors
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PublishingGroup

  defp changeset(attrs, group \\ %PublishingGroup{}) do
    PublishingGroup.changeset(group, attrs)
  end

  # The mode is locked at creation, so an unknown one must be refused rather
  # than turned into the default for good.
  describe "add_group/2 mode" do
    test "an unknown mode is :invalid_mode, not a timestamp group" do
      assert {:error, :invalid_mode} =
               Groups.add_group("Mode #{System.unique_integer([:positive])}", mode: "slugs")
    end

    test "no mode (or a blank one) is the default" do
      assert {:ok, %{"mode" => "timestamp"}} =
               Groups.add_group("Mode #{System.unique_integer([:positive])}")

      assert {:ok, %{"mode" => "timestamp"}} =
               Groups.add_group("Mode #{System.unique_integer([:positive])}", mode: "")

      assert {:ok, %{"mode" => "slug"}} =
               Groups.add_group("Mode #{System.unique_integer([:positive])}", mode: :slug)
    end
  end

  # `/admin/publishing/new-group`, `/edit-group/:g` and `/categories/:g` are
  # literal routes beside `/admin/publishing/:group`: a group under one of
  # these slugs could never be opened.
  describe "admin route segments" do
    test "a name that slugifies to one gets a suffix" do
      assert {:ok, %{"slug" => slug}} = Groups.add_group("New Group")
      refute slug == "new-group"

      assert {:ok, %{"slug" => slug}} = Groups.add_group("Categories")
      refute slug == "categories"
    end

    test "an explicit one is refused, at create and at rename" do
      assert {:error, :invalid_slug} = Groups.add_group("X", slug: "edit-group")

      {:ok, group} = Groups.add_group("Rename #{System.unique_integer([:positive])}")

      assert {:error, :invalid_slug} =
               Groups.update_group(group["slug"], %{"slug" => "categories"})
    end
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

    # "Admin" used to slug to "admin" — a group the host's own routes
    # shadow. A derived slug is suffixed past the reserved word, like a
    # taken one; an explicit reserved slug is a clean `Errors` atom, not a
    # crash and not a silently shadowed group.
    test "a reserved route word is suffixed past when derived and refused when explicit" do
      {:ok, group} = Groups.add_group("Admin")
      assert group["slug"] == "admin-2"

      assert {:error, :invalid_slug} = Groups.add_group("Back office", slug: "admin")
      assert {:error, :invalid_slug} = Groups.add_group("Back office", slug: "settings")

      assert is_binary(Errors.message(:invalid_slug))
    end
  end
end
