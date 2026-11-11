{
  config,
  lib,
  pkgs,
  ...
}:

# Persist the Strata engine's in-RAM counters and turn the crude ones into
# warnings.  The engine on tiberius listens only on loopback (127.0.0.1:8081;
# the lease proxy owns the two client doors, 8080/8090 - see
# profiles/nixos/strata.nix), and GET /metrics returns JSON: engine (model,
# expert_slots, vram_free_mib, ...), live (state reading/generating/idle,
# tok_s, tok_s_mean, ...), requests (last 12), conversation_cache
# (parks/restores/evictions), totals, hardware (gpu_temp/gpu_power/...) and
# history.  `history` is only ~60 s of RAM and is un-scraped; the roadmap asks
# for a 15 s scraper because of exactly that
# (docs/exec-plans/active/strata-tuning-next.md, "Per-window telemetry
# counters" and "Measurement caveats": drift detection needs a 15 s scraper).
# The human record is already under /persist/strata/strata-<model>.log (the
# module's services.logrotate.settings.strata keeps 4 x 256 MiB of it); these
# date-named JSONL files are the machine-readable series that log cannot give
# at 15 s resolution.
#
# Measured on the deployed 0.1.56 engine, 2026-11-04: expert_slots 7859,
# vram_free_mib 777 (the 262144 / int8 / 2048 MiB conversation-cache regime),
# conversation_cache slots 4, and totals/requests only advancing on real
# traffic.  The scraper stores counters, never prompts: the fields below are
# public-safe counters, no API keys and no request payloads.
#
# Evidence for the alert thresholds:
#   * decode spread ~2-3% between 3 counterbalanced runs and 6.4% base spread
#     on the live-shaped cell (/tmp/strata-tune/campaign-results.md); 0.70x a
#     20-sample median is a real cliff, not measurement noise.
#   * GPU under prefill sits at 61-72 C, with an 89 C operational / 91 C
#     slowdown limit (/tmp/strata-tune/box-audit.md, "thermal"); 82 C leaves
#     margin before throttling but is above any observed steady state.
#   * the conversation cache is RAM-admission-gated: the current engine log
#     already holds 893 `skip parking` admissions and 493 evictions
#     (/tmp/strata-tune/box-audit.md, "Corrections"), so a burst of evictions
#     is the warning sign for the 8 GB box, not a normal steady state.
#
# The unit is deliberately not ordered after tiberius-strata.service: an
# engine that is down is itself a fact worth recording ({"state":"down"}), and
# the failure counter is what distinguishes a restart from a real outage.
let
  cfg = config.services.tiberius-strata-telemetry;

  telemetry = pkgs.writeShellScript "tiberius-strata-telemetry" ''
    set -u
    export LC_ALL=C

    data_dir=$STRATA_TELEMETRY_DATA_DIR
    metrics_url=$STRATA_TELEMETRY_URL
    retention_days=$STRATA_TELEMETRY_RETENTION_DAYS
    tag=strata-telemetry

    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    day=$(date -u +%F)
    out_file=$data_dir/$day.jsonl

    # root owns /persist/strata (the engine's stateDir); the module creates
    # the directory at activation via tmpfiles, and this mkdir covers a manual
    # `systemctl start` before that ran.
    mkdir -p "$data_dir" || exit 1

    # Retention is in-service, not logrotate: these are date-named files, and
    # logrotate matches *.jsonl and would rename today's open file (and the
    # 14 older ones) on its daily run, splitting a day across .1 files.  A new
    # day's first scrape deletes files whose date is older than the cutoff, so
    # 14 daily files is the steady state.  Compression is not worth a gzip
    # dependency for ~1-2 MB/day of text counters.
    if [ ! -e "$out_file" ]; then
      cutoff_day=$(date -u -d "$retention_days days ago" +%F)
      for old in "$data_dir"/*.jsonl; do
        [ -e "$old" ] || continue
        base=$(basename "$old")
        if [[ "$base" < "$cutoff_day.jsonl" ]]; then
          rm -f -- "$old"
        fi
      done
    fi

    # Consecutive-failure bookkeeping: warn exactly when the second scrape in
    # a row fails, not on every 15 s retry.  A recovery is one daemon.info
    # line.  These dotfiles live beside the JSONL and never match *.jsonl.
    fail_file=$data_dir/.consecutive-failures
    fails=0
    if [ -r "$fail_file" ]; then
      fails=$(cat "$fail_file" 2>/dev/null) || fails=0
      case "$fails" in
        "" | *[!0-9]*) fails=0 ;;
      esac
    fi

    emit_down() {
      # Exactly one line, and only the timestamp plus the state: a down
      # scrape must not pretend to know counters.  O_APPEND + one small write
      # means a reader never sees a half line.
      printf '{"ts":"%s","state":"down"}\n' "$stamp" >> "$out_file"
      fails=$((fails + 1))
      printf '%s\n' "$fails" > "$fail_file"
      if [ "$fails" -eq 2 ]; then
        logger -t "$tag" -p daemon.warning "strata /metrics unreachable for two consecutive scrapes (engine down, loading, or loopback :8081 not answering); writing state=down until it returns"
      fi
      exit 0
    }

    # -f makes an HTTP error a failure, --max-time bounds the oneshot; stderr
    # stays silent so a down engine does not produce a journal line per scrape.
    if ! raw=$(curl -fsS --connect-timeout 2 --max-time 5 "$metrics_url" 2>/dev/null); then
      emit_down
    fi

    # One compact JSON object per scrape.  Only counters are copied; the
    # requests[] array (prompt/output text) is deliberately not touched.
    # Null engine fields stay null rather than being invented here.
    if ! line=$(printf '%s' "$raw" | jq -c --arg ts "$stamp" '{
          ts: $ts,
          state: (.live.state // "unknown"),
          tok_s: (.live.tok_s // null),
          tok_s_mean: (.live.tok_s_mean // null),
          expert_slots: (.engine.expert_slots // null),
          vram_free_mib: (.engine.vram_free_mib // null),
          parks: (.conversation_cache.parks // null),
          restores: (.conversation_cache.restores // null),
          evictions: (.conversation_cache.evictions // null),
          gpu_temp: (.hardware.gpu_temp // null),
          gpu_power: (.hardware.gpu_power // null),
          requests: (.totals.requests // null),
          output_tokens: (.totals.output_tokens // null)
        }' 2>/dev/null) || [ -z "$line" ]; then
      emit_down
    fi

    printf '%s\n' "$line" >> "$out_file"

    if [ "$fails" -gt 0 ]; then
      # Only a warned outage (>= 2) earns a recovery line; a single blip is
      # exactly the transient case that must stay out of the journal.
      if [ "$fails" -ge 2 ]; then
        logger -t "$tag" -p daemon.info "strata /metrics recovered after $fails consecutive failed scrapes"
      fi
      printf '0\n' > "$fail_file"
    fi

    # Pull the few fields the warning rules need out of the line we just wrote
    # (one jq call; @tsv keeps empty fields empty).
    fields=$(printf '%s\n' "$line" | jq -r '[.state, (.tok_s_mean // ""), (.evictions // ""), (.gpu_temp // "")] | @tsv')
    IFS=$'\t' read -r state mean evictions gpu_temp <<< "$fields"

    # Decode drift.  The engine only fills tok_s/tok_s_mean while it is
    # generating (serve/server.py: state "generating" is the answering state;
    # "reading" is prefill), so samples are taken only then.  The ring keeps
    # the last 20 answering samples (~5 min at the default 15 s interval);
    # warn on a 30% drop, and clear the one-shot flag only after recovering to
    # 80% of the median, so a slow minute cannot produce a warning per scrape.
    samples_file=$data_dir/.tok-s-samples
    low_file=$data_dir/.decode-low
    if [ "$state" = "generating" ] && awk -v v="$mean" 'BEGIN { exit !(v > 0) }'; then
      prev_count=0
      if [ -r "$samples_file" ]; then
        prev_count=$(wc -l < "$samples_file")
      fi
      if [ "$prev_count" -ge 20 ]; then
        median=$(sort -n "$samples_file" | awk '{ v[NR] = $1 } END { if (NR % 2) print v[(NR + 1) / 2]; else printf "%.2f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }')
        if awk -v cur="$mean" -v med="$median" 'BEGIN { exit !(med > 0 && cur < 0.70 * med) }'; then
          if [ ! -e "$low_file" ]; then
            logger -t "$tag" -p daemon.warning "strata decode drift: live.tok_s_mean=$mean is below 70% of the 20-answering-sample median $median (state=generating); check VRAM pressure (/metrics vram_free_mib) and the conversation cache before blaming the model - campaign decode spread is 2-3% (/tmp/strata-tune/campaign-results.md)"
            : > "$low_file"
          fi
        else
          if [ -e "$low_file" ] && awk -v cur="$mean" -v med="$median" 'BEGIN { exit !(cur >= 0.80 * med) }'; then
            rm -f "$low_file"
          fi
        fi
      fi
      printf '%s\n' "$mean" >> "$samples_file"
      tail -n 20 "$samples_file" > "$samples_file.tmp" && mv "$samples_file.tmp" "$samples_file"
    fi

    # Conversation-cache evictions over a five-minute window.  Samples are
    # timestamped, so the window is 300 s of wall clock regardless of
    # OnUnitActiveSec drift; a counter reset (engine restart) makes the delta
    # negative and is ignored.  At most one warning per five minutes, because
    # a sustained RAM-admission problem would otherwise warn every scrape.
    ev_file=$data_dir/.evictions-samples
    ev_warn_file=$data_dir/.last-eviction-warning
    if [ -n "$evictions" ]; then
      now=$(date +%s)
      printf '%s %s\n' "$now" "$evictions" >> "$ev_file"
      awk -v cutoff=$((now - 1800)) '$1 >= cutoff' "$ev_file" > "$ev_file.tmp" && mv "$ev_file.tmp" "$ev_file"
      delta=$(awk -v now="$now" -v win=300 -v cur="$evictions" '{ if ($1 <= now - win) { base = $2; found = 1 } } END { if (found) print cur - base }' "$ev_file")
      if [ -n "$delta" ] && [ "$delta" -gt 5 ]; then
        last_warn=0
        if [ -r "$ev_warn_file" ]; then
          last_warn=$(cat "$ev_warn_file" 2>/dev/null) || last_warn=0
          case "$last_warn" in
            "" | *[!0-9]*) last_warn=0 ;;
          esac
        fi
        if [ $((now - last_warn)) -ge 300 ]; then
          logger -t "$tag" -p daemon.warning "strata conversation-cache evictions +$delta in the last 5 min (RAM admission pressure; see /tmp/strata-tune/box-audit.md - 893 skip-parking admissions and 493 evictions in the current log)"
          printf '%s\n' "$now" > "$ev_warn_file"
        fi
      fi
    fi

    # GPU temperature: warn on the 82 C crossing and re-arm only after it has
    # cooled below 78 C, so a fan ramp at the threshold does not repeat.  Box
    # audit: 61-72 C under prefill, 89 C operational / 91 C slowdown limit.
    if [ -n "$gpu_temp" ]; then
      hot_file=$data_dir/.gpu-hot
      if awk -v t="$gpu_temp" 'BEGIN { exit !(t >= 82) }'; then
        if [ ! -e "$hot_file" ]; then
          logger -t "$tag" -p daemon.warning "strata GPU temp $gpu_temp C is at or above 82 C (61-72 C under prefill; operational limit 89 C, slowdown 91 C - /tmp/strata-tune/box-audit.md); check airflow/fan before a long prefill"
          : > "$hot_file"
        fi
      else
        if [ -e "$hot_file" ] && awk -v t="$gpu_temp" 'BEGIN { exit !(t < 78) }'; then
          rm -f "$hot_file"
        fi
      fi
    fi

    exit 0
  '';
in
{
  options.services.tiberius-strata-telemetry = {
    enable = lib.mkEnableOption "persisting the tiberius Strata /metrics counters and warning on engine drift";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/persist/strata/metrics";
      description = ''
        Directory for the daily `YYYY-MM-DD.jsonl` files and the scraper's
        dotfile state (failure count, decode samples, hysteresis flags).  It
        lives under the engine's persistent stateDir (`/persist/strata`), the
        only host filesystem that survives this box's root rollback.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15s";
      description = ''
        systemd time span between scrapes (`OnUnitActiveSec`).  The roadmap
        asks for 15 s: `/metrics` history is ~60 s in RAM and un-scraped, and
        20 samples at 15 s is the five-minute decode median the drift rule
        uses.  AccuracySec is 1 s so a 15 s timer is not coalesced by the
        systemd default of one minute.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ReadWritePaths needs the path to exist; tmpfiles creates it before the
    # timer's first 60 s activation and gives it a stable owner/mode.
    systemd = {
      tmpfiles.rules = [
        "d ${toString cfg.dataDir} 0755 root root -"
      ];

      services.tiberius-strata-telemetry = {
        description = "Scrape tiberius Strata /metrics into /persist and warn on drift";
        # Not after/requires tiberius-strata.service on purpose: engine-down is
        # recorded as {"state":"down"} rather than turning the timer into a
        # cascade of failed units.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = telemetry;
          # One curl (max 5 s) plus local jq/awk; a hung scrape must not hold
          # the next timer tick.
          TimeoutStartSec = "30s";
          # The script itself exits 0 on a down engine, so a failed unit means a
          # real bug (bad path, missing tool), not a transient outage.
          #
          # Root rationale: the output belongs in /persist/strata/metrics, which
          # is root-owned and outside /var/lib, so StateDirectory (and its
          # managed /var/lib/<name>) is the wrong tool here.  The unit writes
          # only that directory; ProtectSystem=strict + ReadWritePaths pins it.
          UMask = "0027";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ReadWritePaths = [ (toString cfg.dataDir) ];
          # curl needs loopback TCP; logger writes to /dev/log (AF_UNIX).
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
        # curl/jq/awk/logger/coreutils only; all from the store, no PATH
        # assumptions about the host's /run/current-system/sw.
        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
          pkgs.gawk
          pkgs.util-linux
        ];
        environment = {
          STRATA_TELEMETRY_DATA_DIR = toString cfg.dataDir;
          # The engine's own upstream port, not a lease-proxy door: the proxy is
          # a client-facing process and may be restarted independently.
          STRATA_TELEMETRY_URL = "http://127.0.0.1:8081/metrics";
          STRATA_TELEMETRY_RETENTION_DAYS = "14";
        };
      };

      timers.tiberius-strata-telemetry = {
        description = "15 s scrape of the tiberius Strata /metrics endpoint";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Give the engine's loader a minute after boot; if it is still loading,
          # the down lines are honest and the second one (30 s later) is the
          # warning that the engine did not come back.
          OnBootSec = "60s";
          OnUnitActiveSec = cfg.interval;
          AccuracySec = "1s";
          Unit = "tiberius-strata-telemetry.service";
        };
      };
    };
  };
}
