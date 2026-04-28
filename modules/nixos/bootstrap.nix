{ lib, ... }:

{
  options.cjv.bootstrap.initialHashedPassword = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Temporary hashed password for bootstrapping a new system before age
      secrets can be decrypted. Leave null for normal age-backed passwords.
    '';
  };
}
