# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
# SPDX-License-Identifier: MIT

defmodule AshLua.InputCompatibilityTest do
  use ExUnit.Case, async: false
  alias AshLua.Test.Posts.Post

  test "returned native shape errors retain the Lua control error contract" do
    if returned_control_errors?() do
      filter_query = Ash.Query.filter_input(Post, %{"or" => []})
      assert Enum.any?(filter_query.errors,
        &match?(%Ash.Error.Query.InvalidFilterValue{value: []}, &1))
      sort_query = Ash.Query.sort_input(Post, 5)
      assert Enum.any?(sort_query.errors,
        &match?(%{__struct__: Ash.Error.Query.InvalidSort}, &1))
    else
      assert_raise FunctionClauseError, fn -> Ash.Query.filter_input(Post, %{"or" => []}) end
      assert_raise FunctionClauseError, fn -> Ash.Query.sort_input(Post, 5) end
    end

    for {control, code} <- [
          {~s|filter = { ["or"] = {} }|, "invalid_filter"},
          {"sort = 5", "invalid_sort"}
        ] do
      assert {:ok, %{result: nil, error: error, print_output: ["continued"]}} =
               AshLua.Eval.run(
                 "local r, err = posts.post.read({" <>
                   control <> "}); print('continued'); return r, err", otp_app: :ash_lua)

      assert error["class"] == "invalid"
      field = if code == "invalid_filter", do: "filter", else: "sort"
      assert [%{"code" => ^code, "fields" => [^field]}] = error["errors"]
    end
  end

  test "valid filter and sort preserve the matching rows and order" do
    marker = Ash.UUID.generate()
    Ash.create!(Post, %{title: marker <> "-b", body: marker})
    Ash.create!(Post, %{title: marker <> "-a", body: marker})

    assert {:ok, %{result: rows, error: nil}} =
             AshLua.Eval.run(
               """
               return posts.post.read({filter = {body = "#{marker}"}, sort = "title", fields = {"title"}})
               """,
               otp_app: :ash_lua
             )

    assert Enum.map(rows, & &1["title"]) == [marker <> "-a", marker <> "-b"]
  end

  test "invalid calculation input retains its semantic filter error" do
    assert {:ok, %{result: nil, error: error}} =
             AshLua.Eval.run(
               """
               return posts.post.read({filter = {title_prefixed = {input = 5, eq = "x"}}})
               """,
               otp_app: :ash_lua
             )

    assert error["class"] == "invalid"

    if returned_control_errors?() do
      assert [%{"code" => "invalid_filter_value",
        "vars" => %{"detail" => "calculation input must be a map"}}] = error["errors"]
    else
      assert [%{"code" => "invalid_filter", "fields" => ["filter"]}] = error["errors"]
    end
  end

  test "unknown sort fields retain their semantic field error" do
    assert {:ok, %{result: nil, error: error}} =
             AshLua.Eval.run(~s|return posts.post.read({sort = "not_a_post_attribute"})|,
               otp_app: :ash_lua
             )

    assert error["class"] == "invalid"
    assert [%{"code" => "unknown_field"} | _] = error["errors"]
  end

  test "calculation sort errors retain their native payload" do
    returned = Ash.Query.sort_input(Post, [{:title_prefixed, 5}])
    if returned_control_errors?() do
      assert [%{__struct__: Ash.Error.Query.InvalidSort, sort: {:title_prefixed, 5}}] = returned.errors
    else
      assert [%Ash.Error.Unknown.UnknownError{path: [:sort]}] = returned.errors
    end

    normalized =
      AshLua.QueryControlErrors.normalize_returned(returned, [], :sort, [{:title_prefixed, 5}])

    assert normalized == returned
  end

  test "empty predicate values preserve native error details through Lua" do
    native = if returned_control_errors?() do
      query = Ash.Query.filter_input(Post, %{"title" => %{"contains" => %{}}})
      assert [%Ash.Error.Query.InvalidFilterValue{}] = query.errors
      query.errors |> Ash.Error.to_error_class() |> AshLua.Encoder.encode_error()
    else
      assert_raise FunctionClauseError, fn ->
        Ash.Query.filter_input(Post, %{"title" => %{"contains" => %{}}})
      end
      nil
    end
    assert {:ok, %{result: nil, error: error}} = AshLua.Eval.run(
      ~s|return posts.post.read({filter = {title = {contains = {}}}, fields = {"id"}})|,
      otp_app: :ash_lua)
    if native do
      assert error == native
      assert [%{"code" => "invalid_filter_value", "vars" => %{"detail" => _}}] = error["errors"]
    else
      assert error["class"] == "invalid"
      assert [%{"code" => "invalid_filter", "fields" => ["filter"]}] = error["errors"]
    end
  end

  test "a previous empty-value error cannot discard a successfully parsed filter" do
    previous =
      Ash.Error.Query.InvalidFilterValue.exception(
        value: [],
        message: "earlier semantic error",
        splode: Ash.Error
      )

    incoming = Ash.Query.add_error(Post, previous)
    returned = Ash.Query.filter_input(incoming, %{"title" => "kept"})
    refute returned.filter == incoming.filter

    normalized =
      AshLua.QueryControlErrors.normalize_returned(returned, incoming.errors, :filter, %{
        "title" => "kept"
      })

    assert normalized == returned
    assert previous in normalized.errors
  end

  test "matching new errors preserve unrelated errors and all returned query fields" do
    previous =
      Ash.Error.Query.InvalidFilterValue.exception(
        value: [],
        message: "earlier semantic error",
        splode: Ash.Error
      )

    incoming = Ash.Query.add_error(Post, previous)
    returned = Ash.Query.add_error(incoming,
      Ash.Error.Query.InvalidFilterValue.exception(value: [], context: nil,
        message: "expected a non-empty list or map"))

    unrelated =
      Ash.Error.Query.InvalidSortOrder.exception(order: :unrelated_semantic_order, splode: Ash.Error)

    returned = Ash.Query.add_error(returned, unrelated)

    normalized =
      AshLua.QueryControlErrors.normalize_returned(returned, incoming.errors, :filter, %{
        "or" => []
      })

    assert previous in normalized.errors
    assert unrelated in normalized.errors

    assert Enum.any?(
             normalized.errors,
             &match?(%AshLua.Errors.FieldsError{code: "invalid_filter"}, &1)
           )

    assert Map.drop(Map.from_struct(normalized), [:errors]) ==
             Map.drop(Map.from_struct(returned), [:errors])

    assert length(normalized.errors) == length(returned.errors)
  end

  test "equal previous and prepended shape errors retain exact order and query validity" do
    shape =
      Ash.Error.Query.InvalidFilterValue.exception(
        value: [],
        context: nil,
        message: "expected a non-empty list or map",
        splode: Ash.Error
      )

    unrelated =
      Ash.Error.Query.InvalidSortOrder.exception(order: :unrelated_semantic_order, splode: Ash.Error)

    incoming = Ash.Query.add_error(Post, shape)
    returned = incoming |> Ash.Query.add_error(unrelated) |> Ash.Query.add_error(shape)
    assert returned.errors == [shape, unrelated, shape]

    normalized =
      AshLua.QueryControlErrors.normalize_returned(returned, incoming.errors, :filter, %{
        "or" => []
      })

    assert [
             %AshLua.Errors.FieldsError{code: "invalid_filter", path: [:filter]},
             ^unrelated,
             ^shape
           ] = normalized.errors

    assert normalized.valid? == returned.valid?

    assert Map.drop(Map.from_struct(normalized), [:errors]) ==
             Map.drop(Map.from_struct(returned), [:errors])
  end

  test "replacement sort errors retain the native query control path" do
    if returned_control_errors?() do
      returned = Ash.Query.sort_input(Post, 5)
      normalized = AshLua.QueryControlErrors.normalize_returned(returned, [], :sort, 5)
      assert [%AshLua.Errors.FieldsError{code: "invalid_sort", path: [:sort]}] = normalized.errors
      assert normalized.valid? == returned.valid?
    else
      assert_raise FunctionClauseError, fn -> Ash.Query.sort_input(Post, 5) end
      assert {:ok, %{error: error}} = AshLua.Eval.run("return posts.post.read({sort = 5})", otp_app: :ash_lua)
      assert error["class"] == "invalid"
      assert [%{"code" => "invalid_sort", "fields" => ["sort"]}] = error["errors"]
    end
  end

  test "semantic filter errors keep their existing native error protocol" do
    assert {:ok, %{result: nil, error: error}} =
             AshLua.Eval.run(
               """
               return posts.post.read({filter = {not_a_post_attribute = "value"}})
               """,
               otp_app: :ash_lua
             )

    assert error["class"] == "invalid"
    assert [%{"code" => "unknown_field"} | _] = error["errors"]
  end
  defp returned_control_errors?, do: Code.ensure_loaded?(Ash.Error.Query.InvalidSort)

end
