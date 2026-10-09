"""Prueba de pocket3d_pc.py con un iPhone simulado: python pc/test_pc.py"""
import json
import shlex
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pocket3d_pc as pc


class LiveScan(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        # «Entrenamiento» de prueba: copia la malla como resultado.
        copy = f"{shlex.quote(sys.executable)} -c \"import shutil; shutil.copy('mesh.ply', r'{{salida}}')\""
        self.app = pc.App(self.root, copy)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), pc.make_handler(self.app))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def call(self, method, path, data=b""):
        request = urllib.request.Request(self.base + path, data=data if method != "GET" else None, method=method)
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def test_scan_end_to_end(self):
        code, body = self.call("GET", "/api/hello")
        self.assertEqual((code, json.loads(body)["app"]), (200, "pocket3d"))

        scan_id = json.loads(self.call("POST", "/api/scan")[1])["id"]
        folder = self.root / scan_id
        self.assertEqual(self.call("PUT", f"/api/scan/{scan_id}/file/images/00000.jpg", b"jpeg")[0], 200)
        self.assertEqual(self.call("PUT", f"/api/scan/{scan_id}/file/depth/00000.png", b"png")[0], 200)
        entry = {"file_path": "images/00000.jpg", "depth_file_path": "depth/00000.png",
                 "transform_matrix": [[1, 0, 0, 0.5], [0, 1, 0, 1.5], [0, 0, 1, 2], [0, 0, 0, 1]]}
        self.assertEqual(self.call("POST", f"/api/scan/{scan_id}/frame", json.dumps(entry).encode())[0], 200)

        # La malla en vivo sube la versión que mira el visor.
        self.call("PUT", f"/api/scan/{scan_id}/file/mesh.glb", b"glb")
        status = json.loads(self.call("GET", "/api/status")[1])
        self.assertEqual((status["frames"], status["mesh"], status["cameras"]), (1, 1, [[0.5, 1.5, 2]]))
        self.assertEqual(self.call("GET", f"/api/scan/{scan_id}/mesh.glb")[1], b"glb")

        # Nada fuera de la carpeta del escaneo ni nombres inventados.
        for bad in ["../../evil.txt", "images/../../evil.jpg", "images/x.jpg", "transforms.json", "%2e%2e/evil"]:
            self.assertEqual(self.call("PUT", f"/api/scan/{scan_id}/file/{bad}", b"x")[0], 400, bad)
        self.assertEqual(self.call("PUT", "/api/scan/../file/mesh.glb", b"x")[0], 400)
        self.assertEqual(self.call("POST", f"/api/scan/{scan_id}/frame", b'{"file_path": "../x"}')[0], 400)
        self.assertFalse((self.root.parent / "evil.txt").exists())

        # transforms.json válido en todo momento, con la nube inicial cuando llega mesh.ply.
        self.call("PUT", f"/api/scan/{scan_id}/file/mesh.ply", b"ply")
        self.assertEqual(self.call("POST", f"/api/scan/{scan_id}/finish")[0], 200)
        meta = json.loads((folder / "transforms.json").read_text())
        self.assertEqual((meta["camera_model"], len(meta["frames"]), meta["ply_file_path"]), ("OPENCV", 1, "mesh.ply"))

        # El procesado corre en segundo plano y el resultado se puede bajar al iPhone.
        for _ in range(100):
            status = json.loads(self.call("GET", "/api/status")[1])
            if status["state"] != "procesando":
                break
            time.sleep(0.1)
        self.assertEqual((status["state"], status["result"]), ("listo", True), status["log"])
        self.assertEqual(self.call("GET", f"/api/scan/{scan_id}/resultado.ply"), (200, b"ply"))
        self.assertEqual(json.loads(self.call("GET", f"/api/scan/{scan_id}/status")[1])["state"], "listo")
        self.assertIn(b"three", self.call("GET", "/")[1])

    def test_failed_processing_is_reported(self):
        self.app.command = f"{shlex.quote(sys.executable)} -c \"raise SystemExit(3)\""
        scan_id = json.loads(self.call("POST", "/api/scan")[1])["id"]
        self.call("POST", f"/api/scan/{scan_id}/finish")
        for _ in range(100):
            status = json.loads(self.call("GET", "/api/status")[1])
            if status["state"] != "procesando":
                break
            time.sleep(0.1)
        self.assertEqual((status["state"], status["result"]), ("falló", False))
        self.assertEqual(self.call("GET", f"/api/scan/{scan_id}/resultado.ply")[0], 404)


if __name__ == "__main__":
    unittest.main()
