# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Run.Eval do
  @moduledoc """
  Implementation backing the synthesized `:eval` action.

  Evaluates the script through `AshLua.Eval.run/2` against a manifest scoped to
  the `eval_actions` configuration, with the caller's actor / tenant / context
  threaded through.

  The action returns a typed map `%{result, error, print_output}` mirroring
  the in-script `(result, err)` convention — successful runs populate
  `result`; failed runs populate `error`.

  Extension seams honored here:

    * `entrypoints_resolver` — resolves the manifest's action entrypoints
      from the action context at call time (falling back to the static
      labels/`resource` surface when unset or when the resolver returns
      `nil`). Resolver-scoped surfaces bypass the eval-manifest cache.
    * `lua_init` — supplies the base `%Lua{}` VM bindings are installed on
      (falling back to a plain `Lua.new/0`), so applications can hand in a
      hardened VM.
    * `timeout_ms` — bounds execution. The optional `timeout_ms` action
      argument overrides the configured default (static integer or
      `{module, function}` of the action context). On timeout the script task
      is brutally killed and the failure rides the typed `error` slot with
      code `lua_script_timeout`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshLua.EvalActions.Info

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    script = Map.get(input.arguments, :script)

    if is_binary(script) do
      manifest_opts = resolve_manifest_opts(resource, context)

      eval_opts =
        [
          actor: context.actor,
          tenant: context.tenant,
          context:
            if(is_map(Map.get(context, :source_context)), do: context.source_context, else: %{}),
          forbidden_fields: Info.forbidden_fields(resource)
        ]
        |> maybe_put_lua(resource, context)
        |> Keyword.merge(manifest_opts)

      case resolve_timeout(resource, input, context) do
        nil ->
          AshLua.Eval.run(script, eval_opts)

        timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
          eval_with_timeout(script, eval_opts, timeout_ms)

        _invalid ->
          {:error,
           Ash.Error.Action.InvalidArgument.exception(
             field: :timeout_ms,
             message: "must be a positive integer"
           )}
      end
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :script,
         message: "must be a string"
       )}
    end
  end

  # --- Manifest scoping (entrypoints_resolver seam) --------------------------

  # Resolver-scoped surfaces are per-call: never served from (or written to)
  # the eval-manifest cache. `nil` / unset falls back to the static surface,
  # which keeps the cached default path unchanged.
  defp resolve_manifest_opts(resource, context) do
    case Info.entrypoints_resolver(resource) do
      nil ->
        [eval_resource: resource, cache?: true]

      {module, function} ->
        case apply(module, function, [context]) do
          nil ->
            [eval_resource: resource, cache?: true]

          entrypoints when is_list(entrypoints) ->
            otp_app = AshLua.EvalActions.Info.otp_app(resource)

            [otp_app: otp_app, action_entrypoints: entrypoints]
        end
    end
  end

  # --- Base-VM hook ------------------------------------------------------------

  defp maybe_put_lua(opts, resource, context) do
    case Info.lua_init(resource) do
      nil ->
        opts

      {module, function} ->
        Keyword.put(opts, :lua, apply(module, function, [context]))
    end
  end

  # --- Timeout seam -------------------------------------------------------------

  defp resolve_timeout(resource, input, context) do
    case Map.get(input.arguments, :timeout_ms) do
      nil -> default_timeout(resource, context)
      supplied -> supplied
    end
  end

  defp default_timeout(resource, context) do
    case Info.timeout_ms(resource) do
      nil -> nil
      {module, function} -> apply(module, function, [context])
      static -> static
    end
  end

  # Runs the script on an unlinked task so a runaway script can be killed
  # without taking the caller down; `receive` bounds the wait and a timeout
  # results in a brutal kill. The task carries its own rescue/catch so the
  # classified error contract (`AshLua.Eval.run/2`'s) holds identically on
  # both the plain and the time-bounded path.
  defp eval_with_timeout(script, eval_opts, timeout_ms) do
    parent = self()
    ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        try do
          send(parent, {ref, AshLua.Eval.run(script, eval_opts)})
        rescue
          e ->
            send(parent, {ref, {:error, Exception.format(:error, e, __STACKTRACE__)}})
        catch
          kind, reason ->
            send(parent, {ref, {:error, Exception.format(kind, reason, __STACKTRACE__)}})
        end
      end)

    monitor = Process.monitor(pid)

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {^ref, {:error, %{"errors" => _} = envelope}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, envelope}

      {^ref, {:error, formatted}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, failed_run(lua_error_envelope("script crashed: #{formatted}", "lua_error"))}

      {:DOWN, ^monitor, :process, ^pid, reason} when reason not in [:normal, :killed] ->
        {:ok, failed_run(lua_error_envelope("script crashed: #{inspect(reason)}", "lua_error"))}
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        {:ok, failed_run(timeout_failure(timeout_ms))}
    end
  end

  # A killed/timeout/crashed run is still a successful action whose script
  # failed — the failure rides the typed `error` slot with a stable code, the
  # same shape Lua compile/runtime failures use.
  defp failed_run(envelope) do
    %{result: nil, error: envelope, print_output: []}
  end

  defp timeout_failure(timeout_ms) do
    lua_error_envelope("script timed out after #{timeout_ms}ms", "lua_script_timeout")
  end

  defp lua_error_envelope(message, code) do
    %{
      "message" => message,
      "errors" => [
        %{
          "message" => message,
          "short_message" => code,
          "code" => code,
          "fields" => [],
          "vars" => %{}
        }
      ]
    }
  end
end
