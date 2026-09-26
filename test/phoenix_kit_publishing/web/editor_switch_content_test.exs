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
    assert_push_event(view, @leaf, %{action: "flush", ref: ref})
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
    assert_patch(view)
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

    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})
  end

  test "switching to a language without a translation empties the editor", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "fr-FR"}, "English body.", dirty: false)

    assert_push_event(view, @leaf, %{action: "set_content", content: ""})
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

    assert_push_event(view, @leaf, %{action: "set_content", content: "Second version body."})
  end

  test "the last keystrokes go with the switch instead of being dropped", ctx do
    user = with_real_user()
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid, user_uuid: user)

    # Typed inside Leaf's debounce, so the server has not seen it yet: the
    # switch's flush brings it, and the pre-switch save writes it.
    switch(view, "switch_language", %{"language" => "de-DE"}, "English body. Last word.")

    {:ok, english} = Publishing.read_post_by_uuid(ctx.uuid, "en-US", 1)
    assert english.content == "English body. Last word."
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})
  end

  test "a surface that never answers the flush does not leave the click dead", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_push_event(view, @leaf, %{action: "flush", ref: _ref})

    # No Leaf on the page: the timeout acts on what the server holds.
    assert_patch(view, 3_000)
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})
  end

  test "a flush reply that is not dirty leaves the post clean", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)
    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})

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
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})
    assert_push_event(view, @leaf, %{action: "flush", ref: ref})

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
    assert_push_event(view, @leaf, %{action: "flush", ref: german_ref})

    switch(view, "switch_language", %{"language" => "fr-FR"}, "Deutscher Text.", dirty: false)
    assert_push_event(view, @leaf, %{action: "flush", ref: french_ref})
    assert german_ref != french_ref

    send(view.pid, {:leaf_flushed, Map.put(leaf_payload("Deutscher Text."), :ref, german_ref)})
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text.")})
    refute render(view) =~ "Unsaved changes"

    send(view.pid, {:leaf_flushed, Map.put(leaf_payload(""), :ref, french_ref)})
    send(view.pid, {:leaf_changed, leaf_payload("Texte.")})
    assert render(view) =~ "Unsaved changes"
  end

  test "a surface that mounts after a switch holds the current document", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    switch(view, "switch_language", %{"language" => "de-DE"}, "English body.", dirty: false)
    assert_push_event(view, @leaf, %{action: "flush", ref: _ref})

    # Leaf's script finished loading only now: the commands above never
    # reached it, and the node still shows the English text it rendered at
    # first. The document is handed over again, with a fresh ref.
    send(view.pid, {:leaf_ready, %{editor_id: "content-editor", markdown: "English body."}})
    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})

    # Until that hand-over is answered, the old text is still not an edit.
    send(view.pid, {:leaf_changed, leaf_payload("English body.")})
    refute render(view) =~ "Unsaved changes"

    answer_flush(view, "Deutscher Text.", dirty: false)
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text. Mehr.")})
    assert render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text. Mehr."
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
    assert helper =~ "def set_editor_content(socket, content)"
    assert helper =~ "action: :set_content"
  end
end
