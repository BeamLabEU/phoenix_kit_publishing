defmodule PhoenixKit.Modules.Publishing.Web.AudioPickerTest do
  @moduledoc """
  The Audio version field opens a picker containing only audio.

  It used to open the whole library and refuse a wrong choice afterwards,
  which puts the mistake after the effort: you browse, pick a file, and only
  then learn that kind isn't allowed. The refusal stays as a backstop — this
  pins that the user isn't offered the wrong thing in the first place.

  > #### Needs local core {: .warning}
  >
  > `lock_file_type` (and `:audio` as a filter at all) landed in core after
  > the pin in `mix.exs`, so the narrowing test fails against the published
  > package — the old modal ignores the attr and keeps its type `<select>`.
  > Run with `PHOENIX_KIT_PATH=../phoenix_kit mix test` until core ships it.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "audiopick-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})

    {:ok, view, _html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    %{view: view}
  end

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  @tag :needs_unreleased_core
  test "opening it for audio narrows the picker to audio and locks it", %{view: view} do
    render_click(view, "open_media_selector", %{"field" => "audio_uuid"})

    html = render(view)
    assert assigns_of(view)[:media_selector_target] == "audio_uuid"

    # The type <select> is what would let someone browse back to everything.
    refute html =~ "All Files",
           "a locked picker must not offer its way back to the other types"
  end

  test "the featured image picker still offers the whole library", %{view: view} do
    render_click(view, "open_media_selector", %{"field" => "featured_image_uuid"})

    assert render(view) =~ "All Files",
           "only audio is narrowed; taking choices away elsewhere isn't the fix"
  end

  test "a non-audio file is still refused if it reaches the handler", %{view: view} do
    render_click(view, "open_media_selector", %{"field" => "audio_uuid"})

    # The picker no longer offers this, but the message is still reachable —
    # a stale tab, a forged event — so the server keeps its own guard.
    send(view.pid, {:media_selected, [Ecto.UUID.generate()]})

    html = render(view)
    assert html =~ "isn&#39;t audio" or html =~ "isn't audio"
  end
end
