defmodule PhoenixKit.Modules.Publishing.Web.Controller.DisplaySettingsRenderTest do
  @moduledoc """
  Pins every per-group display setting to its public-render effect: OFF (the
  default) leaves the page unchanged, ON renders the feature. Guards the
  settings surface end-to-end — group `data` JSONB → controller assigns →
  `Web.HTML` — so a broken assign chain can't ship while the unit tests on the
  accessors stay green.
  """

  # async: false — mutates the global publishing/language settings rows, same
  # deadlock risk public_routes_test.exs documents.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "display-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Display Post",
        slug: "display-post",
        content: "Hello world content for the display settings tests."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"], post: post}
  end

  defp set!(slug, params) do
    {:ok, updated} = Groups.update_group(slug, params)
    updated
  end

  defp listing_html(conn, slug), do: get(conn, "/" <> slug) |> html_response(200)

  defp post_html(conn, slug, post_slug),
    do: get(conn, "/#{slug}/#{post_slug}") |> html_response(200)

  # ==========================================================================
  # Listing page
  # ==========================================================================

  describe "listing: show_post_count" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ "1 post"

      set!(slug, %{"show_post_count" => "true"})
      assert listing_html(conn, slug) =~ "1 post"
    end
  end

  describe "listing: scroll_timeline_enabled" do
    test "off by default, config element with granularity + localized months when on", %{
      conn: conn,
      group_slug: slug
    } do
      refute listing_html(conn, slug) =~ "pk-timeline-config"

      set!(slug, %{
        "scroll_timeline_enabled" => "true",
        "scroll_timeline_granularity" => "month"
      })

      html = listing_html(conn, slug)
      assert html =~ "pk-timeline-config"
      assert html =~ ~s(data-granularity="month")
      # The rail's month labels ride the config element so they localize —
      # regression pin for the hardcoded-English MONTHS array.
      assert html =~ "data-months="
      assert html =~ "data-label="
    end
  end

  describe "listing: scrollbar_style" do
    test "native bar by default, styled when branded", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ "::-webkit-scrollbar"

      set!(slug, %{"scrollbar_style" => "branded"})
      assert listing_html(conn, slug) =~ "::-webkit-scrollbar"
    end
  end

  describe "listing: show_breadcrumbs" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug} do
      refute listing_html(conn, slug) =~ ~s(class="breadcrumbs)

      set!(slug, %{"show_breadcrumbs" => "true"})
      assert listing_html(conn, slug) =~ ~s(class="breadcrumbs)
    end
  end

  describe "listing: featured posts" do
    test "a featured post renders in the Featured band with a data-post-date", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, _} = Posts.update_post(slug, post, %{"featured" => "true"}, %{})

      html = listing_html(conn, slug)
      assert html =~ "Featured"
      # The rail bins cards by data-post-date — featured cards must carry it
      # too, or a featured-only page never builds a timeline (regression pin).
      assert html =~ "data-post-date="
    end

    test "featured_enabled=false renders the post in the plain grid", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, _} = Posts.update_post(slug, post, %{"featured" => "true"}, %{})
      set!(slug, %{"featured_enabled" => "false"})

      html = listing_html(conn, slug)
      refute html =~ "badge-primary badge-sm"
      assert html =~ "Display Post"
    end
  end

  describe "listing: newest post band" do
    test "off by default, Latest band pulls the newest post out of the grid", %{
      conn: conn,
      group_slug: slug
    } do
      {:ok, second} =
        Posts.create_post(slug, %{
          title: "Second Post",
          slug: "second-post",
          content: "Newer content."
        })

      :ok = Versions.publish_version(slug, second.uuid, 1)
      {:ok, _} = Posts.update_post(slug, second, %{"published_at" => "2031-06-01T00:00:00Z"}, %{})

      refute listing_html(conn, slug) =~ "badge-secondary badge-sm"

      set!(slug, %{"newest_enabled" => "true"})
      html = listing_html(conn, slug)
      assert html =~ "badge-secondary badge-sm"
      # The newest post renders once — in the Latest band, not also in the grid.
      assert length(String.split(html, "Second Post")) - 1 == 1
      # The older post stays in the grid.
      assert html =~ "Display Post"
    end

    test "a featured newest post stays in the Featured band; Latest takes the next-newest", %{
      conn: conn,
      group_slug: slug
    } do
      {:ok, second} =
        Posts.create_post(slug, %{
          title: "Second Post",
          slug: "second-post",
          content: "Newer content."
        })

      :ok = Versions.publish_version(slug, second.uuid, 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          second,
          %{"published_at" => "2031-06-01T00:00:00Z", "featured" => "true"},
          %{}
        )

      set!(slug, %{"newest_enabled" => "true"})
      html = listing_html(conn, slug)

      # Featured band (first) carries the newer post; Latest band the older one.
      {latest_pos, _} = :binary.match(html, "badge-secondary badge-sm")
      {featured_pos, _} = :binary.match(html, "badge-primary badge-sm")
      assert featured_pos < latest_pos

      {newer_pos, _} = :binary.match(html, "Second Post")
      {older_pos, _} = :binary.match(html, "Display Post")

      assert newer_pos < latest_pos,
             "the featured newer post should render before the Latest band"

      assert older_pos > latest_pos, "the older post should render inside the Latest band"
    end
  end

  describe "listing: listing_animations" do
    test "hover lift on by default, gone when disabled", %{conn: conn, group_slug: slug} do
      assert listing_html(conn, slug) =~ "motion-safe:hover:-translate-y-1"

      set!(slug, %{"listing_animations" => "false"})
      html = listing_html(conn, slug)
      refute html =~ "motion-safe:hover:-translate-y-1"
      refute html =~ "hover:shadow"
    end
  end

  describe "listing: band styles (featured_style / newest_style)" do
    test "classic by default — no style markers", %{conn: conn, group_slug: slug} do
      set!(slug, %{"newest_enabled" => "true"})
      html = listing_html(conn, slug)
      refute html =~ "from-black/80"
      refute html =~ "border-s-4"
      refute html =~ "bg-base-100/95"
    end

    test "cover renders the scrim and, with no image, the branded gradient fallback", %{
      conn: conn,
      group_slug: slug
    } do
      set!(slug, %{"newest_enabled" => "true", "newest_style" => "cover"})
      html = listing_html(conn, slug)
      # Hardcoded scrim + the Latest band's secondary-leaning no-image gradient.
      assert html =~ "from-black/80"
      assert html =~ "from-secondary to-primary"
      assert html =~ "✦"
      # The whole background clicks through to the post…
      assert html =~ "pk-band-cover-link"

      # …gated on the same setting as card-image links.
      set!(slug, %{"listing_image_links" => "false"})
      refute listing_html(conn, slug) =~ "pk-band-cover-link"
    end

    test "featured cover uses the primary-leaning fallback gradient", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, _} = Posts.update_post(slug, post, %{"featured" => "true"}, %{})
      set!(slug, %{"featured_style" => "cover"})
      html = listing_html(conn, slug)
      assert html =~ "from-primary to-secondary"
    end

    test "cover_panel renders the opaque text panel", %{conn: conn, group_slug: slug} do
      set!(slug, %{"newest_enabled" => "true", "newest_style" => "cover_panel"})
      assert listing_html(conn, slug) =~ "bg-base-100/95"
    end

    test "minimal renders the accent-border editorial band", %{conn: conn, group_slug: slug} do
      set!(slug, %{"newest_enabled" => "true", "newest_style" => "minimal"})
      html = listing_html(conn, slug)
      assert html =~ "border-s-4"
      assert html =~ "border-secondary"
    end

    test "top drops the image banner cleanly when the post has none", %{
      conn: conn,
      group_slug: slug
    } do
      set!(slug, %{"newest_enabled" => "true", "newest_style" => "top"})
      html = listing_html(conn, slug)
      # Badge + body render; the 16:9 banner is absent without an image.
      assert html =~ "badge-secondary badge-sm"
      refute html =~ "aspect-video"
    end
  end

  describe "listing: group-wide date counts with a pinned Latest post" do
    test "a page-2 same-day sibling of the pinned newest post keeps its time-segment URL", %{
      conn: conn
    } do
      {:ok, group} = Groups.add_group(unique_name(), mode: "timestamp")
      slug = group["slug"]

      make = fn title, iso ->
        {:ok, p} = Posts.create_post(slug, %{title: title, content: "Body."})
        :ok = Versions.publish_version(slug, p.uuid, 1)
        {:ok, _} = Posts.update_post(slug, p, %{"published_at" => iso}, %{})
      end

      make.("Newest Pin", "2020-06-01T10:00:00Z")
      make.("Mid Same Day", "2020-06-01T09:00:00Z")
      make.("Sibling Same Day", "2020-06-01T08:00:00Z")

      prior_per_page = Settings.get_setting("publishing_posts_per_page")
      {:ok, _} = Settings.update_setting("publishing_posts_per_page", "1")

      on_exit(fn ->
        {:ok, _} = Settings.update_setting("publishing_posts_per_page", prior_per_page || "20")
      end)

      set!(slug, %{"newest_enabled" => "true"})

      html = get(conn, "/#{slug}", %{"page" => "2"}) |> html_response(200)
      # Page 2 shows only the oldest same-day post; the pinned newest and the
      # page-1 post are outside the visible set, but the group-wide date counts
      # must still see all three 2020-06-01 posts and keep the time segment
      # that disambiguates the URL (regression pin for per-page date_counts).
      assert html =~ "Sibling Same Day"
      assert html =~ "2020-06-01/08:00"
    end
  end

  describe "listing: listing_sort" do
    test "newest first by default, oldest first when configured", %{
      conn: conn,
      group_slug: slug
    } do
      {:ok, second} =
        Posts.create_post(slug, %{
          title: "Second Post",
          slug: "second-post",
          content: "Newer content."
        })

      :ok = Versions.publish_version(slug, second.uuid, 1)

      # Same-second publishes would tie the ISO-8601 sort keys — pin explicit
      # effective dates so the ordering assertion is deterministic.
      {:ok, _} =
        Posts.update_post(slug, second, %{"published_at" => "2031-06-01T00:00:00Z"}, %{})

      html = listing_html(conn, slug)
      {first_pos, _} = :binary.match(html, "Display Post")
      {second_pos, _} = :binary.match(html, "Second Post")
      assert second_pos < first_pos, "newest-first should render the newer post first"

      set!(slug, %{"listing_sort" => "oldest"})
      html = listing_html(conn, slug)
      {first_pos, _} = :binary.match(html, "Display Post")
      {second_pos, _} = :binary.match(html, "Second Post")
      assert first_pos < second_pos, "oldest-first should render the older post first"
    end
  end

  # ==========================================================================
  # Post page
  # ==========================================================================

  describe "post page: header toolbar row" do
    test "empty toolbar (no switcher, no admin, no versions) renders no wrapper", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      # Single language + anonymous viewer — every toolbar child is absent, so
      # the mt-4 flex row must not render (it left an awkward gap under the
      # title).
      refute post_html(conn, slug, post.slug) =~ "flex flex-wrap items-center gap-4 mt-4"
    end
  end

  describe "post page: show_top_back_link" do
    test "renders top + footer back links by default, footer only when disabled", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      html = post_html(conn, slug, post.slug)
      assert length(String.split(html, "Back to")) - 1 == 2

      set!(slug, %{"show_top_back_link" => "false"})
      html = post_html(conn, slug, post.slug)
      assert length(String.split(html, "Back to")) - 1 == 1
    end
  end

  describe "post page: show_reading_time" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug, post: post} do
      refute post_html(conn, slug, post.slug) =~ "min read"

      set!(slug, %{"show_reading_time" => "true"})
      assert post_html(conn, slug, post.slug) =~ "min read"
    end
  end

  describe "post page: post_width" do
    test "normal by default, narrow/wide map to their classes", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      assert post_html(conn, slug, post.slug) =~ "max-w-4xl"

      set!(slug, %{"post_width" => "narrow"})
      assert post_html(conn, slug, post.slug) =~ "max-w-2xl"

      set!(slug, %{"post_width" => "wide"})
      assert post_html(conn, slug, post.slug) =~ "max-w-6xl"
    end
  end

  describe "post page: post_date_position" do
    test "date renders by default and disappears when hidden", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      assert post_html(conn, slug, post.slug) =~ "<time"

      set!(slug, %{"post_date_position" => "hidden"})
      refute post_html(conn, slug, post.slug) =~ "<time"
    end
  end

  describe "post page: scroll_progress_enabled" do
    test "off by default, progress bar markup when on", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      refute post_html(conn, slug, post.slug) =~ "pk-reading-progress"

      set!(slug, %{"scroll_progress_enabled" => "true"})
      assert post_html(conn, slug, post.slug) =~ "pk-reading-progress"
    end
  end

  describe "post page: scroll_headings_enabled" do
    test "off by default, config element with localized label when on", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      refute post_html(conn, slug, post.slug) =~ "pk-headings-config"

      set!(slug, %{"scroll_headings_enabled" => "true"})
      html = post_html(conn, slug, post.slug)
      assert html =~ "pk-headings-config"
      assert html =~ "data-label="
    end
  end

  describe "post page: show_breadcrumbs" do
    test "hidden by default, shown when enabled", %{conn: conn, group_slug: slug, post: post} do
      refute post_html(conn, slug, post.slug) =~ ~s(class="breadcrumbs)

      set!(slug, %{"show_breadcrumbs" => "true"})
      assert post_html(conn, slug, post.slug) =~ ~s(class="breadcrumbs)
    end
  end

  # ==========================================================================
  # Translated group name — every public surface resolves through
  # translated_group_name/2 (listing h1/title/OG, post breadcrumb + back link)
  # ==========================================================================

  describe "translated group name reach" do
    test "listing h1 and og:title use the resolved name", %{conn: conn, group_slug: slug} do
      set!(slug, %{"name_i18n" => %{"en" => "Overridden Name"}})

      html = listing_html(conn, slug)
      assert html =~ "Overridden Name"
      assert html =~ ~s(property="og:title" content="Overridden Name")
    end

    test "post page breadcrumb and back link use the resolved name", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      set!(slug, %{"name_i18n" => %{"en" => "Overridden Name"}, "show_breadcrumbs" => "true"})

      html = post_html(conn, slug, post.slug)
      # Breadcrumb label + the "Back to <group>" footer.
      assert html =~ "Overridden Name"
      refute html =~ ~r/Back to [^<]*#{Regex.escape(slug)}/
    end
  end
end
