{
  description = "Dev VM tool profile";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.buildEnv {
            name = "devenv-tools";
            paths = with pkgs; [
              neovim
              fzf
              zoxide
              tree-sitter
              ripgrep

              fnm

              asdf-vm
              awscli2
              kubectl
              kustomize
              kubernetes-helm
              helmfile
              k3d
            ];
          };
        }
      );
    };
}
