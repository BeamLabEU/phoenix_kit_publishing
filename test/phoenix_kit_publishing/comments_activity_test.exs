defmodule PhoenixKit.Modules.Publishing.CommentsActivityTest do
  @moduledoc """
  Comments were the one publishing mutation with no audit trail — and the one
  most obviously worth telling somebody about.

  The notification half matters more than it looks. Core skips the fan-out
  when `target_uuid` is nil, and no publishing activity set one, so the module
  produced exactly zero notifications despite logging 28 kinds of action. A
  comment on your post, and a reply to your comment, are the two that have an
  obvious recipient.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Comments
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo

  @author "019cce93-0000-7000-8000-0000000000a1"
  @reader "019cce93-0000-7000-8000-0000000000a2"

  # The author column carries a foreign key, so the fixture needs real rows.
  defp insert_user(uuid, email) do
    Repo.query!(
      """
      INSERT INTO phoenix_kit_users (uuid, email, hashed_password, inserted_at, updated_at)
      VALUES ($1::uuid, $2, 'x', now(), now())
      ON CONFLICT (email) DO NOTHING
      """,
      [Ecto.UUID.dump!(uuid), email]
    )
  end

  setup do
    # Without this the comments module reports itself unavailable and every
    # create returns {:error, :comments_unavailable} — which the tests below
    # would happily accept, passing while exercising nothing.
    {:ok, _} = Settings.update_boolean_setting("comments_enabled", true)

    insert_user(@author, "cmt-author@example.com")
    insert_user(@reader, "cmt-reader@example.com")

    slug = "cmtlog-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")

    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})

    # The author normally comes from the caller's scope; set it directly so
    # the fixture doesn't depend on scope plumbing that isn't under test.
    Repo.query!(
      "UPDATE phoenix_kit_publishing_posts SET created_by_uuid = $1::uuid WHERE uuid = $2::uuid",
      [Ecto.UUID.dump!(@author), Ecto.UUID.dump!(post[:uuid])]
    )

    %{slug: slug, post: post}
  end

  test "the module registers notification types, or nobody can mute them" do
    types = Publishing.notification_types()

    assert [%{key: "publishing", sub_types: subs}] = types

    actions = subs |> Enum.flat_map(& &1.actions) |> Enum.sort()
    assert actions == ["publishing.comment.created", "publishing.comment.replied"]

    # Every action a module notifies on must be registered, or the preferences
    # screen has no switch for it and the reader can't turn it off.
    for sub <- subs do
      assert sub.actions != []
      assert is_boolean(sub.default)
    end
  end

  test "commenting on a post is logged and aimed at the author", ctx do
    # Comments themselves need the optional module; the logging contract is
    # what's under test, so skip cleanly when it isn't installed.
    assert Comments.available?(), "the logging path can't be exercised without comments"

    case Comments.create(ctx.post[:uuid], @reader, "Nice piece.") do
      {:ok, _comment} ->
        entry = last_activity("publishing.comment.created")

        assert entry.actor_uuid == @reader

        assert entry.target_uuid == @author,
               "without a target_uuid core skips the fan-out and nobody is told"

        assert entry.resource_uuid == ctx.post[:uuid]
        assert entry.metadata["notification_text"]
    end
  end

  test "a comment on your own post notifies nobody", ctx do
    assert Comments.available?()

    case Comments.create(ctx.post[:uuid], @author, "Following up on my own post.") do
      {:ok, _} ->
        entry = last_activity("publishing.comment.created")

        # Core would skip it anyway, but leaving the target set would mean the
        # audit row claims a recipient that never got anything.
        assert is_nil(entry.target_uuid)
    end
  end

  defp last_activity(action) do
    import Ecto.Query

    Repo.one(
      from(a in "phoenix_kit_activities",
        where: a.action == ^action,
        order_by: [desc: a.inserted_at],
        limit: 1,
        select: %{
          actor_uuid: type(a.actor_uuid, Ecto.UUID),
          target_uuid: type(a.target_uuid, Ecto.UUID),
          resource_uuid: type(a.resource_uuid, Ecto.UUID),
          metadata: a.metadata
        }
      )
    )
  end
end
