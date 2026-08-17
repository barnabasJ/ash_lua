# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Transformers.AddActions do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshLua.EvalActions.Info

  # The synthesized actions are added EARLY (no `after?(_) -> true` catch-all)
  # so that downstream transformers and other extensions — e.g. action
  # wrappers generated from the resource's final action set — can see and bind
  # to the synthesized `:eval`/`:docs` actions. Transformers that must run
  # after everything else still do: they declare their own `after?` clauses,
  # which outrank this transformer's neutral ordering.
  def after?(_), do: false

  def transform(dsl_state) do
    eval_name = Info.eval_action_name(dsl_state)
    docs_name = Info.docs_action_name(dsl_state)

    with {:ok, dsl_state} <- add_eval_action(dsl_state, eval_name) do
      add_docs_action(dsl_state, docs_name)
    end
  end

  defp add_eval_action(dsl_state, name) do
    with {:ok, script_arg} <- Builder.build_action_argument(:script, :string, allow_nil?: false),
         {:ok, timeout_arg} <-
           Builder.build_action_argument(:timeout_ms, :integer, allow_nil?: true) do
      Builder.add_new_action(dsl_state, :action, name,
        returns: :map,
        constraints: [
          fields: [
            result: [type: :term, allow_nil?: true],
            error: [type: :map, allow_nil?: true],
            print_output: [type: {:array, :string}, allow_nil?: true]
          ]
        ],
        arguments: [script_arg, timeout_arg],
        run: AshLua.EvalActions.Run.Eval
      )
    end
  end

  defp add_docs_action(dsl_state, name) do
    with {:ok, name_arg} <- Builder.build_action_argument(:name, :string, allow_nil?: true),
         {:ok, search_arg} <- Builder.build_action_argument(:search, :string, allow_nil?: true) do
      Builder.add_new_action(dsl_state, :action, name,
        returns: :string,
        arguments: [name_arg, search_arg],
        run: AshLua.EvalActions.Run.Docs
      )
    end
  end
end
