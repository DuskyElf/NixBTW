# Workaround: Module-CPANTS-Analyse's test fails with Archive::Any::Lite 0.11
# because SECURE EXTRACT MODE rejects the absolute-symlink test tarball. This
# cascades: Test-Kwalitee -> Finance-Quote -> gnucash breaks.
#
# Using `perl5.override { overrides = ... }` with the base `prev.perl5.pkgs`
# creates a top-level `//` merge that does NOT propagate to internal fixpoint
# references inside makeScopeWithSplicing'. Test-Kwalitee would still use the
# original ModuleCPANTSAnalyse (with tests enabled).
#
# Instead, use overrideScope on the perl package set itself. This rebuilds
# the entire scope fixpoint, so ALL packages that depend on ModuleCPANTSAnalyse
# (Test-Kwalitee, Finance-Quote, etc.) use the overridden version internally.
_final: prev: {
  perl5 = prev.perl5.override {
    overrides =
      _:
      prev.perl5.pkgs.overrideScope (
        _finalself: prevself: {
          ModuleCPANTSAnalyse = prevself.ModuleCPANTSAnalyse.overrideAttrs (_old: {
            doCheck = false;
          });
        }
      );
  };
}
