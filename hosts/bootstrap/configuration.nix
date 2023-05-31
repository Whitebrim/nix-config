{ self, ... }:
{ lib, modulesPath, ... }: {
  imports = [
    (modulesPath + "/profiles/all-hardware.nix")
    self.nixosModules.base-system
    self.nixosModules.erase-your-darlings
    self.nixosModules.trust-admins
  ];

  system.stateVersion = lib.trivial.release;
  networking.hostName = "bootstrap";
  time.timeZone = "Europe/Moscow";

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;

  eraseYourDarlings = {
    bootDisk = "/dev/disk/by-partlabel/efi";
    rootDisk = "/dev/disk/by-partlabel/nix";
  };
}
