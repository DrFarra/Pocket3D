#!/usr/bin/env python3
"""Pocket3D PC: recibe en vivo lo que escanea el iPhone (modo Espacio) y lo procesa con la GPU del PC.

    python pocket3d_pc.py                      # recibe, muestra el escaneo en vivo y arma el dataset
    python pocket3d_pc.py --al-terminar "CMD"  # además, al terminar ejecuta CMD ({datos} = carpeta, {salida} = .ply)

Abre http://localhost:8765 para ver el escaneo crecer mientras escaneas. Solo usa la biblioteca estándar;
si está instalado `zeroconf` (pip install zeroconf) el iPhone encuentra el PC solo, si no, escribe la IP en la app.
"""
import argparse
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

try:   # fusión en vivo (modo PC): opcional, necesita numpy y open3d
    import fusion as fusion_engine
except ImportError:
    fusion_engine = None

PORT = 8765
SERVICE = "_pocket3d._tcp.local."
# Solo estos nombres se pueden escribir: nada de rutas con «..» ni archivos fuera de la carpeta del escaneo.
ALLOWED_FILE = re.compile(r"^(images/\d{5}\.jpg|depth/\d{5}\.png|mesh\.glb|mesh\.ply)$")
SCAN_ID = re.compile(r"^\d{8}-\d{6}$")
MAX_UPLOAD = 64 * 1024 * 1024


class Scan:
    def __init__(self, root: Path):
        self.id = time.strftime("%Y%m%d-%H%M%S")
        self.dir = root / self.id
        (self.dir / "images").mkdir(parents=True, exist_ok=True)
        (self.dir / "depth").mkdir(exist_ok=True)
        self.frames = []
        self.mesh_version = 0
        # Malla en vivo calculada aquí con la profundidad LiDAR y las poses que manda el iPhone.
        self.fusion = fusion_engine.Fusion(self.dir) if fusion_engine else None
        self.state = "recibiendo"   # recibiendo → procesando → listo / falló
        self.log = []
        self.lock = threading.Lock()

    @property
    def result(self) -> Path:
        return self.dir / "resultado.ply"

    @property
    def final_mesh(self) -> Path:
        return self.dir / "malla.ply"

    def add_frame(self, entry: dict):
        if not isinstance(entry, dict) or not ALLOWED_FILE.match(str(entry.get("file_path", ""))):
            raise ValueError("fotograma sin file_path válido")
        with self.lock:
            self.frames.append(entry)
            self.write_transforms()
        if self.fusion:
            self.fusion.add(entry)

    def write_transforms(self):
        """transforms.json siempre al día y válido: se puede entrenar aunque el iPhone se desconecte a medias."""
        meta = {"camera_model": "OPENCV", "frames": sorted(self.frames, key=lambda f: f["file_path"])}
        # Nube de partida del splat: la malla del iPhone o, en modo PC, la fusionada aquí.
        for cloud in ("mesh.ply", "malla.ply"):
            if (self.dir / cloud).exists():
                meta["ply_file_path"] = cloud
                break
        tmp = self.dir / "transforms.json.tmp"
        tmp.write_text(json.dumps(meta, indent=1))
        os.replace(tmp, self.dir / "transforms.json")

    def status(self) -> dict:
        with self.lock:
            cameras = [[f["transform_matrix"][r][3] for r in range(3)] for f in self.frames if "transform_matrix" in f]
            return {"id": self.id, "frames": len(self.frames), "mesh": self.mesh_version, "state": self.state,
                    "result": self.result.exists() and self.state == "listo", "cameras": cameras,
                    "preview": self.fusion.version if self.fusion else 0, "final_mesh": self.final_mesh.exists(),
                    "log": self.log[-6:], "folder": str(self.dir)}


class App:
    def __init__(self, root: Path, command: str | None):
        self.root = root
        self.command = command
        self.scans: dict[str, Scan] = {}
        self.current: Scan | None = None

    def new_scan(self) -> Scan:
        scan = Scan(self.root)
        while scan.id in self.scans:   # dos en el mismo segundo
            time.sleep(1)
            scan = Scan(self.root)
        self.scans[scan.id] = scan
        self.current = scan
        print(f"\n▶ Nuevo escaneo: {scan.dir}", flush=True)
        return scan

    def finish(self, scan: Scan):
        scan.write_transforms()
        print(f"■ Escaneo terminado: {len(scan.frames)} fotos en {scan.dir}", flush=True)
        if not self.command and not scan.fusion:
            scan.state = "listo"
            scan.log.append("Dataset listo (sin --al-terminar no se procesa).")
            return
        scan.state = "procesando"
        threading.Thread(target=self.process, args=(scan,), daemon=True).start()

    def process(self, scan: Scan):
        if scan.fusion:
            scan.log.append("Calculando la malla final…")
            print("⚙ Malla final (TSDF)…", flush=True)
            try:
                mesh = scan.fusion.final()
                scan.log.append("Malla final lista." if mesh else "No salió malla: ¿llegó la profundidad LiDAR?")
                scan.write_transforms()   # ahora con la malla como nube de partida del splat
            except Exception as error:   # sin malla final, el dataset sigue sirviendo
                scan.log.append(f"Malla final: {error}")
        if not self.command:
            scan.state = "listo"
            print("✔ Listo: " + str(scan.final_mesh), flush=True)
            return
        command = self.command.replace("{datos}", str(scan.dir)).replace("{salida}", str(scan.result))
        print(f"⚙ {command}", flush=True)
        try:
            proc = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors="replace", cwd=scan.dir)
            for line in proc.stdout:
                line = line.rstrip()
                if line:
                    print("  " + line, flush=True)
                    scan.log.append(line[-200:])
            ok = proc.wait() == 0 and scan.result.exists()
        except OSError as error:
            scan.log.append(str(error))
            ok = False
        scan.state = "listo" if ok else "falló"
        print(("✔ Resultado: " + str(scan.result)) if ok else "✖ El procesado falló (mira el registro).", flush=True)


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        server_version = "Pocket3D"

        def log_message(self, *args):  # el registro útil lo imprime App
            pass

        def send(self, code: int, body: bytes = b"", kind: str = "application/json"):
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def json(self, value, code: int = 200):
            self.send(code, json.dumps(value).encode())

        def body(self) -> bytes:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_UPLOAD:
                raise ValueError("demasiado grande")
            return self.rfile.read(length)

        def scan(self, scan_id: str) -> Scan | None:
            return app.scans.get(scan_id) if SCAN_ID.match(scan_id) else None

        def do_GET(self):
            parts = urlparse(self.path).path.strip("/").split("/")
            if parts == [""]:
                return self.send(200, VIEWER.encode(), "text/html; charset=utf-8")
            if parts == ["api", "hello"]:
                return self.json({"app": "pocket3d", "version": 1, "name": socket.gethostname()})
            if parts == ["api", "status"]:
                return self.json(app.current.status() if app.current else {})
            if len(parts) == 4 and parts[:2] == ["api", "scan"] and parts[3] == "status":
                scan = self.scan(parts[2])
                if scan:
                    return self.json(scan.status())
            if len(parts) == 4 and parts[:2] == ["api", "scan"] and parts[3] in ("mesh.glb", "resultado.ply", "preview.bin", "fused.glb", "malla.ply"):
                scan = self.scan(parts[2])
                path = scan and scan.dir / parts[3]
                if path and path.exists() and (parts[3] != "resultado.ply" or scan.state == "listo"):
                    return self.send(200, path.read_bytes(), "application/octet-stream")
            self.json({"error": "no existe"}, 404)

        def do_POST(self):
            parts = urlparse(self.path).path.strip("/").split("/")
            try:
                if parts == ["api", "scan"]:
                    return self.json({"id": app.new_scan().id})
                scan = len(parts) == 4 and parts[:2] == ["api", "scan"] and self.scan(parts[2])
                if scan and parts[3] == "frame":
                    scan.add_frame(json.loads(self.body()))
                    return self.json({"frames": len(scan.frames)})
                if scan and parts[3] == "finish":
                    app.finish(scan)
                    return self.json({"state": scan.state})
            except (ValueError, json.JSONDecodeError) as error:
                return self.json({"error": str(error)}, 400)
            self.json({"error": "no existe"}, 404)

        def do_PUT(self):
            # /api/scan/<id>/file/<images|depth>/<nombre>  o  /api/scan/<id>/file/mesh.glb
            path = urlparse(self.path).path.strip("/")
            match = re.match(r"^api/scan/([^/]+)/file/(.+)$", path)
            scan = match and self.scan(match.group(1))
            if not scan or not ALLOWED_FILE.match(match.group(2)):
                return self.json({"error": "ruta no permitida"}, 400)
            try:
                data = self.body()
            except ValueError as error:
                return self.json({"error": str(error)}, 413)
            target = scan.dir / match.group(2)
            tmp = target.with_suffix(target.suffix + ".tmp")
            tmp.write_bytes(data)
            os.replace(tmp, target)
            if match.group(2) == "mesh.glb":
                scan.mesh_version += 1
            self.json({"ok": True})

    return Handler


def local_ips() -> list[str]:
    ips = set()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))   # no envía nada: solo elige la interfaz de la red local
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    try:
        ips.update(a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def advertise(port: int):
    """Anuncia el PC por Bonjour para que la app lo encuentre sola. Sin zeroconf, la app usa la IP escrita a mano."""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        return None
    ips = local_ips()
    info = ServiceInfo(SERVICE, f"Pocket3D {socket.gethostname()}.{SERVICE}", port=port,
                       addresses=[socket.inet_aton(ip) for ip in ips], properties={"version": "1"})
    zc = Zeroconf()
    zc.register_service(info)
    return zc


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--carpeta", default=str(Path.home() / "Pocket3D"), help="dónde guardar los escaneos")
    parser.add_argument("--puerto", type=int, default=PORT)
    parser.add_argument("--al-terminar", dest="command", help="comando al terminar cada escaneo ({datos}, {salida})")
    args = parser.parse_args()

    root = Path(args.carpeta)
    root.mkdir(parents=True, exist_ok=True)
    app = App(root, args.command)
    server = ThreadingHTTPServer(("0.0.0.0", args.puerto), make_handler(app))
    zc = advertise(args.puerto)
    print("Pocket3D PC listo.")
    print(f"  Escaneos en: {root}")
    for ip in local_ips():
        print(f"  En la app (PC → dirección): {ip}")
    print(f"  Mira el escaneo en vivo: http://localhost:{args.puerto}")
    print("  Búsqueda automática: " + ("activada" if zc else "desactivada (pip install zeroconf para activarla)"))
    print("  Modo PC (malla en vivo): " + ("activado" if fusion_engine else "desactivado (pip install open3d==0.19.0)"))
    print("  Si Windows pregunta por el firewall, permite el acceso en redes privadas.\n", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if zc:
            zc.close()


VIEWER = """<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pocket3D en vivo</title>
<style>
 :root{--bg:#0d0f14;--fg:#e8eaf0;--muted:#8a90a0;--accent:#ff4f9a}
 html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:15px system-ui,sans-serif}
 #hud{position:fixed;top:16px;left:16px;right:16px;display:flex;gap:12px;flex-wrap:wrap;pointer-events:none}
 .card{background:#1a1d26cc;border-radius:12px;padding:10px 14px;backdrop-filter:blur(8px)}
 .big{font-size:22px;font-weight:600}.muted{color:var(--muted);font-size:13px}
 #log{position:fixed;bottom:16px;left:16px;right:16px;font:12px ui-monospace,monospace;color:var(--muted);white-space:pre-wrap}
 a{color:var(--accent)}
</style>
<script type="importmap">{"imports":{"three":"https://unpkg.com/three@0.160.0/build/three.module.js","three/addons/":"https://unpkg.com/three@0.160.0/examples/jsm/"}}</script>
</head><body>
<div id="hud">
 <div class="card"><div class="big" id="state">Esperando al iPhone…</div><div class="muted" id="folder">Abre el modo Espacio en la app</div></div>
 <div class="card"><div class="big" id="frames">0</div><div class="muted">fotos recibidas</div></div>
 <div class="card" id="resultCard" hidden><a id="result" download>Descargar resultado</a></div>
</div>
<div id="log"></div>
<script type="module">
import * as THREE from "three";
import {OrbitControls} from "three/addons/controls/OrbitControls.js";
import {GLTFLoader} from "three/addons/loaders/GLTFLoader.js";
const renderer=new THREE.WebGLRenderer({antialias:true});renderer.setPixelRatio(devicePixelRatio);
document.body.appendChild(renderer.domElement);
const scene=new THREE.Scene();scene.background=new THREE.Color(0x0d0f14);
const camera=new THREE.PerspectiveCamera(60,1,0.01,200);camera.position.set(3,3,3);
const controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;
scene.add(new THREE.HemisphereLight(0xffffff,0x334455,1.4));
const sun=new THREE.DirectionalLight(0xffffff,1.2);sun.position.set(2,5,3);scene.add(sun);
scene.add(new THREE.GridHelper(10,20,0x333844,0x22252e));
const cams=new THREE.Points(new THREE.BufferGeometry(),new THREE.PointsMaterial({color:0xff4f9a,size:0.06}));scene.add(cams);
const path=new THREE.Line(new THREE.BufferGeometry(),new THREE.LineBasicMaterial({color:0xff4f9a,transparent:true,opacity:.5}));scene.add(path);
let mesh=null,meshVersion=-1,scanId=null,framed=false;const loader=new GLTFLoader();
function resize(){renderer.setSize(innerWidth,innerHeight);camera.aspect=innerWidth/innerHeight;camera.updateProjectionMatrix()}
addEventListener("resize",resize);resize();
async function poll(){
 try{
  const s=await (await fetch("/api/status")).json();
  if(s.id){
   if(s.id!==scanId){scanId=s.id;meshVersion=-1;framed=false;if(mesh){scene.remove(mesh);mesh=null}}
   document.getElementById("state").textContent={recibiendo:"Recibiendo en vivo",procesando:"Procesando con la GPU…",listo:"Listo","falló":"El procesado falló"}[s.state]||s.state;
   document.getElementById("frames").textContent=s.frames;
   document.getElementById("folder").textContent=s.folder;
   document.getElementById("log").textContent=(s.log||[]).join("\\n");
   const p=new Float32Array(s.cameras.flat());
   cams.geometry.setAttribute("position",new THREE.BufferAttribute(p,3));path.geometry.setAttribute("position",new THREE.BufferAttribute(p,3));
   const card=document.getElementById("resultCard");card.hidden=!s.result;
   if(s.result)document.getElementById("result").href=`/api/scan/${s.id}/resultado.ply`;
   // Con fusión en el PC se ve su malla (en color); si no, la que manda el iPhone.
   const version=s.preview>0?1e6+s.preview:s.mesh, file=s.preview>0?"fused.glb":"mesh.glb";
   if(version!==meshVersion&&version>0){
    meshVersion=version;
    loader.load(`/api/scan/${s.id}/${file}?v=${version}`,g=>{
     if(mesh)scene.remove(mesh);mesh=g.scene;scene.add(mesh);
     if(!framed){const box=new THREE.Box3().setFromObject(mesh),c=box.getCenter(new THREE.Vector3()),r=box.getSize(new THREE.Vector3()).length();
      controls.target.copy(c);camera.position.copy(c).add(new THREE.Vector3(r*.6,r*.6,r*.6));framed=true}
    });
   }
  }
 }catch(e){document.getElementById("state").textContent="Sin conexión con Pocket3D PC"}
 setTimeout(poll,1000);
}
poll();
renderer.setAnimationLoop(()=>{controls.update();renderer.render(scene,camera)});
</script></body></html>"""

if __name__ == "__main__":
    main()
