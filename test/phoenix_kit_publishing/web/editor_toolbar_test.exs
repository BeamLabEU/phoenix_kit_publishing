defmodule PhoenixKit.Modules.Publishing.Web.EditorToolbarTest do
  @moduledoc """
  The editor's own toolbar buttons for PHK components.

  Leaf ships image and video buttons and routes them into the media picker.
  The block components — Showcase, Note, CTA, Headline — had no affordance at
  all: the only way to reach them was to know the tag and type it, which
  means they may as well not exist for anyone who hasn't read the format doc.
  Leaf's `toolbar_extra` is the seam; this pins the wiring on our side.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "toolbar-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})

    {:ok, view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    %{view: view, html: html}
  end

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  defp toolbar_action(view, id, selected \\ "") do
    send(
      view.pid,
      {:leaf_toolbar_action,
       %{editor_id: "content-editor", id: id, selection: %{text: selected, range: nil}}}
    )

    render(view)
  end

  test "the component buttons reach the toolbar", %{html: html} do
    for id <- ~w(phk-headline phk-showcase phk-gallery phk-audio phk-note phk-cta) do
      assert html =~ id, "#{id} must be offered in the toolbar"
    end
  end

  test "gallery and audio open the picker instead of inserting a skeleton", %{view: view} do
    # Both render as NOTHING when empty, so a placeholder skeleton would look
    # exactly like a button that did nothing. They collect their files first.
    toolbar_action(view, "phk-gallery")
    gallery = assigns_of(view)

    assert gallery[:show_media_selector]
    assert gallery[:inserting_gallery]
    assert gallery[:media_selection_mode] == :multiple, "a gallery needs more than one picture"
    assert gallery[:media_selector_target] == "gallery"

    refute_push_event(view, "leaf-command:content-editor", %{action: "insert_markdown"})
  end

  test "the audio button picks one audio file", %{view: view} do
    toolbar_action(view, "phk-audio")
    a = assigns_of(view)

    assert a[:show_media_selector]
    assert a[:inserting_audio]
    assert a[:media_selection_mode] == :single
    assert a[:media_selector_target] == "audio_component"
  end

  test "a chosen gallery arrives as uuid-backed images, not frozen URLs", %{view: view} do
    toolbar_action(view, "phk-gallery")

    uuids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    send(view.pid, {:media_selected, uuids})
    _ = render(view)

    assert_push_event(view, "leaf-command:content-editor", %{
      action: "insert_markdown",
      text: text
    })

    assert text =~ "<Gallery"
    assert text =~ "</Gallery>"

    # file_uuid, so the URL is resolved at render time and the post survives a
    # change of storage prefix or signing secret.
    for uuid <- uuids do
      assert text =~ ~s(file_uuid="#{uuid}")
    end

    refute text =~ "/file/"
  end

  test "a note wraps the selection instead of replacing it", %{view: view} do
    toolbar_action(view, "phk-note", "brought to life")

    assert_push_event(view, "leaf-command:content-editor", %{
      action: "insert_markdown",
      text: text
    })

    # A note annotates a phrase, so the phrase has to survive the insert.
    assert text =~ "brought to life"
    assert text =~ "<Note note="
  end

  test "an unselected component still arrives with something visible", %{view: view} do
    toolbar_action(view, "phk-showcase")

    assert_push_event(view, "leaf-command:content-editor", %{
      action: "insert_markdown",
      text: text
    })

    assert text =~ "<Showcase"
    assert text =~ "</Showcase>"

    # An empty component renders as nothing, which reads as a broken button.
    refute text =~
             "<Showcase src=\"\" side=\"left\" overlap=\"18\" height=\"medium\" alt=\"\">\n\n</Showcase>"
  end

  test "an unknown button id is ignored rather than crashing", %{view: view} do
    html = toolbar_action(view, "not-a-real-button")
    assert is_binary(html)
  end

  test "a read-only session cannot insert components", %{view: view} do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :readonly?, true))
    end)

    toolbar_action(view, "phk-cta")

    refute_push_event(view, "leaf-command:content-editor", %{action: "insert_markdown"})
  end

  test "leaving with unsaved work is guarded again", %{html: html} do
    # Existed before the move to Leaf and was lost in it. Nothing else here
    # catches a tab close or a back button with edits outstanding.
    assert html =~ ~s(data-protect-navigation="true")
  end

  test "Leaf's save badge stays off, because ours says more", %{html: html} do
    # The other attr dropped in that swap, deliberately not restored: Leaf's
    # badge only knows saved/saving/unsaved, while the editor's own badge
    # says WHY a save is blocked. Two indicators disagreeing is worse than
    # one — and the blank-title test in editor_live_test.exs fails outright
    # when both are on screen.
    refute html =~ "background:#22c55e;"
    refute html =~ "background:#9ca3af;"
  end
end
