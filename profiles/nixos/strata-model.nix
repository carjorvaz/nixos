# The public name of the model the Strata lane serves, in one place.
#
# The serve layer derives its drafting set from this string
# (strata_control/drafting.py: set_of(model_name)), so the name carries the
# pack the way upstream's setup writes a set -
# "qwen3.8-flash-next-<family>-<pack>" - and changes when the pack changes.
# `general` is the lane id (profiles/nixos/strata.nix).
#
# No alias carries an older name: the serve layer answers a request that names
# anything else (serve/server.py, model_for: "Other names are still served"), so
# an alias would only keep a name that describes a pack the lane no longer
# loads.  Record the old spelling in the commit/decision note instead.
{
  general = "qwen3.8-flash-next-unsloth-ud-iq2_xs";
}
