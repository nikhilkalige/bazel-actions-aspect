load("//mylang/private:action_graph.bzl", "run_action_graph_aspect")
load("//mylang/private:aspects.bzl", "run_target_graph_aspect")

def _target_graph_impl(target, ctx):
    artifact_extractor = _make_intermediate_files_extractor(ctx)
    return run_target_graph_aspect(
        target,
        ctx,
        ctx.attr._output_group,
        artifact_extractor,
    )

def _action_graph_impl(target, ctx):
    artifact_extractor = _make_intermediate_files_extractor(ctx)
    return run_action_graph_aspect(
        target,
        ctx,
        ctx.attr._output_group,
        artifact_extractor,
    )

def _make_command_line_aspect(impl_func, doc):
    return aspect(
        doc = doc,
        implementation = impl_func,
        attr_aspects = ["*"],
        apply_to_generating_rules = True,
        attrs = {
            "_output_group": attr.string(default = "intermediate"),
            "targets": attr.string(),
            "extensions": attr.string(),
            "rule_types": attr.string(),
            "mnemonics": attr.string(),
        },
    )

def _make_rule_propagated_aspect(impl_func, doc, output_group = "", targets = [], extensions = [], rule_types = [], mnemonics = []):
    return aspect(
        implementation = impl_func,
        doc = doc,
        attr_aspects = ["*"],
        apply_to_generating_rules = True,
        attrs = {
            "_output_group": attr.string(default = output_group),
            "_targets": attr.string_list(default = targets),
            "_extensions": attr.string_list(default = extensions),
            "_rule_types": attr.string_list(default = rule_types),
            "_mnemonics": attr.string_list(default = mnemonics),
        },
    )

fast_aspect = _make_command_line_aspect(
    impl_func = _target_graph_impl,
    doc = r"""
Command-line aspect for accessing intermediate artifacts from the build.

Note that this propagates action artifacts for actions that may be skipped in a
default build. In some cases this can result in executing actions with an invalid
configuration causing a build failure. For a more precise but resource-intensive
approach use precise_aspect.

Example for extraction '.crc' files:
  bazel build //mytargets --output_groups=intermediate \
    --aspects=//build/bazel:utils/intermediate_files.bzl%fast_aspect \
    --aspects_parameters=extensions=crc
""",
)

precise_aspect = _make_command_line_aspect(
    impl_func = _action_graph_impl,
    doc = r"""
Command-line aspect for accessing intermediate artifacts from the build, e.g. to
output .o and .a files from cc_library_rules:
  bazel build //mytargets --output_groups=intermediate \
    --aspects=//build/bazel:utils/intermediate_files.bzl%precise_aspect \
    --aspects_parameters=extensions=o,a \
    --aspects_parameters=rule_types=cc_library
""",
)

linkmap_aspect = _make_rule_propagated_aspect(
    impl_func = _action_graph_impl,
    doc = """
Aspect for accessing .map files produced by the build. Requires that
'generate_linkmap' feature is enabled, either through the command-line flag
(--features=generate_linkmap) or via transition, see extract_linkmap rule.
""",
    output_group = "linkmap_files",
    extensions = ["map"],
    mnemonics = ["CppLink"],
)

def _generate_linkmap_transition_impl(settings, _attr):
    features = settings.get("//command_line_option:features", [])
    if "generate_linkmap" not in features:
        features.append("generate_linkmap")
    return [
        {"//command_line_option:features": features},
    ]

generate_linkmap_transition = transition(
    implementation = _generate_linkmap_transition_impl,
    inputs = ["//command_line_option:features"],
    outputs = ["//command_line_option:features"],
)

def _forward_output_group_impl(ctx):
    output_group = ctx.attr.output_group
    transitive_outs = []
    for dep in ctx.attr.deps:
        dep_outs = getattr(dep[OutputGroupInfo], output_group, None)
        if dep_outs:
            transitive_outs.append(dep_outs)
    return DefaultInfo(files = depset(transitive = transitive_outs))

extract_linkmap = rule(
    implementation = _forward_output_group_impl,
    attrs = {
        "deps": attr.label_list(
            aspects = [linkmap_aspect],
            cfg = generate_linkmap_transition,
        ),
        "output_group": attr.string(default = "linkmap_files"),
    },
)

def _make_intermediate_files_extractor(ctx):
    # Check ctx.attr.<name> and ctx.attr._<name> for attributes, allows for
    # shared implementation for both command-line and rule-propagated aspects
    def _attr(name):
        val = getattr(ctx.attr, name, getattr(ctx.attr, "_" + name, ""))
        if val and type(val) == type(""):
            return [x.strip() for x in val.split(",")]
        return val

    targets = _attr("targets")
    extensions = _attr("extensions")
    if extensions:
        # Normalize extensions for multi-part extensions support, e.g. *.dwo_map.json
        extensions = [".{}".format(ext.lstrip(".")) for ext in extensions]
    rule_types = _attr("rule_types")
    mnemonics = _attr("mnemonics")
    if not any([targets, extensions, rule_types, mnemonics]):
        fail("At least one of {targets, extensions, rule_types, mnemonics} must be set")

    exact_targets, packages, subpackages = [], [], []
    if targets:
        for target in targets:
            if target.endswith(":*"):
                packages.append(Label(target[:-2]).package)
            elif target.endswith("..."):
                subpackages.append(Label(target[:-4]).package)
            else:
                tgt = Label(target)
                exact_targets.append((tgt.package, tgt.name))

    def artifact_extractor(target, ctx):
        if targets:
            if exact_targets and (target.label.package, target.label.name) not in exact_targets:
                return {}
            if packages and not any([target.label.package == p for p in packages]):
                return {}
            if subpackages and not any([target.label.package.startswith(p) for p in subpackages]):
                return {}

        if rule_types and ctx.rule.kind not in rule_types:
            return {}
        outputs = {}
        for action in target.actions:
            if mnemonics and action.mnemonic not in mnemonics:
                continue
            for f in action.outputs.to_list():
                if not extensions or any([f.basename.endswith(ext) for ext in extensions]):
                    outputs.setdefault(action, []).append(f)
        return outputs

    return artifact_extractor

# Note: These debugging files are generated by actions that are not mandatory
# for the build which means that the actions will be pruned by the action graph
# aspect implementation.
gdb_files_aspect = _make_rule_propagated_aspect(
    impl_func = _target_graph_impl,
    doc = "Propagates debug files from dependencies to an output group of the top-level target",
    output_group = "gdb_files",
    extensions = ["dwo", "dwp", "dwo_map.json"],
)
