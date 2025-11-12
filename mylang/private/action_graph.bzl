load("//mylang/private:aspects.bzl", "aspect_traverse_target_and_collect_depsets")

TargetInfo = provider(
    """Provider for """,
    fields = {
        "action_artifacts": """depset[struct<action=Action, artifacts=depset[File]>],
            data structure that from the current target contains all actions (direct
            and transitive) that produce any relevant artifacts. For such actions
            `artifacts` contains all direct and transitive artifacts of the action,
            which prevents the need to continue walking the dependency graph when
            collecting outputs.
            """,
        "dependent_actions": """depset[Action], contains all actions that depend on
            but do not directly produce relevant artifacts. This reduces the memory
            footprint but requires continuing to search the graph to find the
            relevant dependency actions.
            """,
    },
)

# Starlark disallows infinite loops, 1000 iterations is an arbitrary choice
# but dependency trees are not typically anywhere near that deep.
_MAX_ITERATIONS = 1000

def run_action_graph_aspect(target, ctx, output_group, artifact_extractor, target_provider = TargetInfo):
    """Shared implementation for aspects that walk the action graph.

    The aspect implementation visits targets in the dependency tree of requested targets.
    Leaf nodes execute first and data is passed up the tree using a provider. When
    visiting a given target we can only see the providers of direct dependencies, and we
    cannot be sure which actions will be executed as a part of the build until we visit
    the top-level targets. This necessitates propagating all relevant actions and the
    artifacts they produce up the dependency tree, top-level targets then determine which
    actions are needed to build its default outputs and return the artifacts for those
    needed actions in OutputGroupInfo.

    Args:
      target: target forwarded directly from aspect impl
      ctx: ctx forwarded directly from aspect impl
      output_group: str, OutputGroupInfo.<output_group> will be populated with
        the direct and transitive artifacts for the given target
      artifact_extractor: function(target: <target>, ctx: <ctx>) -> dict[Action][File]
        function for visiting actions of the given target and conditionally returning
        the artifacts produced by each action
      target_provider: Provider to construct and propagate, the type of the provider should be the
        same as TargetInfo. This is necessary to work around provider collisions
    Returns:
      List of providers with TargetInfo and OutputGroupInfo conditionally populated
    """
    deps_info = aspect_traverse_target_and_collect_depsets(
        target,
        ctx,
        aspect_provider = target_provider,
        merge_aspect_providers = _merge_action_artifacts,
    )

    pending_action_to_artifacts = artifact_extractor(target, ctx)

    if not pending_action_to_artifacts and not deps_info.action_artifacts:
        return []

    # Initially populated with transitive actions, current target's
    # actions are added once all artifacts are accounted for
    action_to_artifacts = {
        x.action: x.artifacts
        for x in deps_info.action_artifacts.to_list()
    }
    file_to_action = _file_to_generating_action_map(
        action_to_artifacts.keys() + deps_info.dependent_actions.to_list(),
    )

    # Need to ensure that we process dependency actions first
    topo_actions = _topological_sort_actions(target.actions)
    action_artifacts, dependent_actions = [], []
    for action in topo_actions[::-1]:
        direct = pending_action_to_artifacts.pop(action, None)
        inputs = action.inputs.to_list()
        if direct:
            # Action produces a relevant artifact
            transitive = _collect_transitive_artifacts(
                inputs,
                action_to_artifacts,
                file_to_action,
            )
            artifacts = depset(direct, transitive = transitive)
            action_to_artifacts[action] = artifacts
            action_artifacts.append(struct(action = action, artifacts = artifacts))
        elif any([f in file_to_action for f in inputs]):
            # Action depends on a relevant artifact
            dependent_actions.append(action)
        else:
            # Action is irrelevant, no need to include in graph
            continue

        for f in action.outputs.to_list():
            file_to_action[f] = action

    providers = [target_provider(
        action_artifacts = depset(
            action_artifacts,
            transitive = [deps_info.action_artifacts],
        ),
        dependent_actions = depset(
            dependent_actions,
            transitive = [deps_info.dependent_actions],
        ),
    )]

    output_artifacts = _collect_transitive_artifacts(
        _target_outputs(target),
        action_to_artifacts,
        file_to_action,
    )
    if output_artifacts:
        providers.append(
            OutputGroupInfo(
                **{output_group: depset(transitive = output_artifacts)}
            ),
        )
    return providers

def _collect_transitive_artifacts(needed_files, action_to_artifacts, file_to_action):
    """Returns artifacts produced by all actions that are run to provide needed_files."""
    output_artifacts = []
    for i in range(_MAX_ITERATIONS):
        relevant_actions = {}
        for file in needed_files:
            if file in file_to_action:
                action = file_to_action[file]
                relevant_actions[action] = action_to_artifacts.get(action)

        needed_files.clear()
        for action, artifacts in relevant_actions.items():
            if artifacts:
                output_artifacts.append(artifacts)
            else:
                needed_files.extend(_generated_inputs(action))

        if not needed_files:
            break

        if i == _MAX_ITERATIONS - 1:
            fail("[ERROR] Action dependency graph is too deep")

    return output_artifacts

def _merge_action_artifacts(target_infos):
    action_artifacts = [info.action_artifacts for info in target_infos]
    dependent_actions = [info.dependent_actions for info in target_infos]
    return TargetInfo(
        action_artifacts = depset(transitive = action_artifacts),
        dependent_actions = depset(transitive = dependent_actions),
    )

def _topological_sort_actions(actions):
    """Returns sorted list of actions with dependents before dependencies."""
    depsets = {a: depset([a]) for a in actions}
    file_to_action = _file_to_generating_action_map(actions)
    for action in actions:
        dep_actions = [
            file_to_action[f]
            for f in action.inputs.to_list()
            if f in file_to_action
        ]
        if dep_actions:
            dep_depsets = [depsets[a] for a in dep_actions]
            depsets[action] = depset([action], transitive = dep_depsets)

    topo_actions = depset(transitive = depsets.values(), order = "topological")
    return topo_actions.to_list()

def _target_outputs(tgt):
    needed_files = depset(transitive = [tgt.files, tgt.default_runfiles.files, tgt.data_runfiles.files]).to_list()
    if tgt.files_to_run and tgt.files_to_run.executable:
        needed_files.append(tgt.files_to_run.executable)
    return needed_files

def _generated_inputs(action):
    return [f for f in action.inputs.to_list() if not f.is_source]

def _file_to_generating_action_map(actions):
    return {f: a for a in actions for f in a.outputs.to_list()}
