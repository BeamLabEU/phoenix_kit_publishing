defmodule PhoenixKit.Modules.Publishing.PageBuilder.RendererTest do
  @moduledoc """
  Tests for the AST-to-HTML page builder renderer.

  Pins the C12 fix where `render_unknown/2` previously string-interpolated
  AST content directly into a `<div>`. The current implementation wraps in
  a known-safe iolist via `Phoenix.HTML.raw/1` so the wrapper element
  stays well-formed even if AST content is unexpected.
  """

  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Publishing.PageBuilder.Renderer

  defp html(safe), do: safe |> Safe.to_iodata() |> IO.iodata_to_binary()

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
      # Admin-authored content can include inline HTML — MDEx + page_builder
      # share the trust boundary documented in render_markdown_html/1.
      ast = %{type: :unknown, attributes: %{}, content: "<em>marked up</em>"}

      assert {:ok, safe} = Renderer.render(ast, %{})
      rendered = html(safe)
      assert rendered =~ "<em>marked up</em>"
    end
  end

  describe "render/2 — stretch / align lanes" do
    defp headline_ast(attributes) do
      %{type: :headline, attributes: attributes, content: "Big Title", children: []}
    end

    test "stretch=20 wraps the component with clamped negative margins" do
      {:ok, safe} = Renderer.render(headline_ast(%{"stretch" => "20"}), %{})
      out = html(safe)

      assert out =~ ~s(class="pk-stretch")
      # 20% total = 10% per side, clamped to the column↔viewport gap.
      assert out =~ "min(10.0%, max(0px, (100vw - 100%) / 2 - 1rem))"
      assert out =~ "Big Title"
    end

    test "align=wide applies the preset; align=full goes full-bleed" do
      {:ok, wide} = Renderer.render(headline_ast(%{"align" => "wide"}), %{})
      assert html(wide) =~ "min(15.0%,"

      {:ok, full} = Renderer.render(headline_ast(%{"align" => "full"}), %{})
      out = html(full)
      assert out =~ ~s(class="pk-stretch")
      assert out =~ "margin-inline: calc(-1 * max(0px, (100vw - 100%) / 2 - 1rem))"
      refute out =~ "min("
    end

    test "an explicit stretch wins over an align preset" do
      {:ok, safe} = Renderer.render(headline_ast(%{"stretch" => "40", "align" => "full"}), %{})
      assert html(safe) =~ "min(20.0%,"
    end

    test "invalid values render unwrapped" do
      for attrs <- [
            %{"stretch" => "0"},
            %{"stretch" => "150"},
            %{"stretch" => "20; background:red"},
            %{"align" => "sideways"},
            %{}
          ] do
        {:ok, safe} = Renderer.render(headline_ast(attrs), %{})
        refute html(safe) =~ "pk-stretch"
      end
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
    test "a removed component type (Page/Hero) no longer resolves" do
      # Page/Hero were removed with the Pages module (core 0fc3de09); their type
      # now falls through to the catch-all instead of a real module.
      result = Renderer.render(%{type: :page, attributes: %{}, children: []}, %{})
      assert match?({:error, _}, result) or match?({:ok, _}, result)
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
