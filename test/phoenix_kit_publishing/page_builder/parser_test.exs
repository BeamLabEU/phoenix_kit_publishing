defmodule PhoenixKit.Modules.Publishing.PageBuilder.ParserTest do
  @moduledoc """
  Tests for the PHK XML → AST parser plus the Saxy handler that
  drives it. Pure-function coverage — no DB, no LiveView, no IO.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PageBuilder.Parser

  describe "parse/1 — element nodes" do
    test "parses a self-closed element with only attributes" do
      assert {:ok, ast} = Parser.parse(~s(<Hero variant="split-image"/>))

      assert ast == %{
               type: :hero,
               attributes: %{"variant" => "split-image"},
               children: [],
               content: nil
             }
    end

    test "parses an element with character content into the content key" do
      assert {:ok, ast} = Parser.parse(~s(<Headline>Welcome</Headline>))

      assert ast == %{
               type: :headline,
               attributes: %{},
               content: "Welcome"
             }
    end

    test "parses an element with children into the children key" do
      input = ~s(<Page><Headline>Hi</Headline><CTA action="/x">Go</CTA></Page>)
      assert {:ok, ast} = Parser.parse(input)

      assert ast.type == :page
      assert length(ast.children) == 2
      assert Enum.at(ast.children, 0).type == :headline
      assert Enum.at(ast.children, 0).content == "Hi"
      assert Enum.at(ast.children, 1).type == :cta
      assert Enum.at(ast.children, 1).attributes["action"] == "/x"
    end

    test "downcases tag names to atoms" do
      assert {:ok, %{type: :hero}} = Parser.parse("<Hero/>")
      assert {:ok, %{type: :hero}} = Parser.parse("<hero/>")
      assert {:ok, %{type: :hero}} = Parser.parse("<HERO/>")
    end

    test "downcases attribute keys" do
      assert {:ok, ast} = Parser.parse(~s(<Hero VARIANT="split-image"/>))
      assert ast.attributes["variant"] == "split-image"
    end
  end

  describe "parse/1 — error paths" do
    test "returns parse_error tuple for malformed XML" do
      assert {:error, {:parse_error, _}} = Parser.parse("<Hero")
    end

    test "returns invalid_content for non-binary input" do
      assert {:error, :invalid_content} = Parser.parse(:atom)
      assert {:error, :invalid_content} = Parser.parse(123)
      assert {:error, :invalid_content} = Parser.parse(nil)
    end

    test "trims content before parsing" do
      assert {:ok, %{type: :hero}} = Parser.parse("   \n  <Hero/>  \n")
    end
  end

  describe "parse/1 — character handling" do
    test "trims leading/trailing whitespace from content" do
      assert {:ok, ast} = Parser.parse("<Headline>   spaced   </Headline>")
      assert ast.content == "spaced"
    end

    test "preserves interpolation placeholders verbatim" do
      assert {:ok, ast} = Parser.parse("<Subheadline>Hi {{name}}</Subheadline>")
      assert ast.content == "Hi {{name}}"
    end
  end
end
