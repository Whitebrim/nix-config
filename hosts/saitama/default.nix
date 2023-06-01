{ inputs, ... }@args: {
  flake.nixosConfigurations.saitama = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ({ nixpkgs.hostPlatform.system = "x86_64-linux"; })
      (import ./configuration.nix args)
    ];
  };
}