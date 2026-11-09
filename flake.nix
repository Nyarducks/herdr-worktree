{
  description = "herdr-worktree: worktree-driven multi-repository development";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Development-only tools. The runtime requirements (bash, git, gh,
      # jq, herdr, Node.js for plugins) are installed per README
      # "Requirements", not here; bats runs the shell tests, and Node.js is
      # here too so plugin checks (npm run check) run in this shell.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            shellcheck
            bats
            nodejs_24
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
