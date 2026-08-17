# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions do
  @expose %Spark.Dsl.Entity{
    name: :resource,
    target: AshLua.EvalActions.Expose,
    args: [:resource],
    describe: "Exposes a specific set of actions on a resource to the Lua surface.",
    examples: [
      "resource MyApp.Posts.Post, actions: [:read, :create]"
    ],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc: "The resource module to expose."
      ],
      actions: [
        type: {:or, [{:in, [:all]}, {:list, :atom}]},
        default: :all,
        doc:
          "Which actions on the resource to expose. `:all` (default) exposes every public action; otherwise pass an atom list."
      ]
    ]
  }

  @eval_actions %Spark.Dsl.Section{
    name: :eval_actions,
    describe: """
    Configures the Lua surface exposed to the synthesized `:eval` and `:docs` actions.

    Prefer `labels` to expose mapped Lua actions declared on the domain with
    `lua do namespace ... action ..., labels: [...] end`. This keeps the eval
    surface tied to the same public Lua surface used everywhere else.

    The legacy `resource` entries remain supported for derived surfaces and
    fine-grained compatibility. When both `labels` and `resource` entries are
    configured, the resource/action list narrows the labelled action surface.
    """,
    examples: [
      """
      eval_actions do
        labels [:public]
      end
      """,
      """
      eval_actions do
        labels [:public]
        resource MyApp.Posts.Post, actions: [:read]
      end
      """
    ],
    schema: [
      labels: [
        type: {:list, :atom},
        default: [],
        doc:
          "Mapped action labels to expose to the eval/docs actions. An action is included when it has any requested label."
      ],
      eval_action_name: [
        type: :atom,
        default: :eval,
        doc: "Name of the synthesized eval action. Defaults to `:eval`."
      ],
      docs_action_name: [
        type: :atom,
        default: :docs,
        doc: "Name of the synthesized docs action. Defaults to `:docs`."
      ],
      otp_app: [
        type: :atom,
        doc:
          "OTP app to scan when building the manifest. Defaults to the agent resource's domain's `:otp_app`."
      ],
      forbidden_fields: [
        type: {:in, [:hide, :display]},
        default: :hide,
        doc:
          "How to render fields hidden by authorization in `:eval` results. `:hide` (default) strips them; `:display` renders them as the opaque marker `%{\"opaque\" => \"forbidden\"}` so the agent can tell a forbidden field apart from an absent one."
      ],
      entrypoints_resolver: [
        type: {:tuple, [:atom, :atom]},
        doc: """
        `{module, function}` resolving the runtime action entrypoints from the
        action context. The function receives the action implementation context
        map (actor, tenant, source_context, ...) and returns a list of
        `{resource, action}` tuples that filter the manifest for both the
        synthesized `:eval` and `:docs` actions. `nil` (the default) uses the
        statically configured surface (labels / `resource` entries); a resolver
        returning `nil` also falls back to the static surface, while `[]`
        deliberately exposes an empty surface (default-deny). Resolver-scoped
        surfaces bypass the eval-manifest cache — they are per-call.
        """
      ],
      lua_init: [
        type: {:tuple, [:atom, :atom]},
        doc: """
        `{module, function}` supplying the base `%Lua{}` VM the bindings are
        installed on. The function receives the action implementation context
        map and returns a `%Lua{}` (e.g. an application-hardened VM with
        dangerous stdlib entries removed). `nil` (the default) builds a plain
        `Lua.new/0`.
        """
      ],
      timeout_ms: [
        type: {:or, [:pos_integer, {:tuple, [:atom, :atom]}]},
        doc: """
        Execution timeout for the synthesized `:eval` action, in milliseconds.
        A positive integer is a static default; `{module, function}` receives
        the action implementation context and returns the default (used when
        the action's optional `timeout_ms` argument is not supplied).
        `nil` (the default) disables timeout enforcement entirely. On timeout
        the script task is brutally killed and the failure rides the action's
        typed `error` slot with code `lua_script_timeout` (message names the
        limit).
        """
      ]
    ],
    entities: [@expose]
  }

  @moduledoc """
  Resource extension that synthesizes `:eval` and `:docs` generic actions for
  driving an LLM agent against a scoped Lua surface.

  ```elixir
  defmodule MyApp.Agents.MCPActions do
    use Ash.Resource, extensions: [AshLua.EvalActions]

    eval_actions do
      labels [:public]
    end
  end
  ```

  The synthesized actions inherit the caller's actor / tenant / context. Both
  the script body and the documentation rendering are constrained to the
  configured action labels, and every Ash call inside the Lua script flows
  through the standard authorization machinery.

  The surface can additionally be scoped per call through
  `entrypoints_resolver`, hardened through the `lua_init` base-VM hook, and
  time-bounded through `timeout_ms` — see the section schema.
  """

  use Spark.Dsl.Extension,
    sections: [@eval_actions],
    transformers: [AshLua.EvalActions.Transformers.AddActions]
end
