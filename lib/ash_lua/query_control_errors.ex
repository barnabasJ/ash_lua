# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
# SPDX-License-Identifier: MIT

defmodule AshLua.QueryControlErrors do
  @moduledoc false

  # Preserve the returned query and every unmatched error. Consume previous
  # errors from the suffix: Ash.Query.add_error prepends new errors.
  def normalize_returned(query, previous_errors, control, input) do
    {errors, _remaining} =
      Enum.map_reduce(Enum.reverse(query.errors), previous_errors, fn error, remaining ->
        if error in remaining do
          {error, List.delete(remaining, error)}
        else
          {normalize_shape_error(error, control, input), remaining}
        end
      end)

    %{query | errors: Enum.reverse(errors)}
  end

  defp normalize_shape_error(%{__struct__: Ash.Error.Query.InvalidSort, sort: input}, :sort, input)
       when is_number(input) or is_boolean(input),
       do: invalid_control(:sort)

  defp normalize_shape_error(
         %Ash.Error.Query.InvalidFilterValue{
           value: [], context: nil, message: "expected a non-empty list or map"
         } = error,
         :filter,
         input
       ) when is_map(input) do
    if Enum.any?(["or", "and", :or, :and], fn key ->
         Map.has_key?(input, key) && Map.get(input, key) in [[], %{}]
       end),
       do: invalid_control(:filter),
       else: error
  end

  defp normalize_shape_error(error, _control, _input), do: error

  defp invalid_control(control) do
    name = Atom.to_string(control)

    %AshLua.Errors.FieldsError{
      message: "invalid #{name}", short_message: "invalid #{name}",
      code: "invalid_#{name}", fields: [name], vars: %{}
    }
    |> Ash.Error.set_path([control])
  end
end
