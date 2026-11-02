{
  description = "redline.nvim: agent sessions, review comments, snapshots and inline diffs for Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      deps =
        pkgs: with pkgs; [
          neovim-unwrapped
          git
          stylua
          gnumake
        ];
    in
    {
      devShells = each (pkgs: {
        default = pkgs.mkShell { packages = deps pkgs; };
      });

      checks = each (pkgs: {
        default = pkgs.runCommand "redline-tests" { nativeBuildInputs = deps pkgs; } ''
          cp -r ${self} src
          chmod -R u+w src
          cd src
          export HOME=$TMPDIR
          make lint test
          touch $out
        '';
      });
    };
}
