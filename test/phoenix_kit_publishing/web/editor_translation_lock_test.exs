defmodule PhoenixKit.Modules.Publishing.Web.EditorTranslationLockTest do
  @moduledoc """
  While the AI is writing a version, the editor holds a lock so a person
  can't save over the write in progress.

  Every version or language switch patches through `handle_params`, which
  cleared that lock — it had to, because completion events for the version
  you left are deliberately ignored, and without the clear the editor would
  sit behind a spinner forever. But it cleared the lock for the version being
  arrived at too, so switching away from a translating version and back again
  handed the editor back while the write was still running, and whichever
  save landed last won.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor

  defp running?(in_flight, params), do: Editor.translation_running_for?(in_flight, params)

  test "arriving back at a translating version locks it again" do
    assert running?(MapSet.new(["2"]), %{"v" => "2"})
  end

  test "arriving at a version nobody is translating leaves it writable" do
    refute running?(MapSet.new(["2"]), %{"v" => "1"})
  end

  test "the version with no ?v= is scope nil, and tracked the same way" do
    refute running?(MapSet.new(["2"]), %{})
    assert running?(MapSet.new([nil]), %{})
  end

  test "nothing in flight means nothing locked" do
    refute running?(MapSet.new(), %{"v" => "2"})
    refute running?(nil, %{"v" => "2"})
  end

  test "an unparsable version doesn't match a real one" do
    refute running?(MapSet.new(["2"]), %{"v" => "banana"})
  end
end
