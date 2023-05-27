{ self, ... }:
{ lib, pkgs, modulesPath, ... }:
let
  # NB we do not use writeShellApplication since shellcheck fails to cross-compile.
  setup-disk = pkgs.writeScriptBin "setup-disk" (builtins.readFile ./setup-disk.sh);
in
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    self.nixosModules.nix-flakes
  ];

  networking.hostName = "installer";

  environment.systemPackages = [ setup-disk ];

  services.openssh = {
    enable = true;
    startWhenNeeded = true;
    hostKeys = [{
      path = "/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    extraConfig = ''
      LoginGraceTime 15s
      RekeyLimit default 30m
    '';
  };

  users.users.nixos.openssh.authorizedKeys.keys = self.lib.sshKeys.tie;
}
