load("@bazel_skylib//lib:types.bzl", "types")

_TARGET_TYPE = "Target"

def is_target(t):
    return type(t) == _TARGET_TYPE

def visit_dict_type(attr, provider):
    # Only need to consider dict[Target][str] and dict[str][Target]
    return (
        visit_list_type(attr.keys(), provider) or
        visit_list_type(attr.values(), provider)
    )

def visit_list_type(attr, provider):
    for value in attr:
        if not is_target(value):
            return []
        break
    return [value[provider] for value in attr if provider in value]

def visit_target_type(target, provider):
    if provider in target:
        return [target[provider]]
    return []

def aspect_traverse_target_and_collect_depsets(
        target,
        ctx,
        *,
        aspect_provider,
        attributes = None,  # Provided attr names are mandatory, if None use all attrs
        merge_aspect_providers = None):
    collected_aspect_providers = []
    target_attributes = dir(ctx.rule.attr)
    for attr_name in target_attributes:
        if attributes != None and attr_name not in attributes:
            continue
        attr = getattr(ctx.rule.attr, attr_name)
        if attr == None:
            continue
        elif types.is_dict(attr):
            collected_aspect_providers.extend(visit_dict_type(attr, aspect_provider))
        elif types.is_list(attr):
            collected_aspect_providers.extend(visit_list_type(attr, aspect_provider))
        elif is_target(attr):
            collected_aspect_providers.extend(visit_target_type(attr, aspect_provider))
        elif attr != None and attributes != None:
            fail("Unhandled attribute type", attr, attr_name, type(attr), target.label)

    if merge_aspect_providers == None:
        return collected_aspect_providers
    else:
        return merge_aspect_providers(collected_aspect_providers)

def run_target_graph_aspect(target, ctx, output_group, artifact_extractor):
    """Shared implementation for aspects that walk the target graph.

    Note that this propagates action artifacts for actions that may be skipped in a
    default build. In some cases this can result in executing actions with an invalid
    configuration causing a build failure. For a more precise (but slow and expensive)
    approach see action_graph_aspects.bzl.

    Args:
      target: target forwarded directly from aspect impl
      ctx: ctx forwarded directly from aspect impl
      output_group: str, OutputGroupInfo.<output_group> will be populated with
        the direct and transitive artifacts for the given target
      artifact_extractor: function(target: <target>, ctx: <ctx>) -> dict[Action][File]
        function for visiting actions of the given target and conditionally returning
        the artifacts produced by each action
    Returns:
      List of providers with OutputGroupInfo conditionally populated
    """
    deps_infos = aspect_traverse_target_and_collect_depsets(
        target,
        ctx,
        aspect_provider = OutputGroupInfo,
    )
    action_to_artifacts = artifact_extractor(target, ctx)
    if not deps_infos and not action_to_artifacts:
        return []

    direct = [x for artifacts in action_to_artifacts.values() for x in artifacts]
    transitive = [getattr(out_group_info, output_group, depset()) for out_group_info in deps_infos]
    return [
        OutputGroupInfo(**{
            output_group: depset(direct, transitive = transitive),
        }),
    ]
