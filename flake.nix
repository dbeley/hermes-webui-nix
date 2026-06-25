{
  description = "NixOS and Home Manager modules for Hermes WebUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      llm-agents,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: builtins.listToAttrs (map (s: {
        name = s;
        value = f s;
      }) supportedSystems);
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          hermes-webui = pkgs.callPackage ./pkgs/hermes-webui.nix { };
          default = self.packages.${system}.hermes-webui;
        }
      );

      apps = forAllSystems (
        system:
        {
          hermes-webui = {
            type = "app";
            program = "${self.packages.${system}.hermes-webui}/bin/hermes-webui";
          };
          default = self.apps.${system}.hermes-webui;
        }
      );

      nixosModules = {
        default = import ./modules/nixos.nix { inherit llm-agents; };
        hermes-webui = import ./modules/nixos.nix { inherit llm-agents; };
      };

      homeModules = {
        default = import ./modules/home-manager.nix { inherit llm-agents; };
        hermes-webui = import ./modules/home-manager.nix { inherit llm-agents; };
      };

      overlays = {
        default = final: _prev: {
          hermes-webui = self.packages.${final.system}.hermes-webui;
        };
      };
    };
}
