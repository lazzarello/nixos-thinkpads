// Run against a patched DMS source tree: node scripts/test-dms-fingerprint-retry.mjs /path/to/source
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runInNewContext } from "node:vm";

assert.ok(process.argv[2], "Pass the patched DMS source directory");
const lockDir = join(process.argv[2], "quickshell/Modules/Lock");
const content = readFileSync(join(lockDir, "LockScreenContent.qml"), "utf8");
const pamSource = readFileSync(join(lockDir, "Pam.qml"), "utf8");
const button = content.match(/DankButton \{\s+id: fingerprintRetryButton\b([\s\S]*?)\n            \}/)?.[1];
assert.ok(button, "Retry button must be present in the patched lock screen");
const visible = button.match(/visible: (.+)/)[1];
const clicked = button.match(/onClicked: \{([\s\S]*?)\n                \}/)[1];
const recover = pamSource.match(/function recover\(\): void \{([\s\S]*?)\n        \}/)[1];
assert.match(button, /Shortcut \{\s+sequence: "Ctrl\+R"\s+enabled: fingerprintRetryButton.visible\s+onActivated: fingerprintRetryButton.clicked\(\)/);

function context() {
    const fprint = {
        allowed: true, active: false, errorTries: 1, tries: 0, starts: 0,
    };
    fprint.startAttempt = () => { fprint.starts++; };
    fprint.recover = () => runInNewContext(`(function () { ${recover} })()`, fprint);
    return {
        root: {
            demoMode: false, unlocking: false, passwordFocused: false,
            focusPasswordField() { this.passwordFocused = true; },
        },
        pam: { passwd: { active: false }, fprint },
    };
}

// A device error offers recovery, clears only the device-error counter, and starts a scan.
const error = context();
assert.equal(runInNewContext(visible, error), true);
runInNewContext(clicked, error);
assert.equal(error.pam.fprint.starts, 1);
assert.equal(error.pam.fprint.errorTries, 0);

// Failed matches are not forgiven by retrying; password input is untouched.
const mismatch = context();
Object.assign(mismatch.pam.fprint, { errorTries: 0, tries: 1 });
mismatch.root.passwordBuffer = "partially typed password";
assert.equal(runInNewContext(visible, mismatch), true);
runInNewContext(clicked, mismatch);
assert.equal(mismatch.pam.fprint.starts, 1);
assert.equal(mismatch.pam.fprint.tries, 1);
assert.equal(mismatch.root.passwordBuffer, "partially typed password");
assert.equal(mismatch.root.passwordFocused, true);

for (const change of [
    c => { c.root.demoMode = true; },
    c => { c.root.unlocking = true; },
    c => { c.pam.passwd.active = true; },
    c => { c.pam.fprint.active = true; },
    // DMS sets allowed=false at the attempt limit, during sleep, or when disabled.
    c => { c.pam.fprint.allowed = false; },
    c => { c.pam.fprint.errorTries = 0; },
]) {
    const c = context();
    change(c);
    assert.equal(runInNewContext(visible, c), false);
}

// Even a stale click cannot restart authentication after DMS disallows it.
const blocked = context();
blocked.pam.fprint.allowed = false;
runInNewContext(clicked, blocked);
assert.equal(blocked.pam.fprint.starts, 0);
assert.equal(blocked.pam.fprint.errorTries, 1);
console.log("DMS fingerprint retry checks passed");
