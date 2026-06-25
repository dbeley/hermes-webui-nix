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
    # Fix: approval notify callback must call submit_pending() to add a
    # non-mirror entry to the _pending queue. Without this, _pending only
    # gets "gateway mirror" entries (from reconcile_gateway_pending_mirror_locked)
    # which have _GATEWAY_MIRROR_FLAG set, causing _handle_approval_respond to
    # return HTTP 409 (gateway_run_unavailable) for every local approval.
    #
    # Ref: https://github.com/dbeley/hermes-webui-nix/issues

    # Add submit_pending import alongside existing route_approvals imports
    sed -i '/_approval_sse_notify_locked as _approval_sse_notify_locked,/a\                    submit_pending as _submit_webui_pending,' api/streaming.py

    # Add submit_pending call before put('approval', ...) in the notify callback
    sed -i '/def _approval_notify_cb(approval_data):/a\                _submit_webui_pending(session_id, approval_data)' api/streaming.py
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
