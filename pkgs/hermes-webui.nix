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
  version = "0.51.653";

  src = fetchFromGitHub {
    owner = "nesquena";
    repo = "hermes-webui";
    rev = "v${finalAttrs.version}";
    hash = "sha256-AjEyT6jms7gx11XHG7MVFY3IQq28Wvwm1fT3OVkxPtM=";
  };

  nativeBuildInputs = [ makeWrapper ];

  patchPhase = ''
    # Fix: the _approval_notify_cb in streaming.py calls submit_gateway_pending_mirror
    # which creates a "gateway mirror" entry in the pending queue with _GATEWAY_MIRROR_FLAG
    # and a stabilised token. When the user clicks approve, _handle_approval_respond's
    # _gateway_pending_approval_without_run_id() sees the mirror, finds no active
    # gateway run to relay to, and returns HTTP 409 with:
    #   "Gateway approval could not be relayed because the active run is unavailable."
    #
    # The old behaviour (no mirroring) was restored: the callback only pushes the
    # approval via SSE, which is sufficient for the in-process agent path (legacy mode).
    sed -i '/if _submit_pending_for_polling is not None:/,/logger.warning(/d' api/streaming.py
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/{bin,share/hermes-webui}
    cp -r api static server.py bootstrap.py requirements.txt $out/share/hermes-webui/
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
