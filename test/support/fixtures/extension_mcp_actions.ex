# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.ExtensionMCPActions do
  @moduledoc false
  # Exercises the EvalActions extension seams: runtime entrypoints resolution,
  # base-VM hook, and timeout. `narrow: true` in the action context resolves
  # the surface down to a single read action; `narrow: false` resolves the
  # full pair; `narrow: :empty` resolves an explicitly empty surface; no
  # `:narrow` key falls back to the static configured surface.
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.Posts.Post, actions: [:read, :create]
    resource AshLua.Test.Posts.Comment, actions: [:read]
    entrypoints_resolver({__MODULE__, :resolve_entrypoints})
    lua_init({__MODULE__, :base_vm})
  end

  def resolve_entrypoints(context) do
    source = Map.get(context, :source_context) || %{}

    case Map.get(source, :narrow) do
      true -> [{AshLua.Test.Posts.Post, :read}]
      false -> [{AshLua.Test.Posts.Post, :read}, {AshLua.Test.Posts.Post, :create}]
      :empty -> []
      nil -> nil
    end
  end

  def base_vm(_context) do
    Lua.new() |> Lua.set!([:greeting], "hola")
  end
end

defmodule AshLua.Test.Posts.TimeoutMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.Posts.Post, actions: [:read]
    timeout_ms(40)
  end
end

defmodule AshLua.Test.Posts.DynamicTimeoutMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.Posts.Post, actions: [:read]
    timeout_ms({__MODULE__, :default_timeout})
  end

  def default_timeout(_context), do: 40
end
