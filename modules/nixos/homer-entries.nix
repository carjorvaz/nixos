{ lib, config, ... }:

let
  cfg = config.services.homer;

  entrySubmodule = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    options = {
      name = lib.mkOption { type = lib.types.str; };
      url = lib.mkOption { type = lib.types.str; };
      group = lib.mkOption {
        type = lib.types.str;
        default = "services";
        description = "Group key for categorizing the entry on the dashboard.";
      };
    };
  };

  # Controls display order on the dashboard; unlisted groups appear at the end.
  groupOrder = [
    "arr"
    "media"
    "ai"
    "home"
    "productivity"
    "services"
  ];

  groupLabels = {
    arr = "Arr!";
    media = "Media";
    ai = "AI";
    home = "Home";
    productivity = "Productivity";
    services = "Services";
  };

  grouped = lib.groupBy (e: e.group) cfg.entries;
  knownGroups = builtins.filter (g: builtins.hasAttr g grouped) groupOrder;
  unknownGroups = builtins.filter
    (g: !(builtins.elem g groupOrder))
    (builtins.attrNames grouped);
  orderedGroups = knownGroups ++ unknownGroups;

  # Strip the internal "group" key and any empty-string fields before serialization.
  cleanEntry = e: lib.filterAttrs (n: v: n != "group" && v != "") e;

  sortedItems = items:
    lib.sort (a: b: a.name < b.name) (map cleanEntry items);

  toHomerServices = map (key: {
    name = groupLabels.${key} or key;
    items = sortedItems grouped.${key};
  }) orderedGroups;
in
{
  options.services.homer.entries = lib.mkOption {
    type = lib.types.listOf entrySubmodule;
    default = [ ];
    description = "Service entries for the Homer dashboard, auto-collected from profiles.";
  };

  config = lib.mkIf cfg.enable {
    services.homer.settings.services = toHomerServices;
  };
}
