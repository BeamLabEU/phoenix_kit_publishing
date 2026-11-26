defmodule PhoenixKit.Modules.Publishing.PostAccess do
  @moduledoc """
  Per-post access control: who may open a post.

  A post with no access rule is public — exactly as every post was before
  this module existed, on every surface. Rules (`PublishingAccessRule`, module
  chain V4) restrict it:

    * `signed_in` — any signed-in reader
    * `role` — a reader holding one of the chosen core roles
    * `user` — one of the chosen users
    * `password` — anyone who typed the post's password (a grant in an
      encrypted cookie, `PostAccess.Grants`)
    * `token` — a secret link (`?access_token=…`, redeemed into the same cookie)

  By default any one satisfied rule opens the post (`match: "any"`); a post
  set to `"all"` needs one satisfied rule of every kind it has. Holders of the
  `publishing` permission (editors, Admin, Owner) always pass: they can open
  the post in the editor anyway.

  Two entry points, used by every public surface:

    * `authorize_view/2` — the one decision for a single post:
      `:ok | {:redeem, rule} | {:error, :not_found | :login | :password | :forbidden}`
    * `visible_query/1` — the one query filter for listings that read the
      database (`where` no gating rule exists); listings read from the
      listing cache filter on the `:access_protected` flag the cache
      carries (`public?/1`, `visible_entries/2`).

  A group can hold a default rule set: new posts copy it at creation
  (`copy_group_defaults/3`), and `apply_group_defaults/2` pushes it onto
  existing posts on request.
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.PublishingAccessRule, as: Rule
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.SitemapRefresh

  @gate_kinds Rule.gate_kinds()
  @login_kinds ~w(signed_in role user)
  @key_bytes 32

  @type denial :: :not_found | :login | :password | :forbidden
  @type decision :: :ok | {:redeem, Rule.t()} | {:error, denial()}
  @type owner :: {:post, String.t()} | {:group, String.t()}

  @typedoc """
  A post's access as the resolver reads it: its gating rules and the match
  mode. `nil` means public.
  """
  @type access :: %{rules: [Rule.t()], match: String.t()} | nil

  # ===========================================================================
  # Reading
  # ===========================================================================

  @probe_absent_ms 30_000

  @doc """
  True when the access-rules table exists (module chain V4 has run). Code
  deployed before the migration finds no table: every read here then answers
  "no rules", so every post is public on every surface, exactly as before the
  feature, instead of a 500. A found table is remembered for the life of the
  node; a missing one is asked again after #{div(@probe_absent_ms, 1000)} s, so the
  rules take effect soon after the migration runs. Kept in `:persistent_term`
  per repo. A database that cannot answer the probe counts as "present": the
  real query then fails as it would have.
  """
  @spec rules_table?() :: boolean()
  def rules_table? do
    key = probe_key()

    case :persistent_term.get(key, nil) do
      true ->
        true

      {false, until} ->
        if System.monotonic_time(:millisecond) < until, do: false, else: probe(key)

      nil ->
        probe(key)
    end
  end

  @doc false
  # Forgets the probe's answer (tests, and a host that just migrated).
  @spec reset_rules_table_probe() :: :ok
  def reset_rules_table_probe do
    :persistent_term.erase(probe_key())
    :ok
  end

  defp probe_key, do: {__MODULE__, :rules_table, repo()}

  defp probe(key) do
    name =
      case Rule.__schema__(:prefix) do
        nil -> Rule.__schema__(:source)
        prefix -> "#{prefix}.#{Rule.__schema__(:source)}"
      end

    case repo().query("SELECT to_regclass($1) IS NOT NULL", [name]) do
      {:ok, %{rows: [[true]]}} ->
        :persistent_term.put(key, true)
        true

      {:ok, %{rows: [[false]]}} ->
        Logger.warning(
          "[PostAccess] no access-rules table (module chain V4 not run): every post is public"
        )

        :persistent_term.put(key, {false, System.monotonic_time(:millisecond) + @probe_absent_ms})
        false

      _error ->
        true
    end
  rescue
    _ -> true
  end

  @doc "Every rule of a post (gates and the settings row), oldest first."
  @spec list_rules(owner()) :: [Rule.t()]
  def list_rules(owner) do
    if rules_table?(), do: read_rules(owner), else: []
  end

  defp read_rules({:post, post_uuid}) do
    with_uuid(post_uuid, [], fn uuid ->
      repo().all(from(r in Rule, where: r.post_uuid == ^uuid, order_by: [asc: r.inserted_at]))
    end)
  end

  defp read_rules({:group, group_uuid}) do
    with_uuid(group_uuid, [], fn uuid ->
      repo().all(from(r in Rule, where: r.group_uuid == ^uuid, order_by: [asc: r.inserted_at]))
    end)
  end

  @doc """
  A post's access (`t:access/0`), or `nil` when it has no gating rule.
  One indexed query; a site without rules pays only that.
  """
  @spec access_for_post(String.t() | nil) :: access()
  def access_for_post(post_uuid) when is_binary(post_uuid) do
    post_uuid |> then(&list_rules({:post, &1})) |> to_access()
  end

  def access_for_post(_), do: nil

  @doc false
  @spec to_access([Rule.t()]) :: access()
  def to_access(rules) do
    case Enum.filter(rules, &(&1.kind in @gate_kinds)) do
      [] -> nil
      gates -> %{rules: gates, match: match_of(rules)}
    end
  end

  @doc ~S|The match mode ("any" / "all") a rule list carries.|
  @spec match_of([Rule.t()]) :: String.t()
  def match_of(rules) do
    case Enum.find(rules, &(&1.kind == "settings")) do
      %Rule{config: %{"match" => "all"}} -> "all"
      _ -> "any"
    end
  end

  @doc """
  True when the group lists its protected posts to the readers who may open
  them (the group's settings row, `list_protected`). Off by default:
  protected posts are reachable by their URL only.
  """
  @spec list_protected?([Rule.t()]) :: boolean()
  def list_protected?(group_rules) do
    match?(
      %Rule{config: %{"list_protected" => true}},
      Enum.find(group_rules, &(&1.kind == "settings"))
    )
  end

  @doc "True when the post has at least one gating rule."
  @spec protected?(String.t() | nil) :: boolean()
  def protected?(post_uuid), do: access_for_post(post_uuid) != nil

  @doc """
  Which of these posts are protected (any gating rule), as a map
  `%{uuid => true}` — one query for a whole listing.
  """
  @spec protected_post_uuids([String.t()]) :: %{optional(String.t()) => true}
  def protected_post_uuids([]), do: %{}

  def protected_post_uuids(post_uuids) when is_list(post_uuids) do
    if rules_table?(), do: read_protected(post_uuids), else: %{}
  end

  defp read_protected(post_uuids) do
    from(r in Rule,
      where: r.post_uuid in ^post_uuids and r.kind in ^@gate_kinds,
      distinct: true,
      select: r.post_uuid
    )
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  @doc """
  The one query filter for post listings that read the database: keeps only
  posts no gating rule restricts. `query` must have the posts table as its
  first binding.
  """
  @spec visible_query(Ecto.Queryable.t()) :: Ecto.Query.t()
  def visible_query(query) do
    if rules_table?(), do: filter_visible(query), else: Ecto.Queryable.to_query(query)
  end

  defp filter_visible(query) do
    protected =
      from(r in Rule,
        where: not is_nil(r.post_uuid) and r.kind in ^@gate_kinds,
        select: r.post_uuid
      )

    from(p in query, where: p.uuid not in subquery(protected))
  end

  @doc """
  True for a listing-cache entry that no rule protects. The cache marks a
  protected post with `access_protected: true`; anything else is public.
  """
  @spec public?(map()) :: boolean()
  def public?(entry), do: Map.get(entry, :access_protected) != true

  @doc """
  Listing-cache entries a viewer may see LISTED: the public ones, plus — when
  the group lists protected posts (`list_protected?/1`) — the protected ones
  this viewer may open. Anonymous viewers without grants never cost a query.
  """
  @spec visible_entries([map()], Viewer.t() | nil, String.t() | nil) :: [map()]
  def visible_entries(entries, viewer, group_uuid) do
    {public, protected} = Enum.split_with(entries, &public?/1)

    cond do
      protected == [] -> entries
      not Viewer.may_hold_access?(viewer) -> public
      not list_protected?(list_rules({:group, group_uuid})) -> public
      true -> keep_openable(entries, Map.new(openable(protected, viewer), &{&1, true}))
    end
  end

  @doc """
  Listing-cache entries this viewer may OPEN: the public ones plus the
  protected ones `authorize_view/2` lets them into, whether or not the group
  lists protected posts. For decisions that must not count a post the reader
  cannot open (is this URL segment a language with content?), never for
  what a listing shows (`visible_entries/3`).
  """
  @spec openable_entries([map()], Viewer.t() | nil) :: [map()]
  def openable_entries(entries, viewer) do
    {_public, protected} = Enum.split_with(entries, &public?/1)

    cond do
      protected == [] -> entries
      not Viewer.may_hold_access?(viewer) -> Enum.filter(entries, &public?/1)
      true -> keep_openable(entries, Map.new(openable(protected, viewer), &{&1, true}))
    end
  end

  defp openable(protected, viewer) do
    protected_uuids = Enum.map(protected, & &1[:uuid])

    rules_by_post =
      from(r in Rule, where: r.post_uuid in ^protected_uuids)
      |> repo().all()
      |> Enum.group_by(& &1.post_uuid)

    for uuid <- protected_uuids,
        authorize_view(to_access(Map.get(rules_by_post, uuid, [])), viewer) == :ok,
        do: uuid
  end

  defp keep_openable(entries, openable) do
    Enum.filter(entries, &(public?(&1) or Map.has_key?(openable, &1[:uuid])))
  end

  # ===========================================================================
  # The decision
  # ===========================================================================

  @doc """
  Decides whether `viewer` may open a post with this access.

    * `:ok` — show it (public posts always).
    * `{:redeem, rule}` — the request carried a valid secret link for this
      post: grant it and redirect to the clean URL.
    * `{:error, :password}` — show the password form.
    * `{:error, :login}` — an anonymous reader a sign-in could admit.
    * `{:error, :forbidden}` — a signed-in reader without the right.
    * `{:error, :not_found}` — nothing the reader could do (a secret-link
      post, or every rule expired): answer as for a missing post.
  """
  @spec authorize_view(access() | map(), Viewer.t() | nil) :: decision()
  def authorize_view(nil, _viewer), do: :ok

  def authorize_view(%{rules: []}, _viewer), do: :ok

  def authorize_view(%{rules: rules, match: match}, viewer) do
    viewer = viewer || Viewer.anonymous()
    now = DateTime.utc_now()
    active = Enum.filter(rules, &active?(&1, now))

    cond do
      viewer.bypass? -> :ok
      match == "all" and dead_kind?(rules, active) -> {:error, :not_found}
      satisfied?(active, match, viewer, now) -> :ok
      redeemable = redeemable_token(active, viewer) -> {:redeem, redeemable}
      true -> {:error, denial(active, match, viewer, now)}
    end
  end

  # With `match: "all"` every kind the post has is a requirement. A kind
  # whose rules have all expired (or, for links, been revoked) can no longer
  # be met, so nobody gets in: dropping the requirement instead would let an
  # expiry WIDEN access ("role AND password until June" becoming "role" in
  # July), where with "any" it only ever narrows it.
  defp dead_kind?(rules, active) do
    live = MapSet.new(active, & &1.kind)
    Enum.any?(rules, &(not MapSet.member?(live, &1.kind)))
  end

  @doc """
  `authorize_view/2` with a scope and a grants map instead of a viewer, for
  callers outside a request (a background job, a host's own page).
  """
  @spec authorize_view(access(), term(), map()) :: decision()
  def authorize_view(access, scope, grants) do
    authorize_view(access, Viewer.new(scope, grants))
  end

  defp satisfied?(active, "all", viewer, now) do
    by_kind = Enum.group_by(active, & &1.kind)

    by_kind != %{} and
      Enum.all?(by_kind, fn {_kind, rules} -> Enum.any?(rules, &grants?(&1, viewer, now)) end)
  end

  defp satisfied?(active, _any, viewer, now), do: Enum.any?(active, &grants?(&1, viewer, now))

  defp denial(active, match, viewer, now) do
    unsatisfied =
      case match do
        "all" ->
          active
          |> Enum.group_by(& &1.kind)
          |> Enum.reject(fn {_k, rules} -> Enum.any?(rules, &grants?(&1, viewer, now)) end)
          |> Enum.flat_map(fn {_k, rules} -> rules end)

        _ ->
          active
      end

    kinds = unsatisfied |> Enum.map(& &1.kind) |> Enum.uniq()

    cond do
      "password" in kinds -> :password
      Enum.any?(@login_kinds, &(&1 in kinds)) and viewer.anonymous? -> :login
      Enum.any?(@login_kinds, &(&1 in kinds)) -> :forbidden
      true -> :not_found
    end
  end

  @doc false
  @spec active?(Rule.t(), DateTime.t()) :: boolean()
  def active?(%Rule{} = rule, now) do
    not_expired = is_nil(rule.expires_at) or DateTime.compare(rule.expires_at, now) == :gt
    not_revoked = rule.kind != "token" or is_nil(rule.revoked_at)
    not_expired and not_revoked
  end

  defp grants?(%Rule{kind: "signed_in"}, viewer, _now), do: not viewer.anonymous?

  defp grants?(%Rule{kind: "user", config: config}, viewer, _now) do
    is_binary(viewer.user_uuid) and viewer.user_uuid in List.wrap(config["user_uuids"])
  end

  defp grants?(%Rule{kind: "role", config: config}, viewer, _now) do
    not viewer.anonymous? and
      config
      |> Map.get("role_uuids", [])
      |> List.wrap()
      |> role_names()
      |> Enum.any?(&(&1 in viewer.role_names))
  end

  defp grants?(%Rule{kind: kind} = rule, viewer, now) when kind in ["password", "token"] do
    case Map.get(viewer.grants, rule.uuid) do
      %{"r" => rev, "e" => exp} when is_integer(exp) ->
        rev == revision(rule) and exp > DateTime.to_unix(now)

      _ ->
        false
    end
  end

  defp grants?(_rule, _viewer, _now), do: false

  @doc "The revision a grant for this rule must carry (password rotation bumps it)."
  @spec revision(Rule.t()) :: integer()
  def revision(%Rule{config: %{"rev" => rev}}) when is_integer(rev), do: rev
  def revision(_rule), do: 1

  defp redeemable_token(_active, %Viewer{key: nil}), do: nil

  defp redeemable_token(active, %Viewer{key: key}) do
    digest = digest(key)

    Enum.find(active, fn
      %Rule{kind: "token", config: %{"digest" => stored}} when is_binary(stored) ->
        Plug.Crypto.secure_compare(stored, digest)

      _ ->
        false
    end)
  end

  # Role rules store core role uuids; the scope holds role NAMES. One query,
  # only when a signed-in reader meets a role rule.
  defp role_names([]), do: []

  defp role_names(uuids) do
    uuids = Enum.filter(uuids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    if uuids == [] do
      []
    else
      repo().all(from(r in PhoenixKit.Users.Role, where: r.uuid in ^uuids, select: r.name))
    end
  rescue
    error ->
      Logger.warning("[PostAccess] role lookup failed: #{inspect(error.__struct__)}")
      []
  end

  @doc "SHA-256 (hex) of a secret-link key — the only form a key is stored in."
  @spec digest(String.t()) :: String.t()
  def digest(key) when is_binary(key),
    do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

  @doc "Checks a typed password against a post's active password rules."
  @spec check_password(access(), String.t()) :: {:ok, Rule.t()} | :error
  def check_password(nil, _password), do: :error

  def check_password(%{rules: rules}, password) when is_binary(password) do
    now = DateTime.utc_now()

    candidates =
      Enum.filter(
        rules,
        &(&1.kind == "password" and active?(&1, now) and is_binary(&1.config["hash"]))
      )

    case Enum.find(candidates, &Bcrypt.verify_pass(password, &1.config["hash"])) do
      nil ->
        # Same cost whether or not the post has a password at all.
        if candidates == [], do: Bcrypt.no_user_verify()
        :error

      rule ->
        {:ok, rule}
    end
  end

  def check_password(_access, _password), do: :error

  # ===========================================================================
  # Writing
  # ===========================================================================

  @doc """
  Adds a `signed_in`, `role` or `user` rule.

  `attrs`: `"kind"`, `"role_uuids"` / `"user_uuids"` (lists), `"note"`,
  `"expires_at"` (a `DateTime`, an ISO-8601 string or empty). Opts:
  `:actor_uuid`.
  """
  @spec add_rule(owner(), map(), keyword()) :: {:ok, Rule.t()} | {:error, term()}
  def add_rule(owner, attrs, opts \\ []) do
    kind = attr(attrs, "kind")

    case rule_config(kind, attrs) do
      :invalid -> {:error, :invalid_kind}
      %{"role_uuids" => []} -> {:error, :empty_rule}
      %{"user_uuids" => []} -> {:error, :empty_rule}
      config -> insert_rule(owner, kind, config, attrs, opts)
    end
  end

  defp rule_config("role", attrs), do: %{"role_uuids" => uuid_list(attr(attrs, "role_uuids"))}
  defp rule_config("user", attrs), do: %{"user_uuids" => uuid_list(attr(attrs, "user_uuids"))}
  defp rule_config("signed_in", _attrs), do: %{}
  defp rule_config(_kind, _attrs), do: :invalid

  @attr_atoms %{
    "kind" => :kind,
    "role_uuids" => :role_uuids,
    "user_uuids" => :user_uuids,
    "note" => :note,
    "expires_at" => :expires_at,
    "no_end_date" => :no_end_date
  }

  # Form params arrive with string keys, code passes atoms; both are read.
  defp attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Map.fetch!(@attr_atoms, key))
    end
  end

  @doc """
  Sets the password of a post or group default. An existing password rule is
  rotated in place: a new hash and a higher revision, which invalidates every
  grant readers hold for the old one. A rotation keeps the rule's end date
  unless `attrs` gives a new one (`"expires_at"`) or lifts it
  (`"no_end_date" => true`).
  """
  @spec set_password(owner(), String.t(), map(), keyword()) ::
          {:ok, Rule.t()} | {:error, term()}
  def set_password(owner, password, attrs \\ %{}, opts \\ [])

  def set_password(owner, password, attrs, opts) when is_binary(password) do
    if String.length(String.trim(password)) < 4 do
      {:error, :password_too_short}
    else
      hash = Bcrypt.hash_pwd_salt(password)

      case Enum.filter(list_rules(owner), &(&1.kind == "password")) do
        [] ->
          insert_rule(owner, "password", %{"hash" => hash, "rev" => 1}, attrs, opts)

        [rule | extra] ->
          rotate_password(owner, rule, extra, hash, attrs, opts)
      end
    end
  end

  def set_password(_owner, _password, _attrs, _opts), do: {:error, :password_too_short}

  defp rotate_password(owner, rule, extra, hash, attrs, opts) do
    config = %{"hash" => hash, "rev" => revision(rule) + 1}

    # One password per owner: a second row (two first saves racing) would
    # keep accepting its old password after the rotation.
    Enum.each(extra, fn row -> repo().delete(row) end)

    # A rotation without an end date keeps the one the rule has: a new
    # password must not quietly lift an expiry the admin set. Lifting it is
    # explicit: `"no_end_date" => true` (the panel's "No end date" box).
    expires_at =
      if attr(attrs, "no_end_date") in [true, "true", "on"],
        do: nil,
        else: parse_expiry(attr(attrs, "expires_at")) || rule.expires_at

    rule
    |> Rule.changeset(%{
      config: config,
      expires_at: expires_at,
      note: blank_to_nil(attr(attrs, "note")) || rule.note
    })
    |> repo().update()
    |> after_write(owner, "password_rotated", opts)
  end

  @doc """
  Creates a secret link for a post. Returns the key ONCE — only its digest is
  stored, so it cannot be shown again. `attrs`: `"note"` (who it is for),
  `"expires_at"`.
  """
  @spec create_link({:post, String.t()}, map(), keyword()) ::
          {:ok, Rule.t(), String.t()} | {:error, term()}
  def create_link({:post, _} = owner, attrs \\ %{}, opts \\ []) do
    key = @key_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case insert_rule(owner, "token", %{"digest" => digest(key)}, attrs, opts) do
      {:ok, rule} -> {:ok, rule, key}
      error -> error
    end
  end

  @doc "Revokes a secret link: readers who redeemed it lose access at once."
  @spec revoke_link(String.t(), keyword()) :: {:ok, Rule.t()} | {:error, term()}
  def revoke_link(rule_uuid, opts \\ []) do
    case get_rule(rule_uuid) do
      %Rule{kind: "token"} = rule ->
        rule
        |> Rule.changeset(%{revoked_at: DateTime.truncate(DateTime.utc_now(), :second)})
        |> repo().update()
        |> after_write(owner_of(rule), "link_revoked", opts)

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Deletes one rule (any kind)."
  @spec delete_rule(String.t(), keyword()) :: {:ok, Rule.t()} | {:error, term()}
  def delete_rule(rule_uuid, opts \\ []) do
    case get_rule(rule_uuid) do
      %Rule{} = rule ->
        rule |> repo().delete() |> after_write(owner_of(rule), "rule_deleted", opts)

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Makes a post public again: every rule, links included, is deleted."
  @spec clear(owner(), keyword()) :: :ok
  def clear(owner, opts \\ []) do
    {column, uuid} = owner_column(owner)
    {count, _} = repo().delete_all(from(r in Rule, where: field(r, ^column) == ^uuid))
    if count > 0, do: after_change(owner, "cleared", opts)
    :ok
  end

  @doc """
  Sets the match mode of a post or group default (`"any"` / `"all"`), and for
  a group whether it lists protected posts to readers who may open them
  (`list_protected:` option).
  """
  @spec put_settings(owner(), map(), keyword()) :: {:ok, Rule.t()} | {:error, term()}
  def put_settings(owner, settings, opts \\ []) do
    existing = Enum.find(list_rules(owner), &(&1.kind == "settings"))
    current = (existing && existing.config) || %{}

    config =
      current
      |> maybe_put_setting("match", fetch_setting(settings, "match"), ~w(any all))
      |> maybe_put_bool("list_protected", fetch_setting(settings, "list_protected"))

    case existing do
      nil ->
        insert_rule(owner, "settings", config, %{}, opts)

      rule ->
        rule
        |> Rule.changeset(%{config: config})
        |> repo().update()
        |> after_write(owner, "settings", opts)
    end
  end

  @setting_atoms %{"match" => :match, "list_protected" => :list_protected}

  defp fetch_setting(settings, key) do
    case Map.fetch(settings, key) do
      {:ok, v} -> v
      :error -> Map.get(settings, Map.fetch!(@setting_atoms, key))
    end
  end

  defp maybe_put_setting(config, key, value, allowed) do
    if value in allowed, do: Map.put(config, key, value), else: config
  end

  defp maybe_put_bool(config, _key, nil), do: config
  defp maybe_put_bool(config, key, value), do: Map.put(config, key, value in [true, "true", "on"])

  @doc """
  Copies a group's default rules onto a new post. Secret links are never
  part of a group default. Called by `Posts.create_post/3`; a no-op for a
  group without defaults.
  """
  @spec copy_group_defaults(String.t() | nil, String.t(), keyword()) :: :ok
  def copy_group_defaults(group_uuid, post_uuid, opts \\ [])

  def copy_group_defaults(nil, _post_uuid, _opts), do: :ok

  def copy_group_defaults(group_uuid, post_uuid, opts) do
    case defaults_to_copy(group_uuid) do
      [] ->
        :ok

      rules ->
        # All or nothing: a partial copy can WIDEN access (the settings row
        # with match "all" missing, or one kind of an "all" set).
        {:ok, _} =
          repo().transaction(fn -> Enum.each(rules, &copy_rule(&1, post_uuid, opts)) end)

        :ok
    end
  rescue
    # A database without V4 yet (code deployed before the migration) must
    # still create posts: no rules table means no group defaults either.
    # Any other failure raises, so the post is not left looking protected
    # to the admin while it is public.
    error in Postgrex.Error ->
      if error.postgres[:code] == :undefined_table do
        Logger.warning("[PostAccess] group defaults not copied: no access-rules table")
        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  defp defaults_to_copy(group_uuid) do
    group_uuid
    |> then(&list_rules({:group, &1}))
    |> Enum.reject(&(&1.kind == "token"))
    |> Enum.map(fn
      %Rule{kind: "settings", config: config} = rule ->
        %{rule | config: Map.take(config, ["match"])}

      rule ->
        rule
    end)
  end

  defp copy_rule(rule, post_uuid, opts) do
    %Rule{}
    |> Rule.changeset(%{
      post_uuid: post_uuid,
      kind: rule.kind,
      config: rule.config,
      note: rule.note,
      expires_at: rule.expires_at,
      created_by_uuid: ActivityLog.actor_uuid(opts)
    })
    # Raises: both callers run it in a transaction, which must roll back
    # (apply_group_defaults/2 has already deleted the post's own rules).
    |> repo().insert!()
  end

  @doc """
  How many of a group's live posts `apply_group_defaults/2` would change:
  every post that is not trashed, less those with rules of their own when
  `keep_custom: true`.
  """
  @spec preview_group_defaults(String.t(), keyword()) :: non_neg_integer()
  def preview_group_defaults(group_uuid, opts \\ []) do
    group_uuid |> target_posts(opts) |> length()
  end

  @doc """
  Pushes a group's default rules onto its existing posts (`keep_custom:
  true` skips posts that already have rules). A post's own non-link rules are
  replaced; its secret links stay. Returns the number of posts changed.
  """
  @spec apply_group_defaults(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def apply_group_defaults(group_uuid, opts \\ []) do
    posts = target_posts(group_uuid, opts)
    defaults = defaults_to_copy(group_uuid)

    {:ok, count} =
      repo().transaction(fn ->
        Enum.each(posts, fn post_uuid ->
          repo().delete_all(
            from(r in Rule, where: r.post_uuid == ^post_uuid and r.kind != "token")
          )

          Enum.each(defaults, &copy_rule(&1, post_uuid, opts))
        end)

        length(posts)
      end)

    if count > 0,
      do: after_change({:group, group_uuid}, "defaults_applied", opts, %{"posts" => count})

    {:ok, count}
  end

  defp target_posts(group_uuid, opts) do
    posts =
      repo().all(
        from(p in PublishingPost,
          where: p.group_uuid == ^group_uuid and is_nil(p.trashed_at),
          select: p.uuid
        )
      )

    if Keyword.get(opts, :keep_custom, false) do
      with_rules = protected_or_configured(posts)
      Enum.reject(posts, &Map.has_key?(with_rules, &1))
    else
      posts
    end
  end

  defp protected_or_configured([]), do: %{}

  defp protected_or_configured(post_uuids) do
    from(r in Rule, where: r.post_uuid in ^post_uuids, distinct: true, select: r.post_uuid)
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  # ===========================================================================
  # Plain-language summary
  # ===========================================================================

  @doc """
  One sentence describing who may open a post: "Public", or for example
  "Readers with the role Client ACME, or with the password, until 30 Jun 2026".
  """
  @spec summary([Rule.t()]) :: String.t()
  def summary(rules) do
    now = DateTime.utc_now()
    gates = Enum.filter(rules, &(&1.kind in @gate_kinds))

    case gates do
      [] ->
        gettext("Public — anyone can open this post")

      gates ->
        parts =
          gates
          |> Enum.filter(&active?(&1, now))
          |> Enum.group_by(& &1.kind)
          |> Enum.map(fn {kind, rules} -> summary_part(kind, rules) end)
          |> Enum.sort()

        joiner =
          if match_of(rules) == "all",
            do: " " <> gettext("and") <> " ",
            else: " " <> gettext("or") <> " "

        case parts do
          [] -> gettext("Hidden — every rule has expired or was revoked")
          parts -> gettext("Only: %{who}", who: Enum.join(parts, joiner))
        end
    end
  end

  defp summary_part("signed_in", rules), do: gettext("signed-in readers") <> until(rules)

  defp summary_part("role", rules) do
    names = rules |> Enum.flat_map(&List.wrap(&1.config["role_uuids"])) |> role_names()
    gettext("readers with the role %{roles}", roles: Enum.join(names, ", ")) <> until(rules)
  end

  defp summary_part("user", rules) do
    count = rules |> Enum.flat_map(&List.wrap(&1.config["user_uuids"])) |> Enum.uniq() |> length()
    ngettext("%{count} chosen user", "%{count} chosen users", count) <> until(rules)
  end

  defp summary_part("password", rules), do: gettext("anyone with the password") <> until(rules)

  defp summary_part("token", rules) do
    ngettext("%{count} secret link", "%{count} secret links", length(rules))
  end

  defp until(rules) do
    case rules |> Enum.map(& &1.expires_at) |> Enum.reject(&is_nil/1) do
      [] ->
        ""

      dates ->
        date = dates |> Enum.max(DateTime) |> DateTime.to_date() |> Date.to_iso8601()
        " " <> gettext("(until %{date})", date: date)
    end
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  @doc false
  @spec get_rule(String.t()) :: Rule.t() | nil
  def get_rule(uuid), do: with_uuid(uuid, nil, &repo().get(Rule, &1))

  defp insert_rule(owner, kind, config, attrs, opts) do
    {column, uuid} = owner_column(owner)

    %Rule{}
    |> Rule.changeset(%{
      column => uuid,
      kind: kind,
      config: config,
      note: blank_to_nil(attr(attrs, "note")),
      expires_at: parse_expiry(attr(attrs, "expires_at")),
      created_by_uuid: ActivityLog.actor_uuid(opts)
    })
    |> repo().insert()
    |> after_write(owner, "#{kind}_added", opts)
  end

  defp after_write({:ok, rule} = ok, owner, what, opts) do
    after_change(owner, what, opts, %{"rule_kind" => rule.kind})
    ok
  end

  defp after_write(error, _owner, _what, _opts), do: error

  # The listing cache carries each post's protected flag, so every change
  # rebuilds the group's listing; a change can add or remove a public URL,
  # so the sitemap is asked to refresh too.
  defp after_change(owner, what, opts, metadata \\ %{}) do
    {resource_type, resource_uuid, group_slug} = describe_owner(owner)

    if group_slug do
      ListingCache.regenerate(group_slug)
      SitemapRefresh.request()
    end

    ActivityLog.log_manual(
      "publishing.access.changed",
      ActivityLog.actor_uuid(opts),
      resource_type,
      resource_uuid,
      Map.merge(%{"change" => what}, metadata),
      opts
    )

    :ok
  end

  defp describe_owner({:post, uuid}) do
    slug =
      case DBStorage.get_post_by_uuid(uuid, [:group]) do
        %PublishingPost{group: %PublishingGroup{slug: slug}} -> slug
        _ -> nil
      end

    {"publishing_post", uuid, slug}
  end

  defp describe_owner({:group, uuid}) do
    slug =
      case DBStorage.get_group(uuid) do
        %PublishingGroup{slug: slug} -> slug
        _ -> nil
      end

    {"publishing_group", uuid, slug}
  end

  defp owner_of(%Rule{post_uuid: uuid}) when is_binary(uuid), do: {:post, uuid}
  defp owner_of(%Rule{group_uuid: uuid}), do: {:group, uuid}

  defp owner_column({:post, uuid}), do: {:post_uuid, uuid}
  defp owner_column({:group, uuid}), do: {:group_uuid, uuid}

  defp uuid_list(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      v when is_binary(v) -> String.split(v, [",", " ", "\n"], trim: true)
      _ -> []
    end)
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
  end

  defp parse_expiry(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp parse_expiry(value) when is_binary(value) and value != "" do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, dt, _} = DateTime.from_iso8601(value)
        DateTime.truncate(dt, :second)

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      true ->
        nil
    end
  end

  defp parse_expiry(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp blank_to_nil(_), do: nil

  defp with_uuid(value, default, fun) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> fun.(uuid)
      :error -> default
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
