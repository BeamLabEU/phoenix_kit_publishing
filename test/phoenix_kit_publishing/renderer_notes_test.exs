defmodule PhoenixKit.Modules.Publishing.RendererNotesTest do
  @moduledoc """
  Pins the author-notes contract: `<Note note="…">phrase</Note>` renders a
  numbered superscript ref + a collected Notes section, numbering is
  document-sequential, code fences are immune, and note text is escaped in
  both the popover attribute and the section.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  test "renders the ref, the popover attribute, and the collected section" do
    html =
      Renderer.render_markdown(
        "Intro with <Note note=\"A clarifying remark.\">a tricky phrase</Note> in prose."
      )

    # add_tailwind_classes merges link classes onto the ref anchor.
    assert html =~ "pk-note-ref"
    assert html =~ ~s(href="#pk-note-1")
    assert html =~ ~s(data-note="A clarifying remark.")
    assert html =~ "a tricky phrase<sup>1</sup>"
    assert html =~ ~s(<li id="pk-note-1">A clarifying remark.)
    assert html =~ ~s(class="pk-notes)
    assert html =~ "<style>"
  end

  test "numbers notes sequentially through the document" do
    html =
      Renderer.render_markdown("""
      First <Note note="one">alpha</Note> then <Note note="two">beta</Note>.

      Later <Note note="three">gamma</Note>.
      """)

    assert html =~ "alpha<sup>1</sup>"
    assert html =~ "beta<sup>2</sup>"
    assert html =~ "gamma<sup>3</sup>"
    assert html =~ ~s(<li id="pk-note-3">three)
  end

  test "a literal <Note> inside a code fence is left alone" do
    html =
      Renderer.render_markdown("""
      Demo:

      ```
      <Note note="not real">shown as code</Note>
      ```
      """)

    refute html =~ "pk-note-ref"
    refute html =~ "pk-notes"
    assert html =~ "&lt;Note"
  end

  test "note text is escaped in the attribute and the section" do
    # Double quotes can't appear inside the note attribute (documented
    # limitation — the tag would not parse); angle brackets and ampersands
    # are escaped everywhere they render.
    html = Renderer.render_markdown(~s(X <Note note="a <b> & 'q'">phrase</Note> y))

    assert html =~ ~s(data-note="a &lt;b&gt; &amp; 'q'")
    assert html =~ ~s(<li id="pk-note-1">a &lt;b&gt; &amp; 'q')
    refute html =~ ~s(<li id="pk-note-1">a <b>)
  end

  test "no notes → no section, byte-identical pipeline behavior" do
    html = Renderer.render_markdown("Just **prose** here.")
    refute html =~ "pk-notes"
    refute html =~ "pk-note-ref"
    assert html =~ "<strong"
  end

  test "notes coexist with PHK components (mixed path)" do
    html =
      Renderer.render_markdown("""
      <Headline>Big</Headline>

      Body with <Note note="side info">a phrase</Note>.
      """)

    assert html =~ "a phrase<sup>1</sup>"
    assert html =~ ~s(<li id="pk-note-1">side info)
  end

  describe "panel style (notes_style: \"panel\")" do
    test "refs target the slide-out panel anchors; no bottom section" do
      content = "See <Note note=\"Panel body text.\">the phrase</Note> here."
      html = Renderer.render_markdown(content, notes_style: "panel")

      panel_id = Renderer.note_dom_id("Panel body text.")
      assert html =~ ~s(href="#pk-note-panel-#{panel_id}")
      assert html =~ "the phrase<sup>1</sup>"
      # Hover popover survives; the collected section does not.
      assert html =~ ~s(data-note="Panel body text.")
      assert html =~ ".pk-note-ref:hover::after"
      refute html =~ "pk-notes"
      refute html =~ ~s(id="pk-note-1")
    end

    test "unknown/absent style falls back to footnotes" do
      content = "See <Note note=\"n\">p</Note>."

      for style <- [nil, "bogus"] do
        html = Renderer.render_markdown(content, notes_style: style)
        assert html =~ ~s(href="#pk-note-1")
        assert html =~ "pk-notes"
      end
    end
  end

  describe "list_notes/1" do
    test "returns document-ordered notes with stable content-derived ids" do
      content = """
      One <Note note="first body">a</Note> and two <Note note="second body">b</Note>.

      ```
      <Note note="in a fence">ignored</Note>
      ```
      """

      assert [
               %{number: 1, id: id1, body: "first body"},
               %{number: 2, id: id2, body: "second body"}
             ] = Renderer.list_notes(content)

      assert id1 == Renderer.note_dom_id("first body")
      assert id1 != id2
      # The id is content-addressed: inserting an earlier note must not
      # move an existing note's anchor (comments stay attached).
      shifted = "Zero <Note note=\"new earliest\">z</Note>. " <> content
      assert Enum.any?(Renderer.list_notes(shifted), &(&1.id == id1))
    end

    test "no notes → empty list; non-binary input tolerated" do
      assert Renderer.list_notes("plain prose") == []
      assert Renderer.list_notes(nil) == []
    end

    test "duplicate note texts get distinct ids; the first keeps the plain digest" do
      content = "A <Note note=\"same\">x</Note> B <Note note=\"same\">y</Note>."

      assert [%{id: id1}, %{id: id2}] = Renderer.list_notes(content)
      assert id1 == Renderer.note_dom_id("same")
      assert id1 != id2

      # The rendered refs target the two distinct panels.
      html = Renderer.render_markdown(content, notes_style: "panel")
      assert html =~ ~s(href="#pk-note-panel-#{id1}")
      assert html =~ ~s(href="#pk-note-panel-#{id2}")
    end
  end
end
