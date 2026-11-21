# The prebuilt T3 Code server from upstream's release tarball.
#
# The source package in ./default.nix builds a pnpm workspace and a Rust
# resource monitor: minutes of compile on a fast machine, far longer on the
# homelab's A10. Every release also ships that same server as
# t3-<version>-linux-x64.tar.gz, so a headless host takes the artifact: Nix
# fetches it and points the two executables at NixOS's loader. Nothing is
# compiled.
#
# The patch is hand-rolled instead of autoPatchelfHook because `t3` is a Node
# single-executable application: its JS blob is appended to the ELF, and the
# hook's patching/stripping moves it, so every start dies on the SEA magic
# assertion. `dontStrip` protects the same blob and `dontPatchELF` keeps the
# setup hook from rewriting the binary's rpath again. The bundled native modules
# are dlopen'd through the `t3` RUNPATH, so only the executables need an
# interpreter of their own.
#
# The tree keeps upstream's layout, because `t3` resolves its client,
# node_modules, and resource monitor relative to its own path. bin/t3 is a
# symlink into that tree so `t3 serve` and the processes it spawns find them.
{
  pkgs,
  lockPath ? ./server-lock.nix,
}:
let
  inherit (pkgs) lib;
  lock = import lockPath;
  version = lib.removePrefix "v" lock.tag;
  interpreter = pkgs.stdenv.cc.bintools.dynamicLinker;
  libs = lib.makeLibraryPath [
    pkgs.glibc
    pkgs.stdenv.cc.cc.lib
  ];
  monitor = "resource-monitor/linux-x64/t3-resource-monitor";
  patch = file: ''
    patchelf --set-interpreter ${interpreter} ${file}
    patchelf --set-rpath '${libs}:$ORIGIN/lib' ${file}
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "t3code-server";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/${lock.tag}/t3-${version}-linux-x64.tar.gz";
    hash = lock.hash;
  };

  nativeBuildInputs = [ pkgs.patchelf ];
  # The SEA blob's offset is derived from the section table; stripping moves it.
  dontStrip = true;
  dontPatchELF = true;

  # The header's patchelf warning deserves a build-time guard: if a later
  # release moves the blob or breaks the interpreter, the build fails here
  # instead of on the homelab's first service start.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/t3 --version
    runHook postInstallCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    cp -r . $out/libexec/t3
    chmod -R u+w $out/libexec/t3
    ln -s ../libexec/t3/t3 $out/bin/t3
    ${patch "$out/libexec/t3/t3"}
    test -e "$out/libexec/t3/${monitor}" || {
      echo "t3code-server: ${monitor} is missing from the release tarball" >&2
      exit 1
    }
    ${patch "$out/libexec/t3/${monitor}"}
    runHook postInstall
  '';

  meta = {
    mainProgram = "t3";
    platforms = [ "x86_64-linux" ];
  };
}
