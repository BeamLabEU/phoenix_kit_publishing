defmodule PhoenixKit.Modules.Publishing.Web.EditorSwitchContentTest do
  @moduledoc """
  A switch of language or version has to put the new text INTO the editor,
  and take the writer's last keystrokes WITH it.

  Leaf renders `@content` once: its surface is `phx-update="ignore"`, so a
  later assign changes nothing on screen, and the client takes a new
  document through `action: :set_content` only. The editor pushed a
  `"set-content"` event that core's MarkdownEditor hook used to handle and
  Leaf never did — so switching to Russian showed the English body until
  the page was reloaded.

  Leaf also keeps up to a debounce of keystrokes on the client and flushes
  them on blur — AFTER the click that switches — so the switch first asks
  for the buffer with a ref (`after_flush/2`) and acts when it is back; and
  after the new document is handed over, another ref-flush marks the point
  from which `leaf_changed` speaks for it (`awaiting_buffer_ref`). The
  surface re-serialises in its own markdown dialect, so a flush reply is
  applied only when Leaf itself says the surface is dirty.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @leaf "leaf-command:content-editor"
  @saver_uuid "019cce93-0000-7000-8000-00000000ee02"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          },
          %{
            "code" => "fr-FR",
            "name" => "French",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 2
          }
        ]
      })

    {:ok, group} =
      Groups.add_group("Switch content #{System.unique_integer([:positive])}", mode: "slug")

    slug = group["slug"]
    {:ok, post} = Posts.create_post(slug, %{title: "English title", slug: "switch-content"})

    {:ok, saved} =
      Publishing.update_post(slug, post, %{
        "title" => "English title",
        "content" => "English body.",
        "status" => "draft"
      })

    {:ok, _} = Publishing.add_language_to_post(slug, saved[:uuid], "de-DE", 1)
    {:ok, german} = Publishing.read_post_by_uuid(saved[:uuid], "de-DE", 1)

    {:ok, _} =
      Publishing.update_post(slug, german, %{
        "title" => "Deutscher Titel",
        "content" => "Deutscher Text.",
        "status" => "draft"
      })

    %{slug: slug, uuid: saved[:uuid]}
  end

  defp open_editor(slug, uuid, opts \\ []) do
    scope = fake_scope(Keyword.take(opts, [:user_uuid]))

    build_conn()
    |> put_test_scope(scope)
    |> live("/admin/publishing/#{slug}/#{uuid}/edit?lang=en-US&v=1")
  end

  # The save stamps updated_by_uuid, so a test that expects a row to be
  # written needs a user that exists.
  defp with_real_user do
    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_users (uuid, email, hashed_password, inserted_at, updated_at)
      VALUES ($1::uuid, 'switch-saver@example.com', 'x', now(), now())
      ON CONFLICT (email) DO NOTHING
      """,
      [Ecto.UUID.dump!(@saver_uuid)]
    )

    @saver_uuid
  end

  # What Leaf sends: a `content_changed` (→ leaf_changed) and then the
  # `flushed` reply carrying the same markdown and the ref.
  defp answer_flush(view, markdown, opts) do
    assert_push_event(view, @leaf, %{action: "flush", ref: ref}, 1000)
    dirty? = Keyword.get(opts, :dirty, true)
    send(view.pid, {:leaf_changed, leaf_payload(markdown, dirty?)})
    send(view.pid, {:leaf_flushed, Map.put(leaf_payload(markdown, dirty?), :ref, ref)})
    ref
  end

  # A click that flushes first: answer with the surface's text, then follow
  # the patch the action makes.
  defp switch(view, event, params, markdown, opts \\ []) do
    render_click(view, event, params)
    answer_flush(view, markdown, opts)
    assert_patch(view, 1000)
  end

  defp leaf_payload(markdown, dirty? \\ true) do
    %{editor_id: "content-editor", markdown: markdown, html: "", dirty: dirty?}
  end

  # What the editor would save: the content assign behind autosave.
  defp buffer(view), do: :sys.get_state(view.pid).socket.assigns.content

  test "opening the editor renders the text once and does not re-send it", ctx do
    {:ok, view, html} = open_editor(ctx.slug, ctx.uuid)

    assert html =~ "English body."
    refute_push_event(view, @leaf, %{action: "set_content"})
  end

  test "switching to a language that has content puts that content in the editor", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)

    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)
  end

  test "switching to a language without a translation empties the editor", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "fr-FR"}, "English body.", dirty: false)

    assert_push_event(view, @leaf, %{action: "set_content", content: ""}, 1000)
  end

  test "switching versions puts the other version's text in the editor", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.uuid, 1)
    {:ok, second} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 2)

    {:ok, _} =
      Publishing.update_post(ctx.slug, second, %{
        "title" => "English title",
        "content" => "Second version body.",
        "status" => "draft"
      })

    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_version", %{"version" => "2"}, "English body.", dirty: false)

    assert_push_event(
      view,
      @leaf,
      %{action: "set_content", content: "Second version body."},
      1000
    )
  end

  # The switch subscribes under the new form key, then patches; handle_params
  # comes back with that same key as the "old" one. A second subscribe there
  # delivered every message twice: an AI translation's completions counted
  # double and the lock lifted at half the jobs.
  test "a version switch leaves one subscription per topic, not two", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.uuid, 1)
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_version", %{"version" => "2"}, "English body.", dirty: false)
    _ = render(view)

    assigns = :sys.get_state(view.pid).socket.assigns
    post_id = PublishingPubSub.broadcast_id(assigns.post)

    for topic <- [
          PublishingPubSub.editor_form_topic(assigns.form_key),
          PublishingPubSub.post_translations_topic(ctx.slug, post_id),
          PublishingPubSub.post_versions_topic(ctx.slug, post_id)
        ] do
      subscriptions =
        :phoenix_kit_internal_pubsub
        |> Registry.lookup(topic)
        |> Enum.count(fn {pid, _} -> pid == view.pid end)

      assert subscriptions == 1, "#{subscriptions} subscriptions to #{topic}"
    end
  end

  # Edits made before another session's AI translation locked the post are
  # still pending; the Save button refuses them, and so must the save a
  # switch makes on its way out.
  test "a switch under the translation lock does not save pending edits", ctx do
    user = with_real_user()
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid, user_uuid: user)

    # Typed before the lock: the edit is pending when the lock arrives.
    send(view.pid, {:leaf_changed, leaf_payload("English body. Typed before the lock.")})
    _ = render(view)
    assert :sys.get_state(view.pid).socket.assigns.has_pending_changes

    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = Map.put(socket.assigns, :translation_locked?, true)
      %{state | socket: %{socket | assigns: assigns}}
    end)

    render_click(view, "switch_language", %{"language" => "de-DE"})
    answer_flush(view, "English body. Typed before the lock.", [])

    assert render(view) =~ "Cannot save while translation is in progress"
    {:ok, english} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert english.content == "English body."
  end

  # A save in another language of the same version cannot change this
  # language's body; handing Leaf the stored body replaced its document and
  # dropped what was typed inside its debounce.
  test "a sibling language's save does not replace this editor's text", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)
    form_key = :sys.get_state(view.pid).socket.assigns.form_key
    sibling_key = String.replace_suffix(form_key, ":en-US", ":de-DE")
    refute sibling_key == form_key

    send(view.pid, {:sibling_editor_saved, sibling_key, "another-socket"})
    _ = render(view)

    refute_push_event(view, @leaf, %{action: "set_content"})
  end

  # Back is decided once Leaf has handed its buffer over: the blur flush comes
  # AFTER the click, so deciding on the server's state alone left without a
  # prompt while keystrokes were still on the client.
  test "Back with keystrokes still on the client asks before leaving", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "back_to_list", %{})
    answer_flush(view, "English body. Typed just now.", [])

    assert render(view) =~ "You have unsaved changes. Leave without saving?"
  end

  test "Back with nothing pending leaves once the buffer is in", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "back_to_list", %{})
    answer_flush(view, "English body.", dirty: false)

    {path, _flash} = assert_redirect(view, 1000)
    assert String.ends_with?(path, "/admin/publishing/#{ctx.slug}")
  end

  # A mention click is a navigation like any other switch: the last keystrokes
  # are collected and saved first.
  test "following a mention saves the last keystrokes first", ctx do
    {:ok, other} =
      Posts.create_post(ctx.slug, %{title: "Other", slug: "other", content: "Other body."})

    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid, user_uuid: with_real_user())

    send(view.pid, {:leaf_link_clicked, %{target: "post:" <> other.uuid}})
    answer_flush(view, "English body. Before following.", [])

    {path, _flash} = assert_redirect(view, 1000)
    assert path =~ other.uuid

    {:ok, english} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert english.content == "English body. Before following."
  end

  # Renamed while open: saves look the post up under the group slug, so the
  # editor must take the new one or every autosave answers "Not found".
  test "a rename of the group keeps the open editor saving", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid, user_uuid: with_real_user())

    new_slug = ctx.slug <> "-renamed"
    {:ok, _} = Groups.update_group(ctx.slug, %{"slug" => new_slug})

    assert render(view) =~ "This group was renamed to #{new_slug}"
    assert :sys.get_state(view.pid).socket.assigns.group_slug == new_slug

    send(view.pid, {:leaf_changed, leaf_payload("English body. After the rename.")})
    _ = render(view)
    _ = render_click(view, "save", %{})

    {:ok, english} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert english.content == "English body. After the rename."
  end

  test "the last keystrokes go with the switch instead of being dropped", ctx do
    user = with_real_user()
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid, user_uuid: user)

    # Typed inside Leaf's debounce, so the server has not seen it yet: the
    # switch's flush brings it, and the pre-switch save writes it.
    switch(view, "switch_language", %{"language" => "de-DE"}, "English body. Last word.")

    {:ok, english} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert english.content == "English body. Last word."
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)
  end

  test "creating a version saves and copies the last client keystrokes", ctx do
    {:ok, view, _} = open_editor(ctx.slug, ctx.uuid, user_uuid: with_real_user())
    render_click(view, "open_new_version_modal", %{})
    render_click(view, "set_new_version_source", %{"source" => "1"})
    render_click(view, "create_version_from_source", %{})

    assert {:ok, original} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert original.content == "English body."
    assert original.available_versions == [1]

    answer_flush(view, "Last keystrokes before copying.", dirty: true)
    assert_redirect(view, 1000)

    assert {:ok, original} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert {:ok, copy} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 2)
    assert original.content == "Last keystrokes before copying."
    assert copy.content == original.content
  end

  test "a surface that never answers the flush is told, then the click is given up", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_push_event(view, @leaf, %{action: "flush", ref: ref}, 1000)

    # First the wait shows; nothing is switched on stale text.
    send(view.pid, {:flush_slow, ref})
    assert render(view) =~ "Collecting your edits"
    refute_push_event(view, @leaf, %{action: "set_content"})

    # Then the click is abandoned with a warning, and the surface is still
    # the English document.
    send(view.pid, {:flush_abandon, ref})
    html = render(view)
    assert html =~ "The editor did not answer"
    refute html =~ "Collecting your edits"
    refute_push_event(view, @leaf, %{action: "set_content"})
    assert :sys.get_state(view.pid).socket.assigns.pending_after_flush == nil

    # A reply that comes after the abandon changes nothing.
    send(view.pid, {:leaf_flushed, Map.put(leaf_payload("English body."), :ref, ref)})
    refute_push_event(view, @leaf, %{action: "set_content"})
  end

  test "a flush reply that is not dirty leaves the post clean", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)
    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)

    # The buffer ack: hybrid mode hands the document back re-serialised, and
    # Leaf says it is not dirty. Nothing was edited, nothing may be saved.
    answer_flush(view, "Deutscher Text.\n", dirty: false)

    refute render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text."
  end

  test "a not-dirty echo is ignored while clean and applied while work is pending", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    # A blur re-serialised the untouched body: not an edit.
    send(view.pid, {:leaf_changed, leaf_payload("English body.\n", false)})
    refute render(view) =~ "Unsaved changes"
    assert buffer(view) == "English body."

    # Typed, then typed back to the saved text inside the autosave window:
    # the server copy must follow, or autosave writes the abandoned text.
    send(view.pid, {:leaf_changed, leaf_payload("English body. X", true)})
    assert render(view) =~ "Unsaved changes"
    send(view.pid, {:leaf_changed, leaf_payload("English body.", false)})
    refute render(view) =~ "Unsaved changes"
    assert buffer(view) == "English body."
  end

  test "a change flushed out of the previous language never lands in the new one", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)
    assert_push_event(view, @leaf, %{action: "flush", ref: ref}, 1000)

    # Leaf flushes on blur, and the click that switched the language blurred
    # the editor, so the English text arrives after the German post is loaded.
    send(view.pid, {:leaf_changed, leaf_payload("English body.")})
    refute render(view) =~ "Unsaved changes"

    # The flush's own reply carries whatever the surface holds now.
    send(view.pid, {:leaf_flushed, Map.put(leaf_payload("Deutscher Text."), :ref, ref)})
    refute render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text."

    # From here on the surface speaks for the German document.
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text. Mehr.")})
    assert render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text. Mehr."
  end

  test "a flush answered for a document replaced since is ignored", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "flush", ref: german_ref}, 1000)

    switch(view, "switch_language", %{"language" => "fr-FR"}, "Deutscher Text.", dirty: false)
    assert_push_event(view, @leaf, %{action: "flush", ref: french_ref}, 1000)
    assert german_ref != french_ref

    send(view.pid, {:leaf_flushed, Map.put(leaf_payload("Deutscher Text."), :ref, german_ref)})
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text.")})
    refute render(view) =~ "Unsaved changes"

    send(view.pid, {:leaf_flushed, Map.put(leaf_payload(""), :ref, french_ref)})
    send(view.pid, {:leaf_changed, leaf_payload("Texte.")})
    assert render(view) =~ "Unsaved changes"
  end

  test "a hand-over nobody answers is retried once, then abandoned", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)
    assert_push_event(view, @leaf, %{action: "flush", ref: first_ref}, 1000)

    # Leaf's script had not mounted when the commands were pushed: the node
    # still shows the English text it rendered at first, and nothing answers.
    # A late `ready` alone changes nothing (a ready that merely arrives late
    # would otherwise wipe text typed meanwhile).
    send(view.pid, {:leaf_ready, %{editor_id: "content-editor", markdown: "English body."}})
    refute_push_event(view, @leaf, %{action: "set_content"})

    # The check fires: the document is handed over again with a fresh ref,
    # and the old text is still not an edit.
    send(view.pid, {:handover_check, first_ref})
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."}, 1000)
    assert_push_event(view, @leaf, %{action: "flush", ref: second_ref}, 1000)
    assert second_ref != first_ref
    send(view.pid, {:leaf_changed, leaf_payload("English body.")})
    refute render(view) =~ "Unsaved changes"

    # Still nothing: the wait is abandoned rather than retried forever.
    send(view.pid, {:handover_check, second_ref})
    refute_push_event(view, @leaf, %{action: "set_content"})
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text. Mehr.")})
    assert render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text. Mehr."
  end

  test "a title-only edit followed by a not-dirty blur keeps the stored body", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_change(view, "update_meta", %{"title" => "Renamed", "_target" => ["title"]})
    assert render(view) =~ "Unsaved changes"

    # The blur re-serialises the untouched body; Leaf says it is not dirty.
    send(view.pid, {:leaf_changed, leaf_payload("- English body.\n", false)})
    assert render(view) =~ "Unsaved changes"
    assert buffer(view) == "English body."
  end

  test "closing the media picker forgets every insertion mode", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    send(view.pid, {:leaf_insert_request, %{type: :image}})
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.show_media_selector
    assert assigns.inserting_image_component
    assert assigns.media_selector_scope == {"en-US", 1}

    send(view.pid, {:media_selector_closed})
    assigns = :sys.get_state(view.pid).socket.assigns
    refute assigns.show_media_selector
    refute assigns.inserting_image_component
    refute assigns.inserting_audio
    refute assigns.inserting_gallery
    assert assigns.media_selection_mode == :single
    assert assigns.media_selector_scope == nil
  end

  test "a media pick made for another version or language is dropped", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    send(view.pid, {:leaf_insert_request, %{type: :image}})
    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)

    send(view.pid, {:media_selected, [Ecto.UUID.generate()]})
    _ = render(view)

    refute_push_event(view, @leaf, %{action: "insert_markdown"})
    refute :sys.get_state(view.pid).socket.assigns.show_media_selector
  end

  test "no editor source pushes the event that only core's old hook listened for" do
    for file <- ~w(editor.ex editor/persistence.ex editor/versions.ex editor/collaborative.ex) do
      source = File.read!("lib/phoenix_kit_publishing/web/#{file}")

      refute source =~ ~s|push_event("set-content"|,
             "#{file} pushes set-content, which Leaf ignores — use Helpers.set_editor_content/2"
    end

    helper = File.read!("lib/phoenix_kit_publishing/web/editor/helpers.ex")
    assert helper =~ "def set_editor_content(socket, content"
    assert helper =~ "action: :set_content"
  end
end
