# llm-agents' hermes-agent with its runtime dependency check relaxed.
#
# hermes-agent 0.22.2 pins `prompt-toolkit==3.0.52` and `markdown==3.10.2`,
# but current nixpkgs-unstable ships 3.0.53 and 3.10.3, so
# pythonRuntimeDepsCheckHook aborts the build. Both are patch-level bumps and
# API compatible; drop this override once llm-agents relaxes the pins itself.
{ llm-agents, pkgs }:
let
  hermesAgent = llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.hermes-agent;
in
hermesAgent.overridePythonAttrs (old: {
  pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [
    # Spelling must match the wheel metadata verbatim: the relax hook is a
    # sed on `Requires-Dist: <name>` and upstream writes `prompt_toolkit`.
    "prompt_toolkit"
    "markdown"
  ];
})
