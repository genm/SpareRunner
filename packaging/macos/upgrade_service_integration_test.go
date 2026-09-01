package macospackaging

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// previousReleaseSuffix simulates a property list shipped by an older release:
// the same package file with one extra trailing comment, so provenance is
// decided by byte identity and never by anything weaker.
const previousReleaseSuffix = "<!-- shipped by the previous release -->\n"

// makePreviousPlist copies the repository property list into a fresh
// directory and appends previousReleaseSuffix, standing in for the plist of
// an extracted older release archive.
func makePreviousPlist(t *testing.T, source string) string {
	t.Helper()
	working, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	previous := filepath.Join(working, "com.genm.sparerunner.agent.plist")
	if err := os.WriteFile(
		previous,
		append(contents, []byte(previousReleaseSuffix)...),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	return previous
}

func (harness installerHarness) runMacOSScript(
	t *testing.T,
	wantSuccess bool,
	script string,
	args ...string,
) string {
	t.Helper()
	path := filepath.Join(filepath.Dir(harness.script), script)
	command := exec.Command("/bin/bash", append([]string{path}, args...)...)
	command.Env = installerEnvironment(harness)
	output, err := command.CombinedOutput()
	if wantSuccess && err != nil {
		t.Fatalf("%s failed: %v\n%s", script, err, output)
	}
	if !wantSuccess && err == nil {
		t.Fatalf("%s unexpectedly succeeded:\n%s", script, output)
	}
	return string(output)
}

func (harness installerHarness) runUpgrade(t *testing.T, wantSuccess bool, args ...string) string {
	t.Helper()
	return harness.runMacOSScript(t, wantSuccess, "upgrade-service.sh", args...)
}

func (harness installerHarness) runUpgradeRejecting(t *testing.T, reason string, args ...string) {
	t.Helper()
	output := harness.runUpgrade(t, false, args...)
	if !strings.Contains(output, reason) {
		t.Fatalf("upgrade rejection lacks %q:\n%s", reason, output)
	}
}

func (harness installerHarness) requireDaemonLoaded(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(harness.helper, "launchd-loaded")); err != nil {
		t.Fatalf("the daemon is not loaded after the upgrade path: %v", err)
	}
}

func (harness installerHarness) requireNoUpgradeStaging(t *testing.T) {
	t.Helper()
	for _, suffix := range []string{".sparerunner-upgrade-prev", ".sparerunner-install-tmp"} {
		if _, err := os.Lstat(harness.plistTarget() + suffix); !os.IsNotExist(err) {
			t.Fatalf("upgrade left staging state at %s%s: %v", harness.plistTarget(), suffix, err)
		}
	}
}

func TestUpgradeServiceReplacesOnlyTheProvenPropertyList(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the macOS shell installer harness requires /bin/bash")
	}
	if output, err := exec.Command("/usr/bin/id", "-u").Output(); err == nil &&
		strings.TrimSpace(string(output)) == "0" {
		t.Skip("production root intentionally rejects installer test indirection")
	}

	t.Run("binary-only upgrade restarts without republishing", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		harness.run(t, true)
		harness.resetMutations(t)

		output := harness.runUpgrade(t, true, harness.plist)
		if !strings.Contains(output, "already matches this package") {
			t.Fatalf("binary-only upgrade output = %q", output)
		}
		mutations := harness.mutationLines(t)
		requireMutation(t, mutations, "launchctl bootout ")
		requireMutation(t, mutations, "launchctl bootstrap ")
		for _, mutation := range mutations {
			if strings.HasPrefix(mutation, "install ") || strings.HasPrefix(mutation, "ln ") {
				t.Fatalf("binary-only upgrade republished the property list: %q", mutations)
			}
		}
		harness.requireDaemonLoaded(t)
		harness.requireNoUpgradeStaging(t)
	})

	t.Run("previous-release plist is replaced with proven provenance", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.runMacOSScript(t, true, "install-service.sh", previous)
		harness.resetMutations(t)

		output := harness.runUpgrade(t, true, harness.plist, "--previous", previous)
		if !strings.Contains(output, "replaced com.genm.sparerunner.agent.plist") {
			t.Fatalf("upgrade output = %q", output)
		}
		expected, err := os.ReadFile(harness.plist)
		if err != nil {
			t.Fatal(err)
		}
		requireFileContents(t, harness.plistTarget(), string(expected))
		harness.requireDaemonLoaded(t)
		harness.requireNoUpgradeStaging(t)
	})

	t.Run("previous-release plist without --previous is refused", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.runMacOSScript(t, true, "install-service.sh", previous)
		harness.resetMutations(t)

		harness.runUpgradeRejecting(
			t,
			"pass --previous <previous-release-plist> to prove its provenance",
			harness.plist,
		)
		harness.requireNoMutations(t)
	})

	t.Run("operator-modified plist is refused before any mutation", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.run(t, true)
		contents, err := os.ReadFile(harness.plistTarget())
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(
			harness.plistTarget(),
			append(contents, []byte("<!-- operator edit -->\n")...),
			0o600,
		); err != nil {
			t.Fatal(err)
		}
		harness.resetMutations(t)

		harness.runUpgradeRejecting(
			t,
			"matches neither this package nor the previous package",
			harness.plist,
			"--previous", previous,
		)
		harness.requireNoMutations(t)
		harness.requireDaemonLoaded(t)
	})

	t.Run("a host that was never installed is refused", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)

		harness.runUpgradeRejecting(
			t,
			"no owned SpareRunner installation to upgrade",
			harness.plist,
		)
		harness.requireNoMutations(t)
	})

	t.Run("leftover staging state is refused before any mutation", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		harness.run(t, true)
		if err := os.WriteFile(
			harness.plistTarget()+".sparerunner-upgrade-prev",
			[]byte("stale staging\n"),
			0o600,
		); err != nil {
			t.Fatal(err)
		}
		harness.resetMutations(t)

		harness.runUpgradeRejecting(
			t,
			"refusing to replace upgrade staging state",
			harness.plist,
		)
		harness.requireNoMutations(t)
		harness.requireDaemonLoaded(t)
	})

	t.Run("staging failure restores the previous release and restarts it", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.runMacOSScript(t, true, "install-service.sh", previous)
		harness.resetMutations(t)
		harness.injectMutationFailureAfter(t, "install ")

		output := harness.runUpgrade(t, false, harness.plist, "--previous", previous)
		if !strings.Contains(output, "the previous installation was restored and restarted") {
			t.Fatalf("rollback output = %q", output)
		}
		expected, err := os.ReadFile(previous)
		if err != nil {
			t.Fatal(err)
		}
		requireFileContents(t, harness.plistTarget(), string(expected))
		harness.requireDaemonLoaded(t)
		harness.requireNoUpgradeStaging(t)
	})

	t.Run("post-bootstrap failure removes the new plist and restores", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.runMacOSScript(t, true, "install-service.sh", previous)
		harness.resetMutations(t)
		harness.injectMutationFailureAfter(t, "launchctl bootstrap ")

		output := harness.runUpgrade(t, false, harness.plist, "--previous", previous)
		if !strings.Contains(output, "the previous installation was restored and restarted") {
			t.Fatalf("rollback output = %q", output)
		}
		expected, err := os.ReadFile(previous)
		if err != nil {
			t.Fatal(err)
		}
		requireFileContents(t, harness.plistTarget(), string(expected))
		harness.requireDaemonLoaded(t)
		harness.requireNoUpgradeStaging(t)
	})

	t.Run("an unloaded daemon is upgraded and left loaded", func(t *testing.T) {
		t.Parallel()
		harness := newInstallerHarness(t)
		previous := makePreviousPlist(t, harness.plist)
		harness.runMacOSScript(t, true, "install-service.sh", previous)
		if err := os.Remove(filepath.Join(harness.helper, "launchd-loaded")); err != nil {
			t.Fatal(err)
		}
		harness.resetMutations(t)

		harness.runUpgrade(t, true, harness.plist, "--previous", previous)
		mutations := harness.mutationLines(t)
		for _, mutation := range mutations {
			if strings.HasPrefix(mutation, "launchctl bootout ") {
				t.Fatalf("upgrade booted out an unloaded daemon: %q", mutations)
			}
		}
		harness.requireDaemonLoaded(t)
		harness.requireNoUpgradeStaging(t)
	})
}
