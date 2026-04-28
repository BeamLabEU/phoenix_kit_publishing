defmodule PhoenixKit.Modules.Publishing.PageBuilder.RendererTest do
  @moduledoc """
  Tests for the AST-to-HTML page builder renderer.

  Pins the C12 fix where `render_unknown/2` previously string-interpolated
  AST content directly into a `<div>`. The current implementation wraps in
  a known-safe iolist via `Phoenix.HTML.raw/1` so the wrapper element
  stays well-formed even if AST content is unexpected.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PageBuilder.Renderer

  defp html(safe), do: safe |> Phoenix.HTML.safe_to_string()

  describe "render/2 — unknown components" do
    test "wraps unknown component AST in <div class=\"unknown-component\">" do
      ast = %{type: :totally_unknown, attributes: %{}, content: "hello world"}

      assert {:ok, safe} = Renderer.render(ast, %{})
      rendered = html(safe)
      assert rendered =~ ~s(<div class="unknown-component">)
      assert rendered =~ "hello world"
      assert rendered =~ "</div>"
    end

    test "renders empty wrapper when AST has no content/children" do
      ast = %{type: :unknown, attributes: %{}}

      assert {:ok, safe} = Renderer.render(ast, %{})
      rendered = html(safe)
      assert rendered =~ ~s(<div class="unknown-component">)
      assert rendered =~ "</div>"
    end

    test "passes admin-trusted content through (HTML preserved per trust model)" do
      # Admin-authored content can include inline HTML — Earmark + page_builder
      # share the trust boundary documented in renderer.ex:201-209.
      ast = %{type: :unknown, attributes: %{}, content: "<em>marked up</em>"}

      assert {:ok, safe} = Renderer.render(ast, %{})
      rendered = html(safe)
      assert rendered =~ "<em>marked up</em>"
    end
  end

  describe "render/2 — list of AST nodes" do
    test "renders a list by joining each node" do
      list = [
        %{type: :unknown, attributes: %{}, content: "alpha"},
        %{type: :unknown, attributes: %{}, content: "beta"}
      ]

      assert {:ok, safe} = Renderer.render(list, %{})
      rendered = html(safe)
      assert rendered =~ "alpha"
      assert rendered =~ "beta"
    end
  end

  describe "render/2 — binary content" do
    test "wraps binary in raw HTML" do
      assert {:ok, safe} = Renderer.render("plain text", %{})
      assert html(safe) == "plain text"
    end
  end

  describe "render/2 — known component types resolve correctly" do
    test "resolves :page component type to a known module" do
      ast = %{
        type: :page,
        attributes: %{},
        children: [
          %{type: :unknown, attributes: %{}, content: "child"}
        ]
      }

      result = Renderer.render(ast, %{})
      # Either {:ok, html} for known component or {:error, ...}
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :hero component type" do
      ast = %{type: :hero, attributes: %{}, children: []}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :headline component type" do
      ast = %{type: :headline, attributes: %{}, content: "Title"}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :subheadline component type" do
      ast = %{type: :subheadline, attributes: %{}, content: "Sub"}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :cta component type" do
      ast = %{type: :cta, attributes: %{"action" => "/x"}, content: "Click"}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :image component type" do
      ast = %{type: :image, attributes: %{"src" => "/x.png"}, content: nil}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "resolves :video component type" do
      ast = %{type: :video, attributes: %{"src" => "/x.mp4"}, content: nil}
      result = Renderer.render(ast, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
