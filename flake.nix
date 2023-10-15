{
  description = "zig-ha";

  inputs = {
    nixpkgs = {
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    bash = {
      url = "git+https://git.ocjtech.us/jeff/nixos-bash-prompt-builder.git";
    };
    make-shell = {
      url = "github:ursi/nix-make-shell";
    };
  };

  outputs = { self, nixpkgs, flake-utils, bash, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default =
          let
            project = "zig-datetime";
            prompt = (
              bash.build_ps1_prompt
                bash.ansi_normal_blue
                "${project} - ${bash.username}@${bash.hostname_short}: ${bash.current_working_directory}"
                "${project}:${bash.current_working_directory}"
            );
            make-shell = import inputs.make-shell {
              inherit system;
              pkgs = pkgs;
            };
          in
          make-shell {
            packages = [
              pkgs.zon2nix
              pkgs.zig_0_11
              pkgs.zls
            ];
            env = {
              PS1 = prompt;
            };
          };
      }
    );
}
