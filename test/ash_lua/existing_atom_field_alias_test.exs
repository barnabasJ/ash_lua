defmodule AshLua.ExistingAtomFieldAliasTest do
  use ExUnit.Case, async: false
  alias AshLua.Test.Surface.Page

  test "resource aliases resolve after their external names already exist as atoms" do
    assert Enum.map([:headline, :featured], &Atom.to_string/1) == ["headline", "featured"]
    {:ok, page} = Ash.create(Page, %{title: "Before"}, action: :create)
    assert {:ok, %{result: result, error: nil}} = AshLua.Eval.run("""
    return surface.page_rename({
      input = {id = "#{page.id}", headline = "After", featured = true},
      fields = {"id", "headline", "featured"}
    })
    """, otp_app: :ash_lua)
    assert result == %{"id" => page.id, "headline" => "After", "featured" => true}
    assert {:ok, persisted} = Ash.get(Page, page.id)
    assert persisted.title == "After"
    assert persisted.featured?
  end
end
