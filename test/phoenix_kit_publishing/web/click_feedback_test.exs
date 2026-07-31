defmodule PhoenixKit.Modules.Publishing.Web.ClickFeedbackTest do
  @moduledoc """
  Clicks that do server work have to say so while they're doing it.

  LiveView puts `phx-click-loading` on the clicked element for exactly the
  in-flight window, so the affordance is pure CSS: the icon hides, a spinner
  shows, and further clicks are ignored. That makes it invisible to an
  ordinary render assertion — nothing about the markup changes at rest — so
  it is pinned here against the rendered classes instead.

  Scope is deliberate. A click that opens a modal or expands a panel is
  self-evidencing: the thing appearing IS the feedback. These are the ones
  where the interface sits still while a database write happens.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "feedback-#{System.unique_integer([:positive])}"
    {:ok, _group} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "Post", slug: "post", content: "Body"})
    {:ok, cat} = Categories.create_category(slug, %{"name" => "Filed"})
    {:ok, _} = Categories.replace_post_categories(post[:uuid], [cat.uuid])

    %{slug: slug, post: post, cat: cat}
  end

  defp editor_html(ctx) do
    {:ok, _view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{ctx.slug}/#{ctx.post[:uuid]}/edit")

    html
  end

  # The markup for one button, so an assertion can't accidentally match a
  # spinner belonging to a different control.
  defp button_html(html, event) do
    html
    |> String.split(~r/<button/)
    |> Enum.find(fn chunk -> chunk =~ ~s(phx-click="#{event}") end)
    |> Kernel.||("")
    |> String.split("</button>")
    |> List.first()
  end

  # The `&` in Tailwind's arbitrary variants is HTML-escaped on the way out,
  # so `[&.phx-click-loading]:x` arrives as `[&amp;.phx-click-loading]:x`.
  # Matching the un-escaped source form silently never matches.
  @in_flight_ignores_clicks ".phx-click-loading]:pointer-events-none"
  @glyph_gives_way "[.phx-click-loading_&amp;]:hidden"

  test "removing a category chip shows a spinner while the server answers", ctx do
    chunk = editor_html(ctx) |> button_html("category_remove")

    assert chunk =~ "loading-spinner", "the x must acknowledge the click"
    assert chunk =~ @glyph_gives_way, "the x glyph must give way to it"

    assert chunk =~ @in_flight_ignores_clicks,
           "a second click while the first is in flight would remove twice"
  end

  test "preview shows a spinner, because it saves before it navigates", ctx do
    chunk = editor_html(ctx) |> button_html("preview")

    assert chunk =~ "loading-spinner"
    assert chunk =~ @in_flight_ignores_clicks
  end

  test "the translation-prompt buttons show one too" do
    # Pinned at the source: the AI panel only renders when the `ai` module is
    # active, which it isn't in this suite, so there is no rendered markup to
    # assert against. Both buttons write to the database and leave the page
    # looking identical until they answer.
    source = File.read!("lib/phoenix_kit_publishing/web/editor.ex")

    for event <- ~w(generate_default_translation_prompt regenerate_default_translation_prompt) do
      [_, after_event] = String.split(source, ~s(phx-click="#{event}"), parts: 2)
      button_tail = after_event |> String.split("</button>") |> List.first()

      assert button_tail =~ "loading-spinner", "#{event} must acknowledge the click"
    end
  end
end
