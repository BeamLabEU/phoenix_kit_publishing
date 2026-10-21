defmodule PhoenixKit.Modules.Publishing.API.DangerCreatePostTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKitPublishing.Test.ApiCase

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  test "false when content is absent or null or plain; true for each text rule" do
    refute Danger.create_post(%{"group" => "g", "title" => "t"}, ctx())
    refute Danger.create_post(%{"group" => "g", "title" => "t", "content" => nil}, ctx())

    refute Danger.create_post(
             %{"group" => "g", "title" => "t", "content" => "# plain\n\n- list"},
             ctx()
           )

    for bad <- ["<script>x</script>", "[[post:abc]]", "javascript:alert(1)", "[x](ftp://h)"] do
      assert Danger.create_post(%{"content" => bad}, ctx()), bad
    end
  end

  test "a non-string content fails closed" do
    assert Danger.create_post(%{"content" => 5}, ctx())
    assert Danger.create_post(%{"content" => %{}}, ctx())
  end

  test "the function never reads the confirmation: true with a confirmation uuid too" do
    assert Danger.create_post(%{"content" => "<b>x</b>"}, Map.put(ctx(), :confirmation_uuid, "c"))
  end
end
