defmodule PhoenixKit.Modules.Publishing.API.DangerTextTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  @bad [
    "<script>x</script>",
    "<CTA action=\"x\">",
    "[[post:abc]]",
    "javascript:alert(1)",
    "Java Script:x",
    "data:text/html,x",
    "[x](ftp://h)",
    "[x](&#106;avascript:alert(1))"
  ]

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "T", slug: "t"})
    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt")
    %{post: post, ref: %{"id" => post[:uuid]}}
  end

  test "update_post: plain content false, each rule true on a DRAFT, no content false, null content false",
       %{ref: ref} do
    refute Danger.update_post(%{"post" => ref, "content" => "# plain"}, ctx())
    refute Danger.update_post(%{"post" => ref, "title" => "x"}, ctx())
    refute Danger.update_post(%{"post" => ref, "content" => nil}, ctx())

    for text <- @bad,
        do: assert(Danger.update_post(%{"post" => ref, "content" => text}, ctx()), text)

    assert Danger.update_post(%{"post" => ref, "content" => 5}, ctx()),
           "a non-string, non-null content fails closed"
  end

  test "update_post without content is false even when the stored body holds HTML", %{
    post: post,
    ref: ref
  } do
    Fx.body!(Fx.db_group_slug(post[:uuid]), post[:uuid], "<span>stored html</span>")
    refute Danger.update_post(%{"post" => ref, "title" => "x"}, ctx())
  end

  test "the stand's home markup is dangerous", %{ref: ref} do
    assert Danger.update_post(
             %{"post" => ref, "content" => ~s(# Decor<span class="text-primary">3D</span>print)},
             ctx()
           )
  end

  test "set_translation: plain false, each rule true on a draft", %{ref: ref} do
    refute Danger.set_translation(
             %{"post" => ref, "language" => "de-DE", "title" => "t", "content" => "plain"},
             ctx()
           )

    for text <- @bad,
        do:
          assert(
            Danger.set_translation(
              %{"post" => ref, "language" => "de-DE", "title" => "t", "content" => text},
              ctx()
            ),
            text
          )
  end

  test "the text clause ignores the confirmation: true with a confirmation uuid too", %{ref: ref} do
    ctx = Map.put(ctx(), :confirmation_uuid, "c")
    assert Danger.update_post(%{"post" => ref, "content" => "<b>x</b>"}, ctx)
    assert Danger.set_translation(%{"post" => ref, "content" => "<b>x</b>"}, ctx)
  end
end
