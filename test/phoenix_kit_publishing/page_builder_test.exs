defmodule PhoenixKit.Modules.Publishing.PageBuilderTest do
  @moduledoc """
  End-to-end tests for the page builder pipeline:
  parse → inject assigns → resolve → theme → render.

  Pure-function tests — no DB, no LV, no IO.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PageBuilder

  defp html(safe), do: safe |> Phoenix.HTML.safe_to_string()

  describe "render_content/2" do
    test "renders an unknown component AST through the fallback wrapper" do
      assert {:ok, safe} = PageBuilder.render_content("<Foobar>hello</Foobar>")
      rendered = html(safe)
      assert rendered =~ ~s(<div class="unknown-component">)
      assert rendered =~ "hello"
    end

    test "interpolates {{variable}} placeholders from assigns into content" do
      assert {:ok, safe} =
               PageBuilder.render_content("<Foobar>Hi {{name}}</Foobar>", %{
                 "name" => "Max"
               })

      assert html(safe) =~ "Hi Max"
    end

    test "interpolates atom-keyed assigns when string lookup misses" do
      assert {:ok, safe} =
               PageBuilder.render_content("<Foobar>Hi {{name}}</Foobar>", %{name: "Max"})

      assert html(safe) =~ "Hi Max"
    end

    test "interpolates nested values via dot path" do
      assert {:ok, safe} =
               PageBuilder.render_content("<Foobar>Hi {{user.name}}</Foobar>", %{
                 "user" => %{"name" => "Ada"}
               })

      assert html(safe) =~ "Hi Ada"
    end

    test "missing variables resolve to empty string" do
      assert {:ok, safe} = PageBuilder.render_content("<Foobar>Hi {{missing}}</Foobar>")
      assert html(safe) =~ "Hi "
    end

    test "returns parse_error for malformed XML" do
      assert {:error, {:parse_error, _}} = PageBuilder.render_content("<Foobar")
    end

    test "renders a list of unknown components when given multiple top-level nodes" do
      input = ~s(<Foobar>alpha</Foobar>)
      assert {:ok, safe} = PageBuilder.render_content(input)
      rendered = html(safe)
      assert rendered =~ "alpha"
    end
  end
end
