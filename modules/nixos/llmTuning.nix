{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cjv.llmTuning;
in
{
  options.cjv.llmTuning = {
    enable = lib.mkEnableOption "LLM CPU containment and observability tuning";

    housekeepingCpus = lib.mkOption {
      type = lib.types.str;
      default = "0-1";
      example = "0-1";
      description = "CPU list reserved for system services, IRQs, and background work.";
    };

    workloadCpus = lib.mkOption {
      type = lib.types.str;
      default = "2-5";
      example = "2-5";
      description = "CPU list reserved for latency-sensitive LLM workloads.";
    };

    workqueueCpuMask = lib.mkOption {
      type = lib.types.str;
      default = "03";
      example = "03";
      description = "Hex CPU mask for unbound kernel workqueues; 03 corresponds to CPUs 0-1.";
    };

    workloadServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "llama-cpp" ];
      description = "Systemd services to place in the LLM workload slice.";
    };

    containDefaultSlices = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Constrain system.slice and user.slice to housekeeping CPUs.";
    };

    runtimeIrqAffinity = {
      enable = lib.mkEnableOption "runtime IRQ affinity assignment to housekeeping CPUs";

      cpuMask = lib.mkOption {
        type = lib.types.str;
        default = "03";
        example = "03";
        description = "Hex CPU mask for /proc/irq/default_smp_affinity; 03 corresponds to CPUs 0-1.";
      };
    };

    bootIsolation.enable = lib.mkEnableOption "reboot-required kernel CPU isolation parameters";

    blockScheduler = {
      scheduler = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "adios";
        description = ''
          Optional block IO scheduler to apply to the listed devices before
          workload services start. Leave null to use the host's normal udev
          scheduler policy.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nvme0n1" ];
        example = [ "nvme0n1" ];
        description = "Block devices whose queue scheduler should be set for LLM experiments.";
      };
    };

    observability.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install tools for CPU, IRQ, IO, and scheduler measurements.";
    };

    cacheAllocation = {
      enable = lib.mkEnableOption "experimental hidden LLC allocation MSR policy";

      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "pius";
        description = ''
          Hostname allowed to apply this raw MSR policy. Enabling cache
          allocation requires setting this to the target host's
          networking.hostName so shared imports cannot accidentally apply the
          policy elsewhere.
        '';
      };

      acknowledgeUndocumentedMsrs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Explicit acknowledgement that this policy writes undocumented,
          host-specific cache-allocation MSRs rather than using advertised
          resctrl/RDT support.
        '';
      };

      cosMasks = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "0xc90" = "0xfff";
          "0xc91" = "0x1";
          "0xc92" = "0x7f";
          "0xc93" = "0x1ff";
        };
        description = ''
          MSR cache-allocation masks to apply. This is intentionally raw:
          some client Intel CPUs expose writable CAT-like MSRs without
          advertising resctrl/RDT support.
        '';
      };

      housekeepingPqr = lib.mkOption {
        type = lib.types.str;
        default = "0x1";
        description = ''
          Raw IA32_PQR_ASSOC value for housekeeping CPUs. On pius the hidden
          path accepts the low-bit value 0x1 and rejects the documented
          high-bit CLOS1 encoding, so this option deliberately does not infer
          the encoding from Intel RDT documentation.
        '';
      };

      workloadPqr = lib.mkOption {
        type = lib.types.str;
        default = "0x0";
        description = "Raw IA32_PQR_ASSOC value for workload CPUs.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      toServiceUnit = service: if lib.hasInfix "." service then service else "${service}.service";
      workloadServiceUnits = map toServiceUnit cfg.workloadServices;
      runtimeIrqAffinityScript = pkgs.writeShellApplication {
        name = "llm-irq-affinity";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
        ];
        text = ''
          set -euo pipefail
          shopt -s nullglob

          if [[ -w /proc/irq/default_smp_affinity ]]; then
            { printf '%s\n' "${cfg.runtimeIrqAffinity.cpuMask}" > /proc/irq/default_smp_affinity; } 2>/dev/null || true
          fi

          for affinity in /proc/irq/[0-9]*/smp_affinity_list; do
            { printf '%s\n' "${cfg.housekeepingCpus}" > "$affinity"; } 2>/dev/null || true
          done
        '';
      };
      blockSchedulerScript = pkgs.writeShellApplication {
        name = "llm-block-scheduler";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
        text = ''
          set -euo pipefail

          scheduler=${lib.escapeShellArg (toString cfg.blockScheduler.scheduler)}

          for device in ${lib.escapeShellArgs cfg.blockScheduler.devices}; do
            queue=/sys/block/"$device"/queue/scheduler
            if [[ ! -e "$queue" ]]; then
              echo "missing block scheduler queue: $queue" >&2
              exit 1
            fi

            if ! grep -qw -- "$scheduler" "$queue"; then
              echo "scheduler '$scheduler' is not available for $device: $(cat "$queue")" >&2
              exit 1
            fi

            printf '%s\n' "$scheduler" > "$queue"
          done
        '';
      };
      cacheAllocationScript = pkgs.writeShellApplication {
        name = "llm-cache-allocation-apply";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.kmod
          pkgs.msr-tools
        ];
        text = ''
          set -euo pipefail

          state_dir=/run/llm-cache-allocation
          mkdir -p "$state_dir"

          expand_cpu_list() {
            local spec="$1"
            local part start end cpu
            IFS=',' read -ra ranges <<< "$spec"
            for part in "''${ranges[@]}"; do
              if [[ "$part" == *-* ]]; then
                start="''${part%-*}"
                end="''${part#*-}"
                for ((cpu = start; cpu <= end; cpu++)); do
                  printf '%s\n' "$cpu"
                done
              elif [[ -n "$part" ]]; then
                printf '%s\n' "$part"
              fi
            done
          }

          save_once() {
            local cpu
            for cpu in $(expand_cpu_list "${cfg.housekeepingCpus},${cfg.workloadCpus}"); do
              if [[ ! -e "$state_dir/pqr-cpu$cpu" ]]; then
                rdmsr -p "$cpu" 0xc8f > "$state_dir/pqr-cpu$cpu"
              fi
            done

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (msr: _: ''
                if [[ ! -e "$state_dir/mask-${msr}" ]]; then
                  rdmsr -p 0 ${msr} > "$state_dir/mask-${msr}"
                fi
              '') cfg.cacheAllocation.cosMasks
            )}
          }

          restore_on_error() {
            ${cacheAllocationRestoreScript}/bin/llm-cache-allocation-restore || true
          }

          modprobe msr || true
          save_once
          trap restore_on_error ERR

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (msr: mask: "wrmsr -a ${msr} ${mask}") cfg.cacheAllocation.cosMasks
          )}

          for cpu in $(expand_cpu_list "${cfg.housekeepingCpus}"); do
            wrmsr -p "$cpu" 0xc8f ${cfg.cacheAllocation.housekeepingPqr}
          done

          for cpu in $(expand_cpu_list "${cfg.workloadCpus}"); do
            wrmsr -p "$cpu" 0xc8f ${cfg.cacheAllocation.workloadPqr}
          done

          trap - ERR
        '';
      };
      cacheAllocationRestoreScript = pkgs.writeShellApplication {
        name = "llm-cache-allocation-restore";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.msr-tools
        ];
        text = ''
          set -euo pipefail

          state_dir=/run/llm-cache-allocation
          [[ -d "$state_dir" ]] || exit 0

          expand_cpu_list() {
            local spec="$1"
            local part start end cpu
            IFS=',' read -ra ranges <<< "$spec"
            for part in "''${ranges[@]}"; do
              if [[ "$part" == *-* ]]; then
                start="''${part%-*}"
                end="''${part#*-}"
                for ((cpu = start; cpu <= end; cpu++)); do
                  printf '%s\n' "$cpu"
                done
              elif [[ -n "$part" ]]; then
                printf '%s\n' "$part"
              fi
            done
          }

          for cpu in $(expand_cpu_list "${cfg.housekeepingCpus},${cfg.workloadCpus}"); do
            if [[ -s "$state_dir/pqr-cpu$cpu" ]]; then
              wrmsr -p "$cpu" 0xc8f "0x$(cat "$state_dir/pqr-cpu$cpu")"
            fi
          done

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (msr: _: ''
              if [[ -s "$state_dir/mask-${msr}" ]]; then
                wrmsr -a ${msr} "0x$(cat "$state_dir/mask-${msr}")"
              fi
            '') cfg.cacheAllocation.cosMasks
          )}
        '';
      };
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !cfg.cacheAllocation.enable || cfg.cacheAllocation.hostName != null;
            message = "cjv.llmTuning.cacheAllocation.enable requires setting cacheAllocation.hostName.";
          }
          {
            assertion =
              !cfg.cacheAllocation.enable || cfg.cacheAllocation.hostName == config.networking.hostName;
            message = "cjv.llmTuning.cacheAllocation.hostName must match networking.hostName.";
          }
          {
            assertion = !cfg.cacheAllocation.enable || cfg.cacheAllocation.acknowledgeUndocumentedMsrs;
            message = "cjv.llmTuning.cacheAllocation.enable requires acknowledgeUndocumentedMsrs = true.";
          }
          {
            assertion = cfg.blockScheduler.scheduler == null || cfg.blockScheduler.devices != [ ];
            message = "cjv.llmTuning.blockScheduler.scheduler requires at least one blockScheduler.devices entry.";
          }
        ];

        warnings =
          lib.optional (cfg.bootIsolation.enable && !cfg.containDefaultSlices)
            "cjv.llmTuning.bootIsolation.enable isolates kernel work, but system.slice/user.slice are not constrained unless containDefaultSlices = true.";

        environment.systemPackages = lib.mkIf cfg.observability.enable [
          config.boot.kernelPackages.cpupower
          config.boot.kernelPackages.turbostat
          config.boot.kernelPackages.x86_energy_perf_policy
          pkgs.cpuid
          pkgs.intel-cmt-cat
          pkgs.perf
          pkgs.hwloc
          pkgs.msr-tools
          pkgs.numactl
          pkgs.pciutils
          pkgs.stress-ng
          pkgs.sysstat
        ];

        systemd = {
          slices.llm-workload = {
            description = "Latency-sensitive local LLM workloads";
            sliceConfig = {
              AllowedCPUs = cfg.workloadCpus;
              CPUAccounting = true;
              IOAccounting = true;
              MemoryAccounting = true;
            };
          };

          services =
            (lib.genAttrs cfg.workloadServices (_: {
              serviceConfig = {
                Slice = "llm-workload.slice";
                AllowedCPUs = cfg.workloadCpus;
                CPUAccounting = true;
                IOAccounting = true;
                MemoryAccounting = true;
              };
            }))
            // {
              # Let irqbalance continue managing housekeeping CPUs, but keep it
              # from deliberately moving managed IRQs onto the workload CPUs.
              irqbalance.environment.IRQBALANCE_BANNED_CPULIST = cfg.workloadCpus;
            };

          # Keep unbound kworkers off the workload CPUs after boot. Per-CPU
          # kthreads still need reboot-time isolation parameters.
          tmpfiles.rules = [
            "w /sys/devices/virtual/workqueue/cpumask - - - - ${cfg.workqueueCpuMask}"
          ];
        };
      }

      (lib.mkIf (cfg.blockScheduler.scheduler != null) {
        systemd.services.llm-block-scheduler = {
          description = "Apply LLM experiment block IO scheduler";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-udev-settle.service" ];
          before = workloadServiceUnits;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${blockSchedulerScript}/bin/llm-block-scheduler";
          };
        };
      })

      (lib.mkIf cfg.runtimeIrqAffinity.enable {
        systemd.services.llm-irq-affinity = {
          description = "Pin IRQ affinity to LLM housekeeping CPUs";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          before = workloadServiceUnits ++ [ "irqbalance.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${runtimeIrqAffinityScript}/bin/llm-irq-affinity";
          };
        };
      })

      (lib.mkIf cfg.cacheAllocation.enable {
        boot.kernelModules = [ "msr" ];

        systemd.services.llm-cache-allocation = {
          description = "Experimental hidden LLC allocation policy for LLM tuning";
          wantedBy = [ "multi-user.target" ];
          before = workloadServiceUnits;
          after = [ "systemd-modules-load.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${cacheAllocationScript}/bin/llm-cache-allocation-apply";
            ExecStop = "${cacheAllocationRestoreScript}/bin/llm-cache-allocation-restore";
          };
        };
      })

      (lib.mkIf cfg.containDefaultSlices {
        systemd.slices.system.sliceConfig = {
          AllowedCPUs = cfg.housekeepingCpus;
          CPUAccounting = true;
          IOAccounting = true;
          MemoryAccounting = true;
        };

        systemd.slices.user.sliceConfig = {
          AllowedCPUs = cfg.housekeepingCpus;
          CPUAccounting = true;
          IOAccounting = true;
          MemoryAccounting = true;
        };
      })

      (lib.mkIf cfg.bootIsolation.enable {
        boot.kernelParams = [
          "nohz_full=${cfg.workloadCpus}"
          "rcu_nocbs=${cfg.workloadCpus}"
          "irqaffinity=${cfg.housekeepingCpus}"
          "kthread_cpus=${cfg.housekeepingCpus}"
          # Keep scheduler load balancing across the workload CPU set. A
          # measured pius run with isolcpus=domain collapsed llama-server's
          # worker threads onto one CPU despite an affinity mask of 2-5.
          "isolcpus=managed_irq,${cfg.workloadCpus}"
        ];
      })
    ]
  );
}
