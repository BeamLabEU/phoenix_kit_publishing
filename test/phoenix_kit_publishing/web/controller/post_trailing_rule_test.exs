defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostTrailingRuleTest do
  @moduledoc """
  One horizontal rule between the article and what follows it.

  The page already announced every other change of register with a rule: the
  header closes with one, the comments section and the footer open with one.
  The categories row and the prev/next links sat in between on margin alone,
  so the prose appeared to trail off into its own filing metadata.

  Which element carries the rule depends on the group's settings — either can
  be absent — so it is a flag rather than a fixed class, and that is what can
  regress: two rules where the boundary is one, or none at all.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  # Bare `border-t`: the page's other rules use the default border colour, and
  # naming a shade drew this one at oklch(0.96 …) against their oklch(0.21 …)
  # — a line that was there in the DOM and invisible on the screen.
  @rule "mt-6 border-t pt-4"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)

    {:ok, group} = Groups.add_group("trail-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Trailing",
        slug: "trailing",
        content: "Body."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{slug: group["slug"], post: post}
  end

  defp html(conn, ctx), do: conn |> get("/#{ctx.slug}/trailing") |> html_response(200)

  defp rules(html), do: html |> String.split(@rule) |> length() |> Kernel.-(1)

  test "categories carry the rule when shown", ctx do
    {:ok, cat} = Categories.create_category(ctx.slug, %{"name" => "Filed"})
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [cat.uuid])
    {:ok, _} = Groups.update_group(ctx.slug, %{"show_categories" => "true"})

    body = html(build_conn(), ctx)

    assert body =~ "Filed"
    assert rules(body) == 1, "one boundary deserves exactly one rule"
  end

  test "prev/next takes the rule when there are no categories", ctx do
    # Neighbours are drawn from PUBLISHED posts, so a draft leaves the nav
    # unrendered and the test would pass against a page that has no boundary
    # to draw at all.
    {:ok, neighbour} =
      Posts.create_post(ctx.slug, %{title: "Neighbour", slug: "neighbour", content: "N."})

    :ok = Versions.publish_version(ctx.slug, neighbour.uuid, 1)
    {:ok, _} = Groups.update_group(ctx.slug, %{"show_prev_next" => "true"})

    body = html(build_conn(), ctx)

    # Without this the rule would belong only to a row that isn't rendered,
    # and the article would run into the navigation with nothing between.
    assert rules(body) == 1
  end

  test "never two rules for the one boundary", ctx do
    {:ok, cat} = Categories.create_category(ctx.slug, %{"name" => "Filed"})
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [cat.uuid])

    {:ok, neighbour} =
      Posts.create_post(ctx.slug, %{title: "Neighbour", slug: "neighbour", content: "N."})

    :ok = Versions.publish_version(ctx.slug, neighbour.uuid, 1)

    {:ok, _} =
      Groups.update_group(ctx.slug, %{
        "show_categories" => "true",
        "show_prev_next" => "true"
      })

    body = html(build_conn(), ctx)

    assert rules(body) == 1, "two rules stacked a few lines apart read as a table"
  end

  test "no rule when neither section is shown", ctx do
    body = html(build_conn(), ctx)

    # The comments section and footer bring their own; an extra rule here
    # would fence off nothing.
    assert rules(body) == 0
  end
end
