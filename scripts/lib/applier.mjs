// Adapter at the wallpaper-applier seam: awww (the running daemon) and awww
// (the set command). exec/spawnFn are injected so the module is testable; the
// composition root supplies the real child_process functions.

export function awwwApplier({ exec, spawnFn, log = () => {} } = {}) {
  function daemonRunning() {
    try {
      exec("awww", ["query"], { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  }

  // Ensure the awww daemon is up; spawn it detached + stdio ignored so the
  // long-lived daemon neither holds our lock nor dies when the parent exits.
  async function ensure() {
    if (daemonRunning()) return true;
    log("starting awww-daemon");
    const child = spawnFn("awww-daemon", [], { stdio: "ignore", detached: true });
    child.on("error", () => {}); // ENOENT etc must not crash the CLI
    child.unref();
    for (let i = 0; i < 10; i++) {
      if (daemonRunning()) return true;
      await new Promise((r) => setTimeout(r, 300));
    }
    return daemonRunning();
  }

  function setWallpaper(file) {
    exec("awww", ["img", "--transition-type", "fade", "--transition-duration", "2", file]);
  }

  return { ensure, setWallpaper };
}
