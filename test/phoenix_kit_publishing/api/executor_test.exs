defmodule PhoenixKit.Modules.Publishing.API.ExecutorTest do
  @moduledoc """
  Publishing tools driven through core's real `PhoenixKit.API.Executor` with a real key: the scope
  check, the confirmation round trip, the approval queue, a batch threshold, idempotency. Everything
  else is tested at the handler (`ApiCase`). Grown by the tool tasks of the plan.
  """

  use PhoenixKit.DataCase, async: false

  # Runs only against a core that has the API (see test_helper.exs).
  @moduletag :core_api

  import Plug.Conn

  alias PhoenixKit.API.{Approvals, Auth, Executor, Keys}
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.API, as: PublishingAPI
  alias PhoenixKit.Modules.Publishing.API.{Common, Tools}
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  # Core's API is optional for this package: reached by name only.
  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Approvals,
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.Keys,
              PhoenixKit.API.Keys.Cache,
              PhoenixKit.Cache,
              PhoenixKit.Users.Auth.Scope,
              PhoenixKit.Users.Permissions,
              PhoenixKit.Users.Roles
            ]}

  @registry_key {PhoenixKit, :registered_modules}
  @every_scope ~w(publishing.posts:read publishing.posts:write publishing.posts:publish publishing.posts:delete
             publishing.categories:read publishing.categories:write publishing.categories:delete
             publishing.groups:read publishing.groups:write publishing.groups:delete publishing.translations:ai)

  # Core offers only the scopes that a declared tool carries; while the tool tasks are still growing
  # the set, the key asks for the intersection.
  defp scopes_declared, do: Tools.all() |> Enum.map(& &1.scope)

  defp scopes, do: Enum.filter(@every_scope, &(&1 in scopes_declared()))

  setup do
    # The cache registry is already running (test_helper.exs).
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    # Core signs confirmation codes with the application's secret; this package has no endpoint of its own.
    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("c", 64))

    previous = :persistent_term.get(@registry_key, :unset)
    :persistent_term.put(@registry_key, [Publishing])
    admin_enabled = Settings.get_boolean_setting("api_admin_enabled", false)
    publishing_enabled = Settings.get_boolean_setting("publishing_enabled", false)

    on_exit(fn ->
      case previous do
        :unset -> :persistent_term.erase(@registry_key)
        modules -> :persistent_term.put(@registry_key, modules)
      end

      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)

      Settings.update_boolean_setting("api_admin_enabled", admin_enabled)
      Settings.update_boolean_setting("publishing_enabled", publishing_enabled)
    end)

    # The module is enabled and registered BEFORE the key is created: core only offers scopes that
    # an enabled module's tool declares.
    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
    {:ok, _} = Publishing.enable_system()
    Fx.languages!()

    g = Fx.group!(name: "Executor Group")
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post, user: owner_with(["publishing"])}
  end

  defp owner_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "PubApi#{System.unique_integer([:positive])}"})
    for key <- ["api" | permissions], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "api-pub-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Api",
        "last_name" => "Test"
      })

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  # A key created by its owner with the owner's own scope, as the settings page does.
  defp issue_token(owner, scopes, extra \\ %{}) do
    scope = Scope.for_user(owner, narrow: false)

    {:ok, _key, token} =
      Keys.create_key(owner, scope, Map.merge(%{name: "pub api", scopes: scopes}, extra))

    token
  end

  # A request from an address no other test uses (the rate-limit counters are shared).
  defp authed(token) do
    n = System.unique_integer([:positive])
    peer = {10, rem(n, 250) + 1, rem(div(n, 250), 250) + 1, rem(div(n, 62_500), 250) + 1}

    :post
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(Auth.init(audience: :admin))
  end

  # Runs a tool through core's real `Executor.call/4`. Answers `{status, decoded_body, conn}`.
  defp call_with(token, name, input) do
    conn = Executor.call(authed(token), :admin, name, input)
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  defp title(ctx), do: Fx.content(ctx.post[:uuid]).title
  defp ref(ctx), do: %{"id" => ctx.post[:uuid]}

  test "a key without the write scope is refused with 403 and nothing is written", %{
    g: g,
    user: user
  } do
    token = issue_token(user, ["publishing.posts:read"])
    before = Fx.table_state()

    assert {403,
            %{
              "code" => "forbidden",
              "context" => %{"required_scope" => "publishing.posts:write"}
            }, _} =
             call_with(token, "publishing.create_post", %{"group" => g["slug"], "title" => "x"})

    assert Fx.table_state() == before
  end

  test "a key without the write scope is refused on update_post", ctx do
    token = issue_token(ctx.user, ["publishing.groups:read"])

    assert {403, %{"context" => %{"required_scope" => "publishing.posts:write"}}, _} =
             call_with(token, "publishing.update_post", %{"post" => ref(ctx), "title" => "x"})

    assert title(ctx) == "Hello"
  end

  test "update_post of a draft runs at once", ctx do
    token = issue_token(ctx.user, scopes())

    assert {200, %{"action" => "updated"}, _} =
             call_with(token, "publishing.update_post", %{
               "post" => ref(ctx),
               "title" => "Draft edit"
             })

    assert title(ctx) == "Draft edit"
  end

  describe "the live version" do
    setup ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

      %{
        token: issue_token(ctx.user, scopes()),
        input: %{"post" => ref(ctx), "version" => 1, "title" => "Live edit"}
      }
    end

    test "the first call previews and writes nothing; the code writes once; a spent code is refused",
         ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"live" => true, "public" => "active"}]
                }
              }, _} =
               call_with(ctx.token, "publishing.update_post", ctx.input)

      assert title(ctx) == "Hello"

      assert {200, %{"action" => "updated"}, _} =
               call_with(
                 ctx.token,
                 "publishing.update_post",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert title(ctx) == "Live edit"

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.update_post",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "the code is refused with reason changed after another write to the post", ctx do
      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.update_post", ctx.input)

      Fx.body!(ctx.g["slug"], ctx.post[:uuid], "someone else edited", 1)

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.update_post",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert title(ctx) == "Hello"
    end

    test "a code cannot be redeemed for different text", ctx do
      input = Map.put(ctx.input, "content", "<b>previewed text</b>")

      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.update_post", input)

      swapped =
        input
        |> Map.put("content", "<script>other text</script>")
        |> Map.put("confirm_token", code)

      assert {409, %{"code" => "confirm_token_invalid"}, _} =
               call_with(ctx.token, "publishing.update_post", swapped)

      assert Fx.content(ctx.post[:uuid]).content == "# Body"
    end
  end

  test "HTML in the body of a DRAFT needs a confirmation (the text rule) and the preview names it",
       ctx do
    token = issue_token(ctx.user, scopes())
    input = %{"post" => ref(ctx), "content" => "# Hi\n\n<span class=\"x\">y</span>"}

    assert {200,
            %{
              "executed" => false,
              "status" => "confirmation_required",
              "confirm_token" => code,
              "preview" => %{
                "rows" => [
                  %{
                    "changes" => %{
                      "content" => %{
                        "raw_html" => %{"dangerous" => true, "findings" => findings}
                      }
                    }
                  }
                ]
              }
            }, _} =
             call_with(token, "publishing.update_post", input)

    assert Enum.any?(findings, &(&1["kind"] == "html" and &1["line"] == 3))
    assert Fx.content(ctx.post[:uuid]).content == "# Body"

    assert {200, %{"action" => "updated"}, _} =
             call_with(token, "publishing.update_post", Map.put(input, "confirm_token", code))
  end

  test "a requires_approval key is queued; the approver's decision writes, with the approver in the log metadata",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    token = issue_token(ctx.user, scopes(), %{requires_approval: true})

    assert {200, %{"executed" => false, "status" => "pending_approval", "approval_id" => id}, _} =
             call_with(token, "publishing.update_post", %{
               "post" => ref(ctx),
               "version" => 1,
               "title" => "Approved edit"
             })

    assert title(ctx) == "Hello"

    assert {:ok, %{status: "executed"}} =
             Approvals.approve(id, Scope.for_user(ctx.user, narrow: false))

    assert title(ctx) == "Approved edit"

    row =
      Enum.find(
        list_activities(),
        &(&1.action == "publishing.post.updated" and &1.mode == "auto")
      )

    assert row.metadata["approved_by_uuid"] == ctx.user.uuid
  end

  test "create_post runs at once for plain markdown and replays with the same idempotency key", %{
    g: g,
    user: user
  } do
    token = issue_token(user, scopes())

    input = %{
      "group" => g["slug"],
      "title" => "Once",
      "content" => "plain",
      "slug" => "once",
      "idempotency_key" => "idem-pub-key-0001"
    }

    assert {200, %{"action" => "created"} = first, conn} =
             call_with(token, "publishing.create_post", input)

    refute get_resp_header(conn, "idempotent-replayed") == ["true"]
    assert {200, ^first, replay} = call_with(token, "publishing.create_post", input)
    assert get_resp_header(replay, "idempotent-replayed") == ["true"]

    assert Enum.count(
             DBStorage.list_posts(g["slug"]),
             &(&1.slug == "once")
           ) == 1
  end

  test "create_post with HTML needs a confirmation; the code writes once and not for other text",
       %{
         g: g,
         user: user
       } do
    token = issue_token(user, scopes())

    input = %{
      "group" => g["slug"],
      "title" => "Html",
      "content" => "<b>previewed</b>",
      "slug" => "html-post"
    }

    created = fn -> Enum.count(DBStorage.list_posts(g["slug"]), &(&1.slug == "html-post")) end

    assert {200,
            %{
              "executed" => false,
              "status" => "confirmation_required",
              "confirm_token" => code,
              "preview" => %{"requires_confirmation" => true}
            }, _} = call_with(token, "publishing.create_post", input)

    assert created.() == 0

    swapped =
      input
      |> Map.put("content", "<script>other</script>")
      |> Map.put("confirm_token", code)

    assert {409, %{"code" => "confirm_token_invalid"}, _} =
             call_with(token, "publishing.create_post", swapped)

    assert created.() == 0

    assert {200, %{"action" => "created"}, _} =
             call_with(token, "publishing.create_post", Map.put(input, "confirm_token", code))

    assert created.() == 1

    assert {409, %{"context" => %{"reason" => "used"}}, _} =
             call_with(token, "publishing.create_post", Map.put(input, "confirm_token", code))

    assert created.() == 1
  end

  test "a 51-item category_ids list is refused by the schema limit, 50 reaches the handler",
       ctx do
    token = issue_token(ctx.user, scopes())

    over = for _ <- 1..51, do: Ecto.UUID.generate()

    assert {422, %{"code" => "validation_failed", "context" => %{"errors" => errors}}, _} =
             call_with(token, "publishing.update_post", %{
               "post" => ref(ctx),
               "category_ids" => over
             })

    assert Enum.any?(errors, &(&1["path"] == "category_ids" and &1["limit"] == 50))

    # 50 passes the schema and is refused by the handler, not by the limit.
    exact = Enum.take(over, 50)

    assert {422, %{"code" => "validation_failed", "context" => %{"errors" => errors}}, _} =
             call_with(token, "publishing.update_post", %{
               "post" => ref(ctx),
               "category_ids" => exact
             })

    assert [%{"path" => "category_ids", "reason" => "unknown_category"}] = errors
  end

  describe "publish_post" do
    test "always answers confirmation_required first; the code publishes once", ctx do
      token = issue_token(ctx.user, scopes())
      input = %{"post" => ref(ctx)}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"goes_live" => %{"version" => 1}}]
                }
              }, _} = call_with(token, "publishing.publish_post", input)

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil

      assert {200, %{"action" => "published", "version" => 1}, _} =
               call_with(token, "publishing.publish_post", Map.put(input, "confirm_token", code))

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid ==
               Fx.version(ctx.post[:uuid]).uuid

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(token, "publishing.publish_post", Map.put(input, "confirm_token", code))
    end

    test "a retry with no version after a success answers unchanged, not no_draft_version", ctx do
      token = issue_token(ctx.user, scopes())
      input = %{"post" => ref(ctx)}

      assert {200, %{"confirm_token" => code}, _} =
               call_with(token, "publishing.publish_post", input)

      assert {200, %{"action" => "published"}, _} =
               call_with(token, "publishing.publish_post", Map.put(input, "confirm_token", code))

      assert {200,
              %{
                "status" => "confirmation_required",
                "confirm_token" => retry_code,
                "preview" => %{"rows" => [%{"action" => "unchanged"}]}
              }, _} = call_with(token, "publishing.publish_post", input)

      assert {200, %{"action" => "unchanged", "version" => 1}, _} =
               call_with(
                 token,
                 "publishing.publish_post",
                 Map.put(input, "confirm_token", retry_code)
               )
    end

    test "a posts:write-only key is refused with 403 and the publish scope", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.posts:publish"}
              }, _} = call_with(token, "publishing.publish_post", %{"post" => ref(ctx)})

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
    end

    test "the code is refused with reason changed after a content row of the version changed",
         ctx do
      token = issue_token(ctx.user, scopes())
      input = %{"post" => ref(ctx)}

      assert {200, %{"confirm_token" => code}, _} =
               call_with(token, "publishing.publish_post", input)

      Fx.body!(ctx.g["slug"], ctx.post[:uuid], "someone else edited", 1)

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(token, "publishing.publish_post", Map.put(input, "confirm_token", code))

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
    end
  end

  describe "unpublish_post" do
    setup ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
      %{token: issue_token(ctx.user, scopes()), input: %{"post" => ref(ctx)}}
    end

    test "always answers confirmation_required first; the code unpublishes once", ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "unpublish", "version" => 1}]
                }
              }, _} = call_with(ctx.token, "publishing.unpublish_post", ctx.input)

      live_uuid = Fx.version(ctx.post[:uuid]).uuid
      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == live_uuid

      assert {200, %{"action" => "unpublished", "version" => 1}, _} =
               call_with(
                 ctx.token,
                 "publishing.unpublish_post",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
      assert Fx.version(ctx.post[:uuid]).status == "draft"

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.unpublish_post",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "a posts:write-only key is refused with 403 and the publish scope", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.posts:publish"}
              }, _} = call_with(token, "publishing.unpublish_post", ctx.input)

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid != nil
    end

    test "the code is refused with reason changed after the live version changed", ctx do
      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.unpublish_post", ctx.input)

      Fx.body!(ctx.g["slug"], ctx.post[:uuid], "someone else edited", 1)

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.unpublish_post",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert Fx.db_post(ctx.post[:uuid]).active_version_uuid != nil
    end
  end

  describe "schedule_post" do
    setup ctx do
      g = Fx.group!(mode: "timestamp", name: "Executor Timestamp Group")
      post = Fx.post!(g["slug"], %{title: "Soon"})
      Fx.body!(g["slug"], post[:uuid], "# Body")

      publish_at =
        "#{Date.utc_today() |> Date.add(10)}T09:30"

      %{
        tg: g,
        tpost: post,
        token: issue_token(ctx.user, scopes()),
        input: %{"post" => %{"id" => post[:uuid]}, "publish_at" => publish_at}
      }
    end

    test "always answers confirmation_required first; the code schedules once", ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "schedule", "public_url_changes_with_date" => true}]
                }
              }, _} = call_with(ctx.token, "publishing.schedule_post", ctx.input)

      assert Fx.db_post(ctx.tpost[:uuid]).active_version_uuid == nil

      assert {200, %{"action" => "scheduled", "post" => %{"status" => "scheduled"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.schedule_post",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert Fx.db_post(ctx.tpost[:uuid]).active_version_uuid != nil

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.schedule_post",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "a posts:write-only key is refused with 403 and the publish scope", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.posts:publish"}
              }, _} = call_with(token, "publishing.schedule_post", ctx.input)

      assert Fx.db_post(ctx.tpost[:uuid]).active_version_uuid == nil
    end
  end

  describe "trash_posts" do
    setup ctx do
      %{token: issue_token(ctx.user, scopes()), input: %{"posts" => [ref(ctx)]}}
    end

    test "always answers confirmation_required, even for one draft post; the code trashes once",
         ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "removed"}]
                }
              }, _} = call_with(ctx.token, "publishing.trash_posts", ctx.input)

      assert Fx.db_post(ctx.post[:uuid]).trashed_at == nil

      assert {200, %{"summary" => %{"removed" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.trash_posts",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert Fx.db_post(ctx.post[:uuid]).trashed_at != nil

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.trash_posts",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "a posts:write-only key is refused with 403 and the delete scope", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.posts:delete"}
              }, _} = call_with(token, "publishing.trash_posts", ctx.input)

      assert Fx.db_post(ctx.post[:uuid]).trashed_at == nil
    end
  end

  describe "restore_posts" do
    setup ctx do
      {:ok, _} = Publishing.Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])
      %{token: issue_token(ctx.user, scopes()), input: %{"posts" => [ref(ctx)]}}
    end

    test "a trashed draft restores at once, without a confirmation", ctx do
      assert {200, %{"summary" => %{"restored" => 1}}, _} =
               call_with(ctx.token, "publishing.restore_posts", ctx.input)

      assert Fx.db_post(ctx.post[:uuid]).trashed_at == nil
    end

    test "a trashed live post asks for a confirmation first; the code restores it", ctx do
      live = Fx.post!(ctx.g["slug"], %{title: "Live", slug: "live"})
      Fx.body!(ctx.g["slug"], live[:uuid], "# Live")
      Fx.publish!(ctx.g["slug"], live[:uuid])
      {:ok, _} = Publishing.Posts.trash_post(ctx.g["slug"], live[:uuid])
      input = %{"posts" => [%{"id" => live[:uuid]}]}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "restored", "becomes_visible" => true}]
                }
              }, _} = call_with(ctx.token, "publishing.restore_posts", input)

      assert Fx.db_post(live[:uuid]).trashed_at != nil

      assert {200, %{"summary" => %{"restored" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.restore_posts",
                 Map.put(input, "confirm_token", code)
               )

      assert Fx.db_post(live[:uuid]).trashed_at == nil

      # The post is out of the trash now, so the call is no longer dangerous: repeating it with
      # the spent code is a harmless no-op.
      assert {200, %{"summary" => %{"unchanged" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.restore_posts",
                 Map.put(input, "confirm_token", code)
               )
    end

    test "a posts:write-only key is refused with 403 and the delete scope", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.posts:delete"}
              }, _} = call_with(token, "publishing.restore_posts", ctx.input)

      assert Fx.db_post(ctx.post[:uuid]).trashed_at != nil
    end
  end

  describe "upsert_categories" do
    setup ctx do
      %{token: issue_token(ctx.user, scopes())}
    end

    defp rows(count), do: for(i <- 1..count, do: %{"slug" => "c#{i}", "name" => "C#{i}"})

    defp category_slugs(ctx),
      do: Common.categories!(ctx.g["slug"]) |> Enum.map(& &1.slug)

    test "creating categories runs at once", ctx do
      input = %{"group" => ctx.g["slug"], "categories" => rows(2)}

      assert {200, %{"summary" => %{"created" => 2}}, _} =
               call_with(ctx.token, "publishing.upsert_categories", input)

      assert Enum.sort(category_slugs(ctx)) == ["c1", "c2"]
    end

    test "updating an existing category answers confirmation_required and the code applies it",
         ctx do
      old = Fx.category!(ctx.g["slug"], "Old", %{slug: "old"})
      input = %{"group" => ctx.g["slug"], "categories" => [%{"slug" => "old", "name" => "New"}]}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "updated"}]
                }
              }, _} = call_with(ctx.token, "publishing.upsert_categories", input)

      assert {:ok, %{name: "Old"}} = Publishing.Categories.fetch_category(old.uuid)

      assert {200, %{"summary" => %{"updated" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.upsert_categories",
                 Map.put(input, "confirm_token", code)
               )

      assert {:ok, %{name: "New"}} = Publishing.Categories.fetch_category(old.uuid)
    end

    test "51 creates are held by core's batch rule and the code writes them", ctx do
      input = %{"group" => ctx.g["slug"], "categories" => rows(51)}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code
              }, _} =
               call_with(ctx.token, "publishing.upsert_categories", input)

      assert category_slugs(ctx) == []

      assert {200, %{"summary" => %{"created" => 51}}, _} =
               call_with(
                 ctx.token,
                 "publishing.upsert_categories",
                 Map.put(input, "confirm_token", code)
               )

      assert length(category_slugs(ctx)) == 51
    end

    test "100 rows are accepted and 101 are refused by max_items", ctx do
      assert {200, %{"status" => "confirmation_required"}, _} =
               call_with(ctx.token, "publishing.upsert_categories", %{
                 "group" => ctx.g["slug"],
                 "categories" => rows(100)
               })

      assert {422, _, _} =
               call_with(ctx.token, "publishing.upsert_categories", %{
                 "group" => ctx.g["slug"],
                 "categories" => rows(101)
               })

      assert category_slugs(ctx) == []
    end

    test "a key without the categories write scope is refused with 403", ctx do
      token = issue_token(ctx.user, ["publishing.posts:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.categories:write"}
              }, _} =
               call_with(token, "publishing.upsert_categories", %{
                 "group" => ctx.g["slug"],
                 "categories" => rows(1)
               })

      assert category_slugs(ctx) == []
    end
  end

  describe "upsert_groups" do
    setup ctx do
      %{token: issue_token(ctx.user, scopes())}
    end

    defp group_rows(count),
      do: for(i <- 1..count, do: %{"slug" => "grp#{i}", "name" => "G#{i}", "mode" => "slug"})

    test "creating a group runs at once", ctx do
      input = %{"groups" => [%{"slug" => "fresh", "name" => "Fresh", "mode" => "slug"}]}

      assert {200, %{"summary" => %{"created" => 1}, "results" => [%{"id" => id}]}, _} =
               call_with(ctx.token, "publishing.upsert_groups", input)

      assert {:ok, %{"uuid" => ^id, "mode" => "slug"}} = Publishing.Groups.fetch_group("fresh")
    end

    test "changing an existing group answers confirmation_required and the code applies it",
         ctx do
      input = %{"groups" => [%{"slug" => ctx.g["slug"], "name" => "Renamed"}]}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "updated"}]
                }
              }, _} = call_with(ctx.token, "publishing.upsert_groups", input)

      assert {:ok, %{"name" => "Executor Group"}} = Publishing.Groups.fetch_group(ctx.g["slug"])

      assert {200, %{"summary" => %{"updated" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.upsert_groups",
                 Map.put(input, "confirm_token", code)
               )

      assert {:ok, %{"name" => "Renamed"}} = Publishing.Groups.fetch_group(ctx.g["slug"])
    end

    test "a code cannot be redeemed after the group changed in between", ctx do
      input = %{"groups" => [%{"slug" => ctx.g["slug"], "name" => "Renamed"}]}

      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.upsert_groups", input)

      {:ok, _} = Publishing.Groups.update_group(ctx.g["slug"], %{"show_breadcrumbs" => true})

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.upsert_groups",
                 Map.put(input, "confirm_token", code)
               )

      assert {:ok, %{"name" => "Executor Group"}} = Publishing.Groups.fetch_group(ctx.g["slug"])
    end

    test "20 rows are accepted and 21 are refused by max_items", ctx do
      assert {200, %{"summary" => %{"created" => 20}}, _} =
               call_with(ctx.token, "publishing.upsert_groups", %{"groups" => group_rows(20)})

      assert {422, _, _} =
               call_with(ctx.token, "publishing.upsert_groups", %{
                 "groups" =>
                   group_rows(21) |> Enum.map(&Map.update!(&1, "slug", fn s -> s <> "x" end))
               })

      assert {:error, :not_found} = Publishing.Groups.fetch_group("grp1x")
    end

    test "a key without the groups write scope is refused with 403", ctx do
      token = issue_token(ctx.user, ["publishing.groups:read"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.groups:write"}
              }, _} = call_with(token, "publishing.upsert_groups", %{"groups" => group_rows(1)})

      assert {:error, :not_found} = Publishing.Groups.fetch_group("grp1")
    end
  end

  describe "trash_groups and restore_groups" do
    setup ctx do
      %{
        token: issue_token(ctx.user, scopes()),
        input: %{"groups" => [%{"slug" => ctx.g["slug"]}]}
      }
    end

    defp group_status(ctx) do
      {:ok, %{"status" => status}} = Publishing.Groups.fetch_group(ctx.g["slug"])
      status
    end

    test "trash_groups always answers confirmation_required, even for an empty group; the code trashes once",
         ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "removed"}]
                }
              }, _} = call_with(ctx.token, "publishing.trash_groups", ctx.input)

      assert group_status(ctx) == "active"

      assert {200, %{"summary" => %{"removed" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.trash_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert group_status(ctx) == "trashed"

      assert {409, _, _} =
               call_with(
                 ctx.token,
                 "publishing.trash_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "restore_groups always answers confirmation_required; the code restores once", ctx do
      {:ok, _} = Publishing.Groups.trash_group(ctx.g["slug"])

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code
              }, _} = call_with(ctx.token, "publishing.restore_groups", ctx.input)

      assert group_status(ctx) == "trashed"

      assert {200, %{"summary" => %{"restored" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.restore_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert group_status(ctx) == "active"

      assert {409, _, _} =
               call_with(
                 ctx.token,
                 "publishing.restore_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "a groups:write-only key is refused with 403 and the delete scope", ctx do
      token = issue_token(ctx.user, ["publishing.groups:write"])

      for tool <- ["publishing.trash_groups", "publishing.restore_groups"] do
        assert {403,
                %{
                  "code" => "forbidden",
                  "context" => %{"required_scope" => "publishing.groups:delete"}
                }, _} = call_with(token, tool, ctx.input)
      end

      assert group_status(ctx) == "active"
    end

    test "a trash code is refused with reason changed when the group changed in between", ctx do
      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.trash_groups", ctx.input)

      {:ok, _} = Publishing.Groups.update_group(ctx.g["slug"], %{"show_breadcrumbs" => true})

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.trash_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert group_status(ctx) == "active"
    end

    test "a restore code is refused with reason changed when the group changed in between", ctx do
      {:ok, _} = Publishing.Groups.trash_group(ctx.g["slug"])

      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.restore_groups", ctx.input)

      {:ok, _} = Publishing.Groups.update_group(ctx.g["slug"], %{"show_breadcrumbs" => true})

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.restore_groups",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert group_status(ctx) == "trashed"
    end
  end

  describe "delete_categories" do
    setup ctx do
      cat = Fx.category!(ctx.g["slug"], "Doomed", %{slug: "doomed"})

      %{
        token: issue_token(ctx.user, scopes()),
        cat: cat,
        input: %{"group" => ctx.g["slug"], "refs" => [%{"id" => cat.uuid}]}
      }
    end

    defp file_under(ctx, category) do
      {:ok, p} = Publishing.Posts.read_post_by_uuid(ctx.post[:uuid])

      {:ok, _} =
        Publishing.Posts.update_post(
          ctx.g["slug"],
          p,
          %{"category_uuids" => [category.uuid]},
          publish: false
        )
    end

    test "always answers confirmation_required, even for an empty category; the code deletes once",
         ctx do
      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "removed", "irreversible" => true}]
                }
              }, _} = call_with(ctx.token, "publishing.delete_categories", ctx.input)

      assert {:ok, _} = Publishing.Categories.fetch_category(ctx.cat.uuid)

      assert {200, %{"summary" => %{"removed" => 1}}, _} =
               call_with(
                 ctx.token,
                 "publishing.delete_categories",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert {:error, :not_found} = Publishing.Categories.fetch_category(ctx.cat.uuid)

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.delete_categories",
                 Map.put(ctx.input, "confirm_token", code)
               )
    end

    test "a categories:write-only key is refused with 403 and the delete scope", ctx do
      token = issue_token(ctx.user, ["publishing.categories:write"])

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "publishing.categories:delete"}
              }, _} = call_with(token, "publishing.delete_categories", ctx.input)

      assert {:ok, _} = Publishing.Categories.fetch_category(ctx.cat.uuid)
    end

    test "the code is refused with reason changed when a post is filed under the category in between",
         ctx do
      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.delete_categories", ctx.input)

      file_under(ctx, ctx.cat)

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.delete_categories",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert {:ok, _} = Publishing.Categories.fetch_category(ctx.cat.uuid)
    end
  end

  describe "set_translation" do
    setup ctx do
      %{
        token: issue_token(ctx.user, scopes()),
        input: %{
          "post" => ref(ctx),
          "version" => 1,
          "language" => "de-DE",
          "title" => "Hallo",
          "content" => "Inhalt"
        }
      }
    end

    defp german(ctx), do: Fx.content(ctx.post[:uuid], "de-DE")

    test "a draft version runs at once, without a confirmation", ctx do
      assert {200, %{"action" => "created", "language" => "de-DE"}, _} =
               call_with(ctx.token, "publishing.set_translation", ctx.input)

      assert %{title: "Hallo", content: "Inhalt"} = german(ctx)
    end

    test "the live version: the first call previews and writes no row; the code writes once; a spent code is refused",
         ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "rows" => [%{"action" => "add", "live" => true}]
                }
              }, _} = call_with(ctx.token, "publishing.set_translation", ctx.input)

      assert german(ctx) == nil
      confirmed = Map.put(ctx.input, "confirm_token", code)

      assert {200, %{"action" => "created"}, _} =
               call_with(ctx.token, "publishing.set_translation", confirmed)

      assert %{title: "Hallo"} = german(ctx)

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(ctx.token, "publishing.set_translation", confirmed)
    end

    test "a code cannot be redeemed for different text", ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.set_translation", ctx.input)

      swapped = ctx.input |> Map.put("content", "Anderer Text") |> Map.put("confirm_token", code)

      assert {409, %{"code" => "confirm_token_invalid"}, _} =
               call_with(ctx.token, "publishing.set_translation", swapped)

      assert german(ctx) == nil
    end

    test "the code is refused with reason changed after another write to the post", ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

      assert {200, %{"confirm_token" => code}, _} =
               call_with(ctx.token, "publishing.set_translation", ctx.input)

      Fx.body!(ctx.g["slug"], ctx.post[:uuid], "someone else edited", 1)

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 ctx.token,
                 "publishing.set_translation",
                 Map.put(ctx.input, "confirm_token", code)
               )

      assert german(ctx) == nil
    end

    test "an unconfirmed draft write whose version goes live in the window is refused as went_live",
         ctx do
      flag = make_ref()
      me = self()
      handler = "executor-set-translation-#{System.unique_integer([:positive])}"
      repo = PhoenixKitPublishing.Test.Repo

      :telemetry.attach(
        handler,
        repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "phoenix_kit_publishing_contents" and meta.query =~ ~r/^INSERT/ and
               Process.get(flag) == nil do
            Process.put(flag, true)
            :ok = Publishing.Versions.publish_version(ctx.g["slug"], ctx.post[:uuid], 1, [])
            send(me, :interleaved)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {409, %{"context" => %{"reason" => "went_live"}}, _} =
               call_with(ctx.token, "publishing.set_translation", ctx.input)

      assert_received :interleaved
      assert %{content: content} = german(ctx)
      assert content in [nil, ""]
    end

    test "a requires_approval key is queued; the approver's decision writes, with the approver in the log metadata",
         ctx do
      Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
      token = issue_token(ctx.user, scopes(), %{requires_approval: true})

      assert {200, %{"executed" => false, "status" => "pending_approval", "approval_id" => id}, _} =
               call_with(token, "publishing.set_translation", ctx.input)

      assert german(ctx) == nil

      assert {:ok, %{status: "executed"}} =
               Approvals.approve(id, Scope.for_user(ctx.user, narrow: false))

      assert %{title: "Hallo"} = german(ctx)

      row =
        Enum.find(
          list_activities(),
          &(&1.action == "publishing.post.updated" and &1.mode == "auto")
        )

      assert row.metadata["approved_by_uuid"] == ctx.user.uuid
    end
  end

  test "every scope the declared tools carry is a known publishing scope, and the key gets all of them" do
    declared = scopes_declared() |> Enum.uniq() |> Enum.sort()

    assert declared -- @every_scope == []
    assert Enum.sort(scopes()) == declared

    assert MapSet.subset?(
             MapSet.new(~w(
               publishing.groups:read publishing.posts:read publishing.categories:read
               publishing.posts:write publishing.posts:publish publishing.posts:delete
             )),
             MapSet.new(scopes())
           )
  end

  test "a core without the confirmation flow exposes only the reads and create_version" do
    six =
      ~w(publishing.create_version publishing.get_group_settings_schema publishing.get_post publishing.list_categories publishing.list_groups publishing.list_posts)

    declared = Tools.all() |> Enum.map(& &1.name)
    names = PublishingAPI.tools(false) |> Enum.map(& &1.name) |> Enum.sort()
    expected = six |> Enum.filter(&(&1 in declared)) |> Enum.sort()

    assert expected != []
    assert names == expected
  end
end
