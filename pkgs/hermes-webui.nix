{
  lib,
  stdenv,
  python3,
  makeWrapper,
  fetchFromGitHub,
}:
let
  hermes-webui-python = python3.withPackages (ps: [
    ps.pyyaml
    ps.cryptography
  ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "hermes-webui";
  version = "0.52.492";

  src = fetchFromGitHub {
    owner = "nesquena";
    repo = "hermes-webui";
    rev = "v${finalAttrs.version}";
    hash = "sha256-gzpUmimWwucOJJEjkkquL5JWOoPjkkWhtVhw6UqFEOw=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    # Runtime tree mirrors upstream's own packaging (nix/packages.nix in the
    # upstream repo): bootstrap/server/mcp entry points, the managed-agent
    # startup shim imported by server.py, plus api/ and static/.
    install -d $out/bin $out/share/hermes-webui
    cp --no-preserve=mode -r api static $out/share/hermes-webui/
    cp --no-preserve=mode \
      bootstrap.py server.py managed_agent_startup.py mcp_server.py requirements.txt \
      $out/share/hermes-webui/

    # Upstream reads api/_version.py when there is no .git checkout (which is
    # always the case for a Nix store path) to report the running version.
    printf "__version__ = 'v%s'\n" "${finalAttrs.version}" \
      > $out/share/hermes-webui/api/_version.py

    makeWrapper ${hermes-webui-python}/bin/python3 $out/bin/hermes-webui \
      --add-flags "$out/share/hermes-webui/server.py" \
      --chdir "$out/share/hermes-webui"
    runHook postInstall
  '';

  meta = {
    description = "Hermes WebUI — web interface for Hermes Agent by Nous Research";
    homepage = "https://github.com/nesquena/hermes-webui";
    license = lib.licenses.mit;
    mainProgram = "hermes-webui";
    platforms = lib.platforms.linux;
  };
})
