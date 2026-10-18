#!/usr/bin/env python3
"""Security and unsaved-document regressions against a built runtime.

Run `swift build`, then `python3 Scripts/runtime-regression-test.py`.
JAPP_RUNTIME can select an assembled/installed runtime executable instead.
All archives, saved pictures, app state and automation reports are temporary.
"""

import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
import zipfile


ROOT = Path(__file__).resolve().parent.parent
RUNTIME = Path(os.environ.get("JAPP_RUNTIME", ROOT / ".build/debug/JAppRuntime"))
ACTION = "dev.japp.runtime.automation.app"


class RuntimeRegressions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helpers = tempfile.TemporaryDirectory(prefix="japp-regression-helpers-")
        cls.addClassCleanup(cls.helpers.cleanup)
        cls.post = Path(cls.helpers.name) / "post-notification"
        subprocess.run(["swiftc", str(ROOT / "Tests/E2E/post-notification.swift"),
                        "-o", str(cls.post)], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="japp-regression-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.app_id = "dev.japp.regression-" + uuid.uuid4().hex
        self.env = {**os.environ, "JAPP_SUPPORT_DIR": str(self.work / "support")}

    def wait_for(self, predicate, description, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.05)
        self.fail("Timed out: " + description)

    def items(self):
        file = self.work / "support/Apps" / self.app_id / "storage.json"
        return json.loads(file.read_text())["items"] if file.exists() else {}

    def pack(self, files, permissions=("storage",)):
        app = self.work / "Probe.japp"
        manifest = {"manifestVersion": 1, "id": self.app_id, "name": "Regression Probe",
                    "version": "1", "permissions": list(permissions)}
        with zipfile.ZipFile(app, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            for name, text in files.items():
                archive.writestr(name, text)
        return app

    def start_app(self, app, script="return null;", auto_quit=False):
        report = self.work / "report"
        report.mkdir()
        source = self.work / "test.js"
        source.write_text(script)
        log = (self.work / "runtime.log").open("w")
        self.addCleanup(log.close)
        process = subprocess.Popen([
            str(RUNTIME), "--host", str(app), "-JAppAutomationDir", str(report),
            "-JAppAutomationScript", str(source), "-JAppAutomationQuit", "YES" if auto_quit else "NO",
            "-JAppSingleProcess", "YES", "-JAppSetFinderIcons", "NO",
        ], env=self.env, stdout=log, stderr=log)

        def stop():
            if process.poll() is None:
                process.kill()  # Only this test's process; do not invoke a pending save prompt.
            process.wait(timeout=5)

        self.addCleanup(stop)
        self.wait_for(lambda: (report / "report.json").exists(), "initial runtime report")
        result = json.loads((report / "report.json").read_text())
        self.assertTrue(result["ok"], result)
        self.assertNotIn("scriptError", result)
        return process, report, result

    def action(self, action):
        subprocess.run([str(self.post), ACTION, action], check=True, capture_output=True)

    def choose(self, report, title):
        alert = self.wait_for(lambda: (report / "alert.json").exists(), "native alert")
        self.assertTrue(alert)
        buttons = json.loads((report / "alert.json").read_text())["buttons"]
        self.assertIn(title, buttons)
        self.action("alert:" + title)
        self.wait_for(lambda: not (report / "alert.json").exists(), "dismissed alert")

    def assert_running(self, process):
        time.sleep(0.2)
        self.assertIsNone(process.poll(), (self.work / "runtime.log").read_text())

    def test_network_policy_covers_svg_and_workers(self):
        # Run both permission states: blocking every request is not a valid fix.
        for allowed in (False, True):
            with self.subTest(network=allowed):
                received = []

                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        received.append(self.path)
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b"OK")

                    def log_message(self, *args):
                        pass

                server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    base = "http://127.0.0.1:" + str(server.server_port)
                    files = {
                        "index.html": """<!doctype html><script>
                        window.finished = 0;
                        addEventListener('message', () => finished++);
                        fetch('BASE/html', {mode:'no-cors'}).catch(()=>{}).finally(()=>finished++);
                        new Worker('worker.js').onmessage = () => finished++;
                        </script><iframe src="probe.svg"></iframe>""".replace("BASE", base),
                        "probe.svg": """<svg xmlns="http://www.w3.org/2000/svg"><script><![CDATA[
                        fetch('BASE/svg', {mode:'no-cors'}).catch(()=>{}).finally(()=>parent.postMessage('done','*'));
                        ]]></script></svg>""".replace("BASE", base),
                        "worker.js": "fetch('" + base + "/worker',{mode:'no-cors'}).catch(()=>{}).finally(()=>postMessage('done'));",
                    }
                    app = self.pack(files, ("network",) if allowed else ())
                    # Each run gets its own report folder while keeping the same package identity.
                    previous_report = self.work / "report"
                    if previous_report.exists():
                        previous_report.rename(self.work / "report-blocked")
                    process, _, result = self.start_app(app, """
                        for (let i=0; i<80 && finished<3; i++) await new Promise(r=>setTimeout(r,50));
                        const range = await fetch('probe.svg', {headers:{Range:'bytes=0-20'}});
                        return {finished, range:range.status, policy:range.headers.get('Content-Security-Policy')};
                    """, auto_quit=True)
                    self.assertEqual(process.wait(timeout=5), 0)
                    self.assertEqual(result["scriptResult"]["finished"], 3)
                    self.assertEqual(result["scriptResult"]["range"], 206)
                    self.assertIn("connect-src", result["scriptResult"]["policy"])
                    self.assertEqual(sorted(received), ["/html", "/svg", "/worker"] if allowed else [])
                finally:
                    server.shutdown()
                    server.server_close()

    def lifecycle_app(self, script):
        return self.start_app(self.pack({"index.html": "<!doctype html><title>Draft</title>"}), script)

    def test_close_quit_and_reload_wait_for_save_and_respect_cancel(self):
        # Fresh process per action, including native termination rather than window.close().
        for action in ("close", "quit", "reload", "signal"):
            with self.subTest(action=action):
                # These subtests need independent app state and report files.
                if (self.work / "report").exists():
                    shutil.rmtree(self.work / "report")
                self.app_id = "dev.japp.regression-" + uuid.uuid4().hex
                process, _, result = self.lifecycle_app("""
                    const load = await japp.storage.get('loads',0)+1;
                    await japp.storage.set('loads',load);
                    await japp.window.setDocumentEdited(true);
                    japp.window.onBeforeClose(async ({reason}) => {
                        const call = await japp.storage.get('calls',0)+1;
                        await japp.storage.set('reason',reason);
                        await japp.storage.set('calls',call);
                        if (call===1) return false;
                        await new Promise(r=>setTimeout(r,150));
                        await japp.storage.set('saved',true);
                        await japp.window.setDocumentEdited(false);
                        return true;
                    });
                    return load;
                """)
                self.assertTrue(result["native"]["documentEdited"])
                def request():
                    if action == "signal":
                        process.send_signal(signal.SIGTERM)
                    else:
                        self.action(action)

                request()
                self.wait_for(lambda: self.items().get("calls") == 1, "cancel callback")
                self.assert_running(process)
                self.assertEqual(self.items().get("loads"), 1)
                self.assertEqual(self.items()["reason"], "quit" if action == "signal" else action)
                request()
                if action == "reload":
                    self.wait_for(lambda: self.items().get("loads") == 2, "approved reload")
                    self.assert_running(process)
                    process.kill()
                    process.wait(timeout=5)
                else:
                    self.assertEqual(process.wait(timeout=5), 0)
                self.assertTrue(self.items()["saved"])

    def test_edited_document_without_handler_has_native_warning(self):
        process, report, _ = self.lifecycle_app("await japp.window.setDocumentEdited(true);")
        self.action("close")
        self.choose(report, "Keep Open")
        self.assert_running(process)
        self.action("close")
        self.choose(report, "Discard Changes")
        self.assertEqual(process.wait(timeout=5), 0)

    def test_repeated_close_requests_share_one_decision(self):
        process, _, _ = self.lifecycle_app("""
            await japp.window.setDocumentEdited(true);
            japp.window.onBeforeClose(async () => {
                await japp.storage.set('calls',await japp.storage.get('calls',0)+1);
                await new Promise(r=>setTimeout(r,2000));
                await japp.storage.set('decisionFinished',true);
                return false;
            });
        """)
        self.action("close")
        self.wait_for(lambda: self.items().get("calls") == 1, "first close request")
        self.action("close")
        self.wait_for(lambda: self.items().get("decisionFinished"), "cancel decision")
        self.assertEqual(self.items()["calls"], 1)
        self.assert_running(process)

    def test_failed_close_handler_does_not_discard_work(self):
        process, report, _ = self.lifecycle_app("""
            await japp.window.setDocumentEdited(true);
            japp.window.onBeforeClose(async () => { throw new Error('save failed'); });
        """)
        self.action("quit")
        self.choose(report, "Keep Open")
        self.assert_running(process)

    def test_close_handler_can_be_removed_and_edited_flag_requires_boolean(self):
        process, _, result = self.lifecycle_app("""
            const remove = japp.window.onBeforeClose(() => false);
            remove();
            try { await japp.window.setDocumentEdited('false'); return 'accepted'; }
            catch (error) { return error.code; }
        """)
        self.assertEqual(result["scriptResult"], "BAD_ARGUMENTS")
        self.assertFalse(result["native"]["documentEdited"])
        self.action("close")
        self.assertEqual(process.wait(timeout=5), 0)

    def paint(self):
        files = {str(file.relative_to(ROOT / "Examples/Paint")): file.read_bytes()
                 for file in (ROOT / "Examples/Paint").rglob("*")
                 if file.is_file() and file.name != "manifest.json"}
        return self.start_app(self.pack(files, ("storage", "dialog", "clipboard")), """
            paint.selectTool('pencil');
            const stage=document.getElementById('stage'), rect=stage.getBoundingClientRect();
            for(const type of ['pointerdown','pointerup']) stage.dispatchEvent(new PointerEvent(type, {
                bubbles:true,pointerId:1,button:0,buttons:type==='pointerup'?0:1,
                clientX:rect.left+15*paint.state.zoom,clientY:rect.top+15*paint.state.zoom
            }));
            paint.state.saved = true; // An existing picture: Save goes directly to the native panel.
            return {dirty:paint.state.dirty};
        """)

    def test_paint_cancel_and_dont_save_for_native_close_and_quit(self):
        process, report, result = self.paint()
        self.assertTrue(result["scriptResult"]["dirty"])
        self.assertTrue(result["native"]["documentEdited"])
        for action in ("close", "quit", "reload"):
            self.action(action)
            self.choose(report, "Cancel")
            self.assert_running(process)
        self.action("close")
        self.choose(report, "Don’t Save")
        self.assertEqual(process.wait(timeout=5), 0)

    def test_paint_cancelled_save_keeps_picture_open(self):
        process, report, _ = self.paint()
        self.action("quit")
        self.choose(report, "Save")
        self.wait_for(lambda: (report / "file-panel.json").exists(), "Save panel")
        self.action("cancelFilePanel")
        self.wait_for(lambda: not (report / "file-panel.json").exists(), "cancelled Save panel")
        self.assert_running(process)
        # A second prompt proves the cancelled save has not cleared the dirty state.
        self.action("close")
        self.choose(report, "Cancel")
        self.assert_running(process)
        self.action("close")
        self.choose(report, "Don’t Save")
        self.assertEqual(process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
