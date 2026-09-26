defmodule PhoenixKit.Modules.Publishing.Web.EditorSwitchContentTest do
  @moduledoc """
  A switch of language or version has to put the new text INTO the editor.

  Leaf renders `@content` once: its surface is `phx-update="ignore"`, so a
  later assign changes nothing on screen, and the client takes a new
  document through `action: :set_content` only. The editor pushed a
  `"set-content"` event that core's MarkdownEditor hook used to handle and
  Leaf never did — so switching to Russian showed the English body until
  the page was reloaded. This pins that every buffer swap now reaches Leaf,
  and that a plain mount does not (a reset there would wipe the undo history
  for nothing, and a same-scope patch after a save would drop keystrokes).
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  @leaf "leaf-command:content-editor"

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

  defp open_editor(slug, uuid, query \\ "lang=en-US&v=1") do
    build_conn()
    |> put_test_scope(fake_scope())
    |> live("/admin/publishing/#{slug}/#{uuid}/edit?#{query}")
  end

  test "opening the editor renders the text once and does not re-send it", ctx do
    {:ok, view, html} = open_editor(ctx.slug, ctx.uuid)

    assert html =~ "English body."
    refute_push_event(view, @leaf, %{action: "set_content"})
  end

  test "switching to a language that has content puts that content in the editor", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    # The switch is deferred: the event shows the skeleton, a message to self
    # then patches the URL and handle_params loads the other language.
    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_patch(view)

    assert_push_event(view, @leaf, %{action: "set_content", content: "Deutscher Text."})
  end

  test "switching to a language without a translation empties the editor", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "switch_language", %{"language" => "fr-FR"})
    assert_patch(view)

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

    render_click(view, "switch_version", %{"version" => "2"})
    assert_patch(view)

    assert_push_event(view, @leaf, %{action: "set_content", content: "Second version body."})
  end

  test "a change flushed out of the previous language never lands in the new one", ctx do
    {:ok, view, _html} = open_editor(ctx.slug, ctx.uuid)

    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_patch(view)
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

    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_patch(view)
    assert_push_event(view, @leaf, %{action: "flush", ref: german_ref})

    render_click(view, "switch_language", %{"language" => "fr-FR"})
    assert_patch(view)
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

    render_click(view, "switch_language", %{"language" => "de-DE"})
    assert_patch(view)
    assert_push_event(view, @leaf, %{action: "flush", ref: _ref})

    # Leaf's script finished loading only now: the commands above never
    # reached it, but it rendered the German document itself.
    send(view.pid, {:leaf_ready, %{editor_id: "content-editor", markdown: "Deutscher Text."}})
    send(view.pid, {:leaf_changed, leaf_payload("Deutscher Text. Mehr.")})
    assert render(view) =~ "Unsaved changes"
    assert buffer(view) == "Deutscher Text. Mehr."
  end

  # What the editor would save: the content assign behind autosave.
  defp buffer(view), do: :sys.get_state(view.pid).socket.assigns.content

  defp leaf_payload(markdown) do
    %{editor_id: "content-editor", markdown: markdown, html: "", dirty: true}
  end

  test "no editor source pushes the event that only core's old hook listened for" do
    for file <- ~w(editor.ex editor/persistence.ex editor/versions.ex editor/collaborative.ex) do
      source = File.read!("lib/phoenix_kit_publishing/web/#{file}")

      refute source =~ ~s|push_event("set-content"|,
             "#{file} pushes \"set-content\", which Leaf ignores — use Helpers.set_editor_content/2"
    end

    helper = File.read!("lib/phoenix_kit_publishing/web/editor/helpers.ex")
    assert helper =~ "def set_editor_content(socket, content)"
    assert helper =~ "action: :set_content"
  end
end
