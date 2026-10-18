defmodule PhoenixKit.Modules.Publishing.API.DangerStaticTest do
  use ExUnit.Case, async: true

  # Spec §8 / F25: reads that rescue to an empty or false result are banned from the danger
  # functions, Refs and every preview path, because a database error must not look "safe".
  @banned [
    "Categories.published_post_counts(",
    "Categories.list_categories(",
    "Categories.by_slug(",
    "Categories.categories_by_uuids(",
    "Categories.list_tree(",
    "Posts.read_post_by_uuid(",
    "SlugHelpers.slug_exists?("
  ]

  test "guard/1 fails closed: a raise, a throw and an exit all answer true" do
    alias PhoenixKit.Modules.Publishing.API.Danger

    assert Danger.guard(fn -> raise "x" end) == true
    assert Danger.guard(fn -> throw(:x) end) == true
    assert Danger.guard(fn -> exit(:x) end) == true
    assert Danger.guard(fn -> false end) == false
  end

  test "danger.ex and refs.ex use none of the banned reads" do
    for file <- ~w(danger refs) do
      source = File.read!("lib/phoenix_kit_publishing/api/#{file}.ex")
      for banned <- @banned, do: refute(source =~ banned, "#{file}.ex calls #{banned}")
    end
  end

  test "handlers use no banned read on a dry-run path (checked per handler file, outside get_post)" do
    for path <- Path.wildcard("lib/phoenix_kit_publishing/api/*.ex"),
        Path.basename(path) != "get_post.ex" do
      source = File.read!(path)

      for banned <- @banned,
          do: refute(source =~ banned, "#{Path.basename(path)} calls #{banned}")
    end
  end

  test "api/ never calls a DBStorage write or an Ecto Repo write" do
    for path <- Path.wildcard("lib/phoenix_kit_publishing/api/**/*.ex") do
      source = File.read!(path)

      refute source =~
               ~r/DBStorage\.(create|update|delete|insert|upsert|set|trash|restore|publish|archive|lock)[a-z_!]*\(/,
             "#{path}: DBStorage write"

      refute source =~ ~r/repo\(\)\.(insert|update|delete|transaction)[a-z_!]*\(/,
             "#{path}: Repo write"

      refute source =~ ~r/ListingCache|PubSub|Phoenix\.PubSub/, "#{path}: cache or pubsub"
    end
  end

  test "api/ runs raw SQL only as a named SELECT statement" do
    for path <- Path.wildcard("lib/phoenix_kit_publishing/api/**/*.ex") do
      source = File.read!(path)

      for [_all, first_arg] <- Regex.scan(~r/\.query!?\(\s*([^,)\s]+)/, source) do
        assert first_arg == "sql", "#{path}: query called with #{first_arg}, not a named sql"
      end

      if source =~ ~r/\.query!?\(/ do
        statements = Regex.scan(~r/\bsql =\s*(?:"""\s*|")\s*(\w+)/, source)
        assert statements != [], "#{path}: no sql statement found to check"

        for [_all, verb] <- statements,
            do:
              assert(
                String.upcase(verb) in ["SELECT", "WITH"],
                "#{path}: sql starts with #{verb}"
              )
      end
    end
  end
end
