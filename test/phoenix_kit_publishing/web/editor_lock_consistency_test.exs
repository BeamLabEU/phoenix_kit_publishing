defmodule PhoenixKit.Modules.Publishing.Web.EditorLockConsistencyTest do
  @moduledoc """
  When the editing lock is gone, the whole page has to agree about it.

  The lock lapses on inactivity, and the page said so — but only some
  controls went dead with it. The title, body, status and categories
  disabled themselves while the media pickers, the clear buttons and the AI
  actions stayed live, so the page simultaneously claimed to be read-only
  and offered a dozen ways to edit. Two different bugs wear that costume:

  * controls that are refused server-side but still look clickable — the
    user presses them and nothing happens, with no explanation;
  * controls that are NOT refused, which is the serious one. The media
    picker was in this group: a session whose lock had lapsed could still
    assign a featured image, OG image or audio, broadcast it to the real
    editor and autosave it over their work.

  So this pins both halves: every write path checks, and every editing
  control is visibly disabled.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  @owner "019cce93-0000-7000-8000-0000000000c1"
  @watcher "019cce93-0000-7000-8000-0000000000c2"

  setup do
    slug = "lockui-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})
    %{slug: slug, post: post}
  end

  defp open(uuid, email, ctx) do
    {:ok, view, _html} =
      build_conn()
      |> put_test_scope(fake_scope(user_uuid: uuid, email: email))
      |> live("/admin/publishing/#{ctx.slug}/#{ctx.post[:uuid]}/edit")

    view
  end

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  # A second session on the same post is read-only because someone else holds
  # the lock.
  defp watcher_view(ctx) do
    owner = open(@owner, "owner@example.com", ctx)
    _ = render(owner)
    watcher = open(@watcher, "watcher@example.com", ctx)
    _ = render(watcher)
    assert assigns_of(watcher)[:readonly?] == true
    watcher
  end

  # The opening tag of the control carrying `event`, straight from the
  # template: everything from its `<button` to the `>` that closes the tag.
  #
  # Source rather than render, for the controls that only appear in the
  # lapsed-lock state. That state can't be held still in a LiveView test:
  # driving the real timer works, but for a SOLO editor the untrack fires a
  # presence diff that promotes the same session straight back to owner —
  # and injecting the assigns with `:sys.replace_state` doesn't mark them
  # changed, so LiveView never re-renders and `render/1` hands back the HTML
  # from BEFORE the injection. An assertion there passes or fails on stale
  # markup, which is worse than not having one.
  defp source_tag_for(event) do
    source = File.read!("lib/phoenix_kit_publishing/web/editor.ex")
    [before, rest] = String.split(source, ~s(phx-click="#{event}"), parts: 2)

    opening = before |> String.split("<button") |> List.last()
    closing = rest |> String.split(">") |> List.first()

    opening <> closing
  end

  test "the media picker cannot write while read-only", ctx do
    watcher = watcher_view(ctx)
    before = assigns_of(watcher)[:form]["featured_image_uuid"]

    # Exactly what the picker sends when the user confirms a choice.
    send(watcher.pid, {:media_selected, [Ecto.UUID.generate()]})
    _ = render(watcher)

    after_pick = assigns_of(watcher)

    assert after_pick[:form]["featured_image_uuid"] == before,
           "a lapsed session must not be able to set the featured image"

    refute after_pick[:has_pending_changes],
           "and must not queue a save that would overwrite the real editor"
  end

  # Every control carrying this event, as its own markup, so a `disabled`
  # belonging to a neighbouring button can't satisfy the assertion.
  defp buttons_for(html, event) do
    html
    |> String.split(~r/<button/)
    |> Enum.filter(&(&1 =~ ~s(phx-click="#{event}")))
    |> Enum.map(&(&1 |> String.split("</button>") |> List.first()))
  end

  test "the media pickers are disabled when someone else holds the lock", ctx do
    html = ctx |> watcher_view() |> render()

    pickers = buttons_for(html, "open_media_selector")
    assert pickers != [], "expected the media pickers to be on the page"

    for button <- pickers do
      assert button =~ "disabled",
             "a picker that stays clickable is how the write hole was reachable"
    end
  end

  test "a lapsed lock still offers the way back" do
    # The counterpart to the rule above: disabling everything would strand
    # someone whose lock merely lapsed, because this is the one control that
    # takes it back. It renders only in that state, not for a spectator.
    refute source_tag_for("resume_editing") =~ "disabled",
           "the way back must never be disabled"
  end

  test "the AI actions are disabled too, not just the text fields" do
    # These enqueue real work against the post. The server refuses them while
    # read-only, so leaving the buttons live meant pressing them did nothing
    # and said nothing.
    for event <- ~w(translate_to_all_languages translate_missing_languages
                    translate_to_this_language generate_default_translation_prompt) do
      assert source_tag_for(event) =~ "edit_disabled?",
             "#{event} must go dead with the rest of the page"
    end
  end
end
