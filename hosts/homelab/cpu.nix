# CPU policy for the A10: the frequency governor and the P-state voltage
# offset. Both are hardware facts about this box, so they live here rather than
# in an apps/ module.
#
# The governor needs no userspace at all: this kernel's default is schedutil
# (hosts/homelab/kernel.nix), which idles at the lowest P-state and requests
# the top one the moment a build starts. What used to run here was
# auto-cpufreq with `charger.governor = "powersave"`, and since this machine is
# always on the charger that pinned it at 1.4 GHz under every load: a fixed ALU
# loop takes 7.6 s there and 5.1 s at 2.3 GHz, and a nix build gets the same
# ratio. Removed with the import in default.nix.
#
# The offset is a voltage change written into PStateDef (MSRC001_0064..6A; the
# seventh state exists but the firmware leaves it disabled):
# SVI2, 6.25 mV per CpuVid step, so +8 steps is -50 mV on every state. It
# lowers power at the same clocks, which on this board means a cooler package
# and a slower fan rather than a higher ceiling.
#
# The clock cannot be raised. PStateDef[2] is the top state the governor can
# ask for (2.3 GHz); writing 2.4 through 2.8 GHz into it reads back unchanged,
# while fid 5 (2.1 GHz) and two DID 1 writes (1.5 and 1.8 GHz) stick, so the
# register takes writes and refuses those definitions. The 3.2 and 2.7 GHz
# entries are the boosted P-states and `_PSS` exports only the five below them:
# writing control 0 selects the 2.3 GHz state and control 1 the 2.0 GHz one, so
# cpufreq cannot ask for the boosted states either. Turning the boost engine on
# is a loss: with HWCR CpbDis=0 on every core and D18F4x15C written to
# 0x80000089 (ApmMasterEn and BoostSrc set, NumBoostStates=2 unchanged), a
# pinned single thread runs 2058 MHz instead of 2295, four spinners sit at
# 1689 MHz instead of 2295, and the xz bench goes from 36.5/10.8 s to
# 38.7/12.8 s. The boosted states never arrive; the part only gets slower.
# Heat is not what caps the clock: four threads read 62 °C after 90 s and peak
# at 63 °C over 210 s against a 102 °C trip.
#
# A test that writes PStateDef or D18F4x15C survives until the next reboot; a
# rebuild resets neither register. The guard compares CpuVid only, so a
# frequency-only test looks like the firmware's table to it: the next switch
# writes the intended VIDs over the test, which erases that test rather than
# refusing it. A test that moves a VID is caught, and then the unit marks
# itself failed and stays off until both /var/lib/homelab-undervolt/state and
# /var/lib/homelab-undervolt/stock are removed.
{
  lib,
  pkgs,
  ...
}:
let
  # One script, two verbs: apply the offset at boot, and confirm a few minutes
  # later that the boot survived it. The guard is the point of the second one.
  undervolt = pkgs.writeTextFile {
    name = "homelab-undervolt";
    executable = true;
    destination = "/bin/homelab-undervolt";
    text = ''
      #!${pkgs.python3}/bin/python3
      """Offset the fam15h P-state voltages, with a boot guard.

      The P-state table is hardware state: a power cycle restores the firmware's
      values (a suspend would lose the offset, and this box never suspends).
      Nothing here is persisted except the guard's own marker and the stock
      table it compares against, so the worst case is a machine that boots at
      stock voltage.

      The guard: "pending" is written before any MSR is touched and only turns
      into "ok" three minutes later. A boot that stops in between leaves
      "pending", and the next boot then refuses to apply anything and stays at
      stock voltage until somebody clears the marker. "failed" is sticky for the
      same reason: a second boot must not repeat a failure the first one proved.
      """
      import os
      import struct
      import sys
      import time

      BASE = 0xC0010064       # PStateDef[0]; [0] and [1] are the boost states
      STATUS = 0xC0010071     # COFVID status, read-only: CurCpuVid lives in 15:9
      STATES = range(7)       # PStateDef[7] has PstateEn clear and is never written
      STEP = 8                # CpuVid steps of 6.25 mV: -50 mV on every state
      FLOOR_VID = 128         # 0.750 V; below this a Trinity core will not hold
      DIR = "/var/lib/homelab-undervolt"
      MARK = DIR + "/state"
      STOCK = DIR + "/stock"


      def cpus(wait=10.0):
          """The cores whose MSR device exists.

          udev creates the device nodes just after the module loads, so a boot
          can find none for a moment; wait rather than skip the offset. An
          offline core is not an error either, it just keeps the firmware's
          voltage.
          """
          end = time.time() + wait
          while True:
              found = []
              try:
                  names = sorted(os.listdir("/dev/cpu"))
              except FileNotFoundError:
                  names = []
              for name in names:
                  if not name.isdigit():
                      continue
                  try:
                      open("/dev/cpu/%s/msr" % name, "rb").close()
                  except OSError:
                      continue
                  found.append(int(name))
              if found or time.time() >= end:
                  return found
              time.sleep(0.5)


      def rd(cpu, reg):
          with open("/dev/cpu/%d/msr" % cpu, "rb", buffering=0) as f:
              f.seek(reg)
              return struct.unpack("<Q", f.read(8))[0]


      def wr(cpu, reg, val):
          with open("/dev/cpu/%d/msr" % cpu, "r+b", buffering=0) as f:
              f.seek(reg)
              f.write(struct.pack("<Q", val))


      def table(cpu):
          return [rd(cpu, BASE + i) for i in STATES]


      def vids(row):
          return [(v >> 9) & 0xFF for v in row]


      def shifted(row, step):
          """The row with every CpuVid moved by step, or None past the floor."""
          out = []
          for v in row:
              vid = (v >> 9) & 0xFF
              if vid + step > FLOOR_VID:
                  return None
              out.append((v & ~(0xFF << 9)) | ((vid + step) << 9))
          return out


      def write_atomic(path, data):
          # tmp + rename in the same directory: a crash mid-write leaves the old
          # file, never a half-written one. The marker is what decides whether
          # the next boot touches the MSRs, so it cannot be torn.
          tmp = path + ".tmp"
          with open(tmp, "wb") as f:
              f.write(data)
              f.flush()
              os.fsync(f.fileno())
          os.rename(tmp, path)


      def mark(state):
          os.makedirs(DIR, exist_ok=True)
          write_atomic(MARK, (state + "\n").encode())


      def read_mark():
          try:
              with open(MARK) as f:
                  return f.read().strip()
          except OSError:
              return ""


      def stop(message):
          """Refuse to touch the MSRs, say why, and stay refused."""
          mark("failed")
          print(message)
          return 0


      def apply():
          # A boot that applied an offset and never confirmed it is the boot that
          # failed. Stay at stock voltage, and stay there until somebody looks:
          # the next boot would otherwise repeat the failure.
          if read_mark() in ("pending", "failed"):
              return stop(
                  "the last boot did not confirm the offset; staying at stock "
                  "voltage. Clear %s to try again." % MARK)

          found = cpus()
          if not found:
              print("no /dev/cpu/N/msr; leaving the P-state table alone")
              return 0

          live = table(found[0])
          # One VDD domain: every core must agree on the VIDs. A core that kept a
          # different table means a half-applied write, and shifting on top of
          # that is how one core ends up an extra step low.
          for cpu in found[1:]:
              if vids(table(cpu)) != vids(live):
                  return stop(
                      "the cores disagree on the P-state VIDs; not touching "
                      "them. Clear %s after checking the table." % MARK)

          stock = None
          if os.path.exists(STOCK):
              try:
                  with open(STOCK, "rb") as f:
                      raw = f.read(56)
              except OSError:
                  raw = b""
              if len(raw) != 56:
                  # Unknown baseline: the live table may already be shifted, and
                  # shifting it again is the one unrecoverable mistake here.
                  return stop(
                      "%s is unreadable, so the firmware's table is unknown; not "
                      "applying. Remove %s and %s to start over." % (STOCK, MARK, STOCK))
              stock = list(struct.unpack("<7Q", raw))

          if stock is None:
              # First run: the live table is what the firmware programmed.
              os.makedirs(DIR, exist_ok=True)
              write_atomic(STOCK, struct.pack("<7Q", *live))
              stock = live

          target = shifted(stock, STEP)
          if target is None:
              return stop(
                  "the firmware's lowest P-state is within %d mV of the 0.750 V "
                  "floor; not applying." % (STEP * 625 // 1000))

          if vids(live) == vids(stock):
              pass
          elif vids(live) == vids(target):
              print("offset already applied")
              mark("pending")
              return 0
          else:
              # A BIOS update (or somebody else's write) moved the table. Treat
              # it as a new baseline only on purpose, by removing both files.
              return stop(
                  "the live table is neither the firmware's nor the offset one; "
                  "not touching it. Remove %s and %s to take it as the new "
                  "baseline." % (MARK, STOCK))

          # Mark first: a hang inside the writes must leave "pending" behind.
          mark("pending")
          for cpu in found:
              for i, v in zip(STATES, target):
                  wr(cpu, BASE + i, v)

          # A write lands on the next entry into that state, so this only reports
          # where each core is; the next boot's compare catches a write that did
          # not stick.
          for cpu in found:
              try:
                  cur = rd(cpu, STATUS)
                  print("cpu%d curpstate=%d curvid=%d" %
                        (cpu, (cur >> 16) & 7, (cur >> 9) & 0xFF))
              except OSError:
                  # Informational only; a read that fails here must not turn a
                  # successful write into a failed boot.
                  print("cpu%d: could not read the state register" % cpu)
          print("offset applied: -%d mV on states %s" %
                (STEP * 625 // 100, list(STATES)))
          return 0


      def confirm():
          # Three minutes after the write is the bar. Anything that failed in
          # between left the marker at "pending" for the next boot, and the
          # timer does not exist any more because the boot it belonged to is
          # gone.
          if read_mark() == "pending":
              mark("ok")
              print("offset confirmed for this boot")
          return 0


      if len(sys.argv) != 2 or sys.argv[1] not in ("apply", "confirm"):
          raise SystemExit("usage: homelab-undervolt apply|confirm")
      raise SystemExit(apply() if sys.argv[1] == "apply" else confirm())
    '';
  };
in
{
  # msr is not auto-loaded by any device probe, and the offset needs it.
  boot.kernelModules = [ "msr" ];

  # On 6.18 an MSR write is allowed by default and taints the kernel
  # (CPU_OUT_OF_SPEC) either way; `allow_writes=on` only stops the per-write
  # warning in dmesg. Stated here because the taint is expected, not a fault.
  boot.extraModprobeConfig = "options msr allow_writes=on";

  # The kernel's default governor is schedutil, and this unit covers the two
  # cases that default does not: a nixos-rebuild switch, where the *running*
  # governor is whatever was set last (auto-cpufreq pinned powersave, so the
  # first switch after it goes would otherwise stay at 1.4 GHz until a reboot),
  # and a manual experiment that left the policies somewhere else.
  systemd.services.homelab-governor = {
    description = "Set the CPU scaling governor to schedutil";
    wantedBy = [ "multi-user.target" ];
    before = [ "homelab-undervolt.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        echo schedutil > "$f"
      done
    '';
  };

  systemd.services.homelab-undervolt = {
    description = "Offset the P-state voltages (fam15h PStateDef)";
    wantedBy = [ "multi-user.target" ];
    after = [ "homelab-governor.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The module also has to exist for the *running* kernel at a switch, not
      # only for the one being installed.
      ExecStartPre = "${pkgs.kmod}/bin/modprobe msr";
      # The guard's other half is armed here, not by OnBootSec: a nixos-rebuild
      # also starts this unit, and a boot-relative timer would fire immediately.
      # ExecStartPost only runs when the apply exited 0, so a failed apply never
      # arms a confirmation.
      ExecStartPost = "${pkgs.systemd}/bin/systemctl --no-block start homelab-undervolt-confirm.timer";
    };
    script = "${lib.getExe undervolt} apply";
  };

  # Not wantedBy anything: the apply unit starts it after the write. A boot that
  # hangs leaves the marker at "pending" and the next one comes up at stock
  # voltage.
  systemd.services.homelab-undervolt-confirm = {
    description = "Confirm the undervolt did not break this boot";
    serviceConfig.Type = "oneshot";
    script = "${lib.getExe undervolt} confirm";
  };

  systemd.timers.homelab-undervolt-confirm = {
    timerConfig = {
      Unit = "homelab-undervolt-confirm.service";
      OnActiveSec = "3min";
    };
  };
}
