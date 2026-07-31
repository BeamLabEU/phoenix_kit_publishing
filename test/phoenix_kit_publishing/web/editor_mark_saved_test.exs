defmodule PhoenixKit.Modules.Publishing.Web.EditorMarkSavedTest do
  @moduledoc """
  Telling Leaf that the content is saved.

  Two things track "is there unsaved work" independently: our own
  `has_pending_changes`, which drives the badge and arms autosave, and Leaf's
  internal snapshot, which drives its navigation guard. Only the first was
  ever set, so after restoring `protect_navigation` the guard believed every
  saved post still had outstanding work and challenged the reader on every
  refresh — while the content had in fact been written.

  The fix is one helper that says it to both, so the two can't drift apart
  again. That is what this pins.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "marksaved-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})

    {:ok, view, _html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    %{view: view, slug: slug, post: post}
  end

  test "a successful save tells Leaf the content is saved", %{view: view} do
    send(
      view.pid,
      {:leaf_changed, %{editor_id: "content-editor", markdown: "Edited body.", html: ""}}
    )

    _ = render(view)

    render_click(view, "save", %{})

    # Without this the navigation guard keeps firing forever: Leaf compares
    # against a snapshot that only `mark_saved` updates.
    assert_push_event(view, "leaf-command:content-editor", %{action: "mark_saved"})
  end

  test "the two clean-state signals are one function, not two lines" do
    # They were separate, and drifted immediately. Anything that goes clean
    # must go through the helper so it cannot say one and forget the other.
    for file <- ~w(editor.ex editor/persistence.ex editor/versions.ex) do
      source = File.read!("lib/phoenix_kit_publishing/web/#{file}")

      refute source =~ "assign(:has_pending_changes, false)",
             "#{file} sets the clean flag directly instead of via Helpers.mark_clean/1"
    end

    helper = File.read!("lib/phoenix_kit_publishing/web/editor/helpers.ex")
    assert helper =~ "def mark_clean(socket)"
    assert helper =~ "action: :mark_saved"
    assert helper =~ ":has_pending_changes, false"
  end
end
