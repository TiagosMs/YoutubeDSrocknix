#!/usr/bin/env python3
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8989
BASE_DIR = "/storage/roms/ports/youtube" if os.path.exists("/storage") else os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(BASE_DIR, "cache")
DOWNLOADS_DIR = os.path.join(BASE_DIR, "downloads")
DOWNLOADS_META = os.path.join(DOWNLOADS_DIR, "metadata.json")
AUTH_FILE = os.path.join(BASE_DIR, "auth.json")
SOCKET_PATH = "/tmp/mpvsocket"
YT_DLP_PATH = os.path.join(BASE_DIR, "yt-dlp")
QR_CACHE_FILE = os.path.join(CACHE_DIR, "qr_connect.png")

try:
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(DOWNLOADS_DIR, exist_ok=True)
except Exception:
    pass

stream_cache = {}
download_status = {}  # vid -> {"status": "downloading"|"completed"|"error", "progress": int, "title": str}
active_threads = {}

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def ensure_qr_code(ip=None):
    if not ip:
        ip = get_local_ip()
    target_url = f"http://{ip}:{PORT}/connect"
    if not os.path.exists(QR_CACHE_FILE) or os.path.getsize(QR_CACHE_FILE) < 100:
        try:
            api_url = f"https://api.qrserver.com/v1/create-qr-code/?size=240x240&format=png&data={urllib.parse.quote(target_url)}"
            req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                data = resp.read()
            if len(data) > 100:
                with open(QR_CACHE_FILE, "wb") as f:
                    f.write(data)
        except Exception:
            pass

def get_auth():
    if os.path.exists(AUTH_FILE):
        try:
            with open(AUTH_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"connected": False, "name": "", "cookies": "", "topics": [], "channels": []}

def save_auth(data):
    try:
        with open(AUTH_FILE, "w") as f:
            json.dump(data, f, indent=2)
        return True
    except Exception:
        return False

def parse_cookie_input(raw):
    raw = (raw or "").strip()
    if not raw:
        return ""
    if "\t" in raw or "\n" in raw:
        cookies = []
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 7:
                cookies.append(f"{parts[5]}={parts[6]}")
        if cookies:
            return "; ".join(cookies)
    return raw

def parse_csv_subscriptions(raw_text):
    channels = []
    for line in (raw_text or "").strip().splitlines():
        line = line.strip()
        if not line or line.startswith("Channel Id"):
            continue
        parts = line.split(",")
        if len(parts) >= 3:
            cid = parts[0].strip()
            title = parts[2].strip().strip('"')
            if cid and title:
                channels.append({"id": cid, "title": title})
    return channels

def mpv_send(cmd):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.4)
        s.connect(SOCKET_PATH)
        payload = json.dumps({"command": cmd}) + "\n"
        s.sendall(payload.encode())
        s.close()
    except Exception:
        pass

def mpv_get_property(prop):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.2)
        s.connect(SOCKET_PATH)
        payload = json.dumps({"command": ["get_property", prop]}) + "\n"
        s.sendall(payload.encode())
        res = s.recv(1024).decode()
        s.close()
        data = json.loads(res.strip().split("\n")[0])
        return data.get("data")
    except Exception:
        return None

def parse_innertube_text(t):
    if not t:
        return ""
    if isinstance(t, str):
        return t
    if isinstance(t, dict):
        if "simpleText" in t:
            return t["simpleText"]
        if "runs" in t and isinstance(t["runs"], list):
            return "".join(r.get("text", "") for r in t["runs"])
    return ""

def extract_videos(data):
    results = []
    seen = set()

    def walk(obj):
        if isinstance(obj, dict):
            for k in ["videoRenderer", "compactVideoRenderer", "gridVideoRenderer"]:
                if k in obj:
                    vr = obj[k]
                    vid = vr.get("videoId")
                    if vid and vid not in seen:
                        seen.add(vid)
                        title = parse_innertube_text(vr.get("title"))
                        dur = parse_innertube_text(vr.get("lengthText")) or "--:--"
                        author = parse_innertube_text(vr.get("ownerText")) or parse_innertube_text(vr.get("shortBylineText")) or "YouTube"
                        views = parse_innertube_text(vr.get("viewCountText")) or parse_innertube_text(vr.get("shortViewCountText")) or "YouTube"
                        if title:
                            results.append({
                                "id": vid,
                                "title": title,
                                "duration": dur,
                                "channel": author,
                                "views": views,
                                "thumb_url": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
                            })
            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for it in obj:
                walk(it)

    walk(data)
    return results

def fetch_feed(query="", browse=None):
    auth = get_auth()
    cookies = auth.get("cookies", "")
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
        "X-YouTube-Client-Name": "1",
        "X-YouTube-Client-Version": "2.20240401.01.00"
    }
    if cookies:
        headers["Cookie"] = cookies

    if browse in ("home", "recommendations"):
        if cookies:
            try:
                url = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"
                payload = {
                    "context": {
                        "client": {
                            "clientName": "WEB",
                            "clientVersion": "2.20240401.01.00",
                            "hl": "pt",
                            "gl": "BR",
                            "utcOffsetMinutes": -180
                        }
                    },
                    "browseId": "FEwhat_to_watch"
                }
                req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    data = json.loads(resp.read().decode())
                items = extract_videos(data)
                if items:
                    return items[:25]
            except Exception:
                pass

        topics = auth.get("topics", [])
        if topics:
            combined = []
            for t in topics[:3]:
                res = fetch_feed(query=t)
                combined.extend(res[:5])
            if combined:
                return combined[:25]

        channels = auth.get("channels", [])
        if channels:
            import random
            sample = channels[:5] if len(channels) <= 5 else random.sample(channels, 5)
            combined = []
            for ch in sample:
                res = fetch_feed(query=ch.get("title", ""))
                if res:
                    combined.extend(res[:3])
            if combined:
                return combined[:25]

        return fetch_feed(query="Retro Gaming")

    elif browse in ("subs", "subscriptions"):
        if cookies:
            try:
                url = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"
                payload = {
                    "context": {
                        "client": {
                            "clientName": "WEB",
                            "clientVersion": "2.20240401.01.00",
                            "hl": "pt",
                            "gl": "BR",
                            "utcOffsetMinutes": -180
                        }
                    },
                    "browseId": "FEsubscriptions"
                }
                req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    data = json.loads(resp.read().decode())
                items = extract_videos(data)
                if items:
                    return items[:25]
            except Exception:
                pass

        channels = auth.get("channels", [])
        if channels:
            import random
            sample = channels[:8] if len(channels) <= 8 else random.sample(channels, 8)
            combined = []
            for ch in sample:
                c_title = ch.get("title", "")
                if c_title:
                    res = fetch_feed(query=c_title)
                    if res:
                        combined.append(res[0])
            if combined:
                return combined[:25]
        return []

    # Standard Search
    q = (query or "Retro Gaming").strip()
    url = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
    payload = {
        "context": {
            "client": {
                "clientName": "WEB",
                "clientVersion": "2.20240401.01.00",
                "hl": "pt",
                "gl": "BR"
            }
        },
        "query": q
    }
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        items = extract_videos(data)
        return items[:25]
    except Exception:
        return []

def verify_and_get_user(cookie_str):
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
        "X-YouTube-Client-Name": "1",
        "X-YouTube-Client-Version": "2.20240401.01.00",
        "Cookie": cookie_str
    }
    url = "https://www.youtube.com/youtubei/v1/account/account_menu?prettyPrint=false"
    payload = {"context": {"client": {"clientName": "WEB", "clientVersion": "2.20240401.01.00"}}}
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        
        def find_name(obj):
            if isinstance(obj, dict):
                for k in ["accountName", "channelHandle", "title"]:
                    if k in obj:
                        txt = parse_innertube_text(obj[k])
                        if txt and "@" in txt or len(txt) > 2:
                            return txt
                for v in obj.values():
                    res = find_name(v)
                    if res: return res
            elif isinstance(obj, list):
                for it in obj:
                    res = find_name(it)
                    if res: return res
            return None

        name = find_name(data) or "Conta do YouTube"
        return True, name
    except Exception:
        return False, None

def get_stream_url(video_id):
    if video_id in stream_cache:
        return stream_cache[video_id]

    try:
        url = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
        payload = {
            "context": {
                "client": {
                    "clientName": "ANDROID",
                    "clientVersion": "21.26.364",
                    "androidSdkVersion": 30,
                    "userAgent": "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
                    "osName": "Android",
                    "osVersion": "11"
                }
            },
            "videoId": video_id,
            "contentCheckOk": True,
            "racyCheckOk": True
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "User-Agent": "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"
            }
        )
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode())
        formats = data.get("streamingData", {}).get("formats", [])
        for f in formats:
            stream_url = f.get("url")
            if stream_url:
                stream_cache[video_id] = stream_url
                return stream_url
    except Exception:
        pass

    # Fallback yt-dlp
    try:
        cmd = [YT_DLP_PATH, "--no-warnings", "-f", "18/b", "-g", f"https://www.youtube.com/watch?v={video_id}"]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=18)
        for line in res.stdout.strip().split("\n"):
            line = line.strip()
            if line.startswith("http"):
                stream_cache[video_id] = line
                return line
    except Exception:
        pass
    return None

# ========================================================
# DOWNLOADS & OFFLINE STORAGE
# ========================================================

def get_downloads_list():
    if not os.path.exists(DOWNLOADS_META):
        return []
    try:
        with open(DOWNLOADS_META, "r") as f:
            items = json.load(f)
        valid = []
        for it in items:
            vid = it.get("id")
            mp4_path = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4")
            if os.path.exists(mp4_path):
                it["file_path"] = mp4_path
                it["size_mb"] = round(os.path.getsize(mp4_path) / (1024 * 1024), 1)
                valid.append(it)
        return valid
    except Exception:
        return []

def save_downloads_list(items):
    try:
        with open(DOWNLOADS_META, "w") as f:
            json.dump(items, f, indent=2)
        return True
    except Exception:
        return False

def delete_download_item(vid):
    mp4_path = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4")
    jpg_path = os.path.join(DOWNLOADS_DIR, f"{vid}.jpg")
    part_path = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4.part")
    for p in [mp4_path, jpg_path, part_path]:
        try:
            if os.path.exists(p):
                os.remove(p)
        except Exception:
            pass
    items = get_downloads_list()
    items = [it for it in items if it.get("id") != vid]
    save_downloads_list(items)
    if vid in download_status:
        del download_status[vid]
    return True

def run_download_task(vid, title, channel, duration):
    download_status[vid] = {"status": "downloading", "progress": 5, "title": title}
    mp4_final = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4")
    mp4_part = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4.part")
    jpg_final = os.path.join(DOWNLOADS_DIR, f"{vid}.jpg")

    try:
        # 1. Download Thumbnail
        thumb_url = f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
        try:
            req_t = urllib.request.Request(thumb_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req_t, timeout=4) as resp:
                with open(jpg_final, "wb") as f_thumb:
                    f_thumb.write(resp.read())
        except Exception:
            pass

        # 2. Get stream URL
        stream_url = get_stream_url(vid)
        if not stream_url:
            # Fallback yt-dlp direct download
            cmd = [YT_DLP_PATH, "-f", "18/b", "-o", mp4_final, f"https://www.youtube.com/watch?v={vid}"]
            subprocess.run(cmd, timeout=300)
        else:
            req = urllib.request.Request(stream_url, headers={"User-Agent": "com.google.android.youtube/21.26.364"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                total_len = int(resp.headers.get("Content-Length", 0))
                downloaded = 0
                with open(mp4_part, "wb") as f_out:
                    while True:
                        chunk = resp.read(64 * 1024)
                        if not chunk:
                            break
                        f_out.write(chunk)
                        downloaded += len(chunk)
                        if total_len > 0:
                            pct = int((downloaded / total_len) * 95)
                            download_status[vid]["progress"] = max(5, pct)
            if os.path.exists(mp4_part):
                os.replace(mp4_part, mp4_final)

        if os.path.exists(mp4_final) and os.path.getsize(mp4_final) > 10000:
            size_mb = round(os.path.getsize(mp4_final) / (1024 * 1024), 1)
            items = get_downloads_list()
            # Remove duplicate if exists
            items = [it for it in items if it.get("id") != vid]
            items.insert(0, {
                "id": vid,
                "title": title or "Vídeo",
                "channel": channel or "YouTube",
                "duration": duration or "--:--",
                "size_mb": size_mb,
                "date": time.strftime("%d/%m/%Y"),
                "file_path": mp4_final,
                "thumb_path": jpg_final
            })
            save_downloads_list(items)
            download_status[vid] = {"status": "completed", "progress": 100, "title": title}
        else:
            download_status[vid] = {"status": "error", "progress": 0, "title": title}
    except Exception as e:
        download_status[vid] = {"status": "error", "progress": 0, "title": title, "error": str(e)}

def start_download_thread(vid, title, channel, duration):
    if vid in download_status and download_status[vid]["status"] == "downloading":
        return
    t = threading.Thread(target=run_download_task, args=(vid, title, channel, duration), daemon=True)
    active_threads[vid] = t
    t.start()

CONNECT_HTML = """<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>YouTube DS - Conectar Conta Google</title>
<style>
  * { box-sizing: border-box; }
  body { background: #0f0f0f; color: #f1f1f1; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 0; padding: 20px 14px; }
  .container { max-width: 600px; margin: 0 auto; }
  .header { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; }
  .logo { background: #ff0000; color: white; font-weight: 900; padding: 7px 12px; border-radius: 8px; font-size: 16px; letter-spacing: -0.5px; }
  .title { font-size: 20px; font-weight: 700; }
  .badge { display: inline-block; padding: 5px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; margin-bottom: 16px; }
  .badge-off { background: #333; color: #aaa; }
  .badge-on { background: #0e7039; color: #a4f4c2; border: 1px solid #1ba558; }
  .card { background: #1f1f1f; border-radius: 12px; padding: 18px; margin-bottom: 16px; border: 1px solid #333; }
  .card h3 { margin-top: 0; color: #fff; font-size: 16px; display: flex; align-items: center; gap: 8px; }
  .card p { color: #aaa; font-size: 13.5px; line-height: 1.5; margin-bottom: 12px; }
  .step { background: #141414; padding: 10px 12px; border-radius: 6px; margin-bottom: 8px; font-size: 13px; color: #ccc; border-left: 3px solid #ff0000; }
  .drop-zone { border: 2px dashed #444; border-radius: 10px; padding: 18px; text-align: center; cursor: pointer; transition: border-color 0.2s, background 0.2s; margin-bottom: 12px; }
  .drop-zone:hover { border-color: #ff0000; background: #262626; }
  .drop-zone span { display: block; font-size: 14px; font-weight: 600; color: #fff; margin-bottom: 4px; }
  .drop-zone small { color: #888; font-size: 12px; }
  textarea, input[type="text"] { width: 100%; background: #121212; border: 1px solid #444; border-radius: 8px; color: #fff; padding: 12px; font-size: 13px; margin-bottom: 12px; font-family: inherit; }
  textarea { min-height: 90px; font-family: monospace; font-size: 11px; }
  button { background: #cc0000; color: white; border: none; padding: 12px 18px; border-radius: 8px; font-size: 14px; font-weight: bold; cursor: pointer; width: 100%; transition: background 0.2s; }
  button:hover { background: #ff0000; }
  button.sec { background: #333; margin-top: 8px; }
  button.sec:hover { background: #444; }
  .alert { padding: 12px 14px; border-radius: 8px; margin-bottom: 16px; display: none; font-size: 13.5px; line-height: 1.4; }
  .alert-success { background: #135200; color: #b7eb8f; border: 1px solid #237804; }
  .alert-error { background: #5c0011; color: #ffa39e; border: 1px solid #820014; }
  a { color: #3ea6ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="logo">▶ YouTube DS</div>
    <div class="title">Conectar Conta Google</div>
  </div>

  <div id="statusBadge" class="badge badge-off">Carregando status...</div>
  <div id="alertBox" class="alert"></div>

  <!-- Método 1: Upload cookies.txt -->
  <div class="card">
    <h3>🍪 Método 1: Arquivo cookies.txt (Recomendado)</h3>
    <p>Conecta sua conta real trazendo suas <b>Recomendações Reais da Home</b> e <b>Canais Inscritos</b>.</p>
    
    <div class="step">1. No navegador do seu computador (Chrome, Edge ou Firefox), acesse o YouTube logado na sua conta Google.</div>
    <div class="step">2. Instale a extensão <b>Get cookies.txt LOCALLY</b> e clique nela para baixar o arquivo <code>cookies.txt</code>.</div>
    <div class="step">3. Clique na área abaixo ou selecione o arquivo baixado:</div>
    
    <div class="drop-zone" onclick="document.getElementById('fileCookie').click()">
      <span>📁 Selecionar arquivo cookies.txt</span>
      <small>Clique para escolher o arquivo baixado no seu PC/celular</small>
      <input type="file" id="fileCookie" accept=".txt" style="display:none;" onchange="handleCookieFile(event)">
    </div>

    <details style="margin-top: 10px; font-size: 12.5px; color: #888;">
      <summary style="cursor: pointer; color: #aaa; margin-bottom: 8px;">Ou colar texto dos cookies manualmente</summary>
      <textarea id="cookiesInput" placeholder="Cole aqui o conteúdo do arquivo de cookies ou cabeçalho..."></textarea>
      <button onclick="saveCookies()">Conectar via Cookies</button>
    </details>
  </div>

  <!-- Método 2: Google Takeout (Sem cookies) -->
  <div class="card">
    <h3>📂 Método 2: Importar Inscrições do Google Takeout</h3>
    <p>Não quer lidar com extensões ou cookies? O Google permite baixar sua lista oficial de inscrições com 1 clique:</p>
    
    <div class="step">1. Acesse o <a href="https://takeout.google.com/takeout/custom/youtube" target="_blank">Google Takeout (YouTube)</a> com sua conta.</div>
    <div class="step">2. Deixe marcado apenas <b>Inscrições</b> e baixe o arquivo <code>subscriptions.csv</code>.</div>
    <div class="step">3. Envie o arquivo abaixo para carregar todos os seus canais:</div>

    <div class="drop-zone" onclick="document.getElementById('fileCsv').click()" style="border-color: #2563eb;">
      <span style="color:#60a5fa;">📄 Selecionar subscriptions.csv</span>
      <small>Importa todos os canais inscritos da sua conta Google</small>
      <input type="file" id="fileCsv" accept=".csv" style="display:none;" onchange="handleCsvFile(event)">
    </div>
  </div>

  <!-- Método 3: Tópicos Personalizados -->
  <div class="card">
    <h3>⚡ Método 3: Tópicos & Canais Favoritos</h3>
    <p>Digite tópicos ou canais favoritos separados por vírgula para criar seu feed:</p>
    <input type="text" id="topicsInput" placeholder="Ex: Jogos Retrô, Nintendo DS, Gameplay, Speedruns">
    <button onclick="saveTopics()" style="background: #2563eb;">Salvar Tópicos</button>
  </div>

  <div id="logoutSection" style="display:none;" class="card">
    <button class="sec" onclick="logout()">Desconectar Conta do Console</button>
  </div>
</div>

<script>
async function loadStatus() {
  try {
    const res = await fetch('/auth/status');
    const data = await res.json();
    const badge = document.getElementById('statusBadge');
    const logoutSec = document.getElementById('logoutSection');
    if (data.connected) {
      badge.className = 'badge badge-on';
      badge.innerText = '✅ Conectado como: ' + (data.name || 'Conta Google');
      logoutSec.style.display = 'block';
    } else {
      badge.className = 'badge badge-off';
      badge.innerText = '⚪ Nenhuma conta conectada';
      logoutSec.style.display = 'none';
    }
  } catch(e) {}
}

function showAlert(msg, isSuccess) {
  const box = document.getElementById('alertBox');
  box.className = 'alert ' + (isSuccess ? 'alert-success' : 'alert-error');
  box.innerText = msg;
  box.style.display = 'block';
  window.scrollTo({top: 0, behavior: 'smooth'});
}

function handleCookieFile(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = function(evt) {
    document.getElementById('cookiesInput').value = evt.target.result;
    saveCookies();
  };
  reader.readAsText(file);
}

function handleCsvFile(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = async function(evt) {
    showAlert('Importando inscrições do Google Takeout...', true);
    try {
      const res = await fetch('/connect', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({csv: evt.target.result})
      });
      const d = await res.json();
      if (d.success) {
        showAlert('✅ ' + d.name + ' importada com sucesso! Olhe seu console.', true);
        loadStatus();
      } else {
        showAlert('⚠️ ' + (d.message || 'Erro ao importar CSV.'), false);
      }
    } catch(err) {
      showAlert('Erro ao enviar CSV.', false);
    }
  };
  reader.readAsText(file);
}

async function saveCookies() {
  const raw = document.getElementById('cookiesInput').value;
  if (!raw.trim()) { showAlert('Selecione o arquivo de cookies antes de salvar.', false); return; }
  showAlert('Validando sessão com o YouTube...', true);
  try {
    const res = await fetch('/connect', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({cookies: raw})
    });
    const d = await res.json();
    if (d.success) {
      showAlert('✅ Conta conectada como: ' + d.name + '! Olhe a tela do console.', true);
      loadStatus();
    } else {
      showAlert('⚠️ ' + (d.message || 'Erro ao validar cookies.'), false);
    }
  } catch(e) {
    showAlert('Erro de conexão com o servidor local.', false);
  }
}

async function saveTopics() {
  const val = document.getElementById('topicsInput').value;
  if (!val.trim()) { showAlert('Digite ao menos um tópico.', false); return; }
  try {
    const res = await fetch('/connect', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({topics: val})
    });
    const d = await res.json();
    if (d.success) {
      showAlert('✅ Feed configurado com sucesso!', true);
      loadStatus();
    }
  } catch(e) {
    showAlert('Erro de conexão.', false);
  }
}

async function logout() {
  if (!confirm('Deseja realmente desconectar?')) return;
  await fetch('/auth/logout', {method: 'POST'});
  showAlert('Conta desconectada do console.', true);
  loadStatus();
}

loadStatus();
</script>
</body>
</html>
"""

class APIHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/feed":
            browse = params.get("browse", [None])[0]
            q = params.get("q", [""])[0]
            items = fetch_feed(query=q, browse=browse)
            self.send_json(items)

        elif parsed.path == "/auth/status":
            auth = get_auth()
            ip = get_local_ip()
            ensure_qr_code(ip)
            self.send_json({
                "connected": auth.get("connected", False),
                "name": auth.get("name", ""),
                "ip": ip,
                "port": PORT,
                "connect_url": f"http://{ip}:{PORT}/connect"
            })

        elif parsed.path == "/qr":
            ip = get_local_ip()
            ensure_qr_code(ip)
            if os.path.exists(QR_CACHE_FILE):
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(os.path.getsize(QR_CACHE_FILE)))
                self.end_headers()
                with open(QR_CACHE_FILE, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()

        elif parsed.path == "/downloads":
            items = get_downloads_list()
            self.send_json({
                "downloads": items,
                "active": download_status
            })

        elif parsed.path == "/download/status":
            vid = params.get("id", [""])[0]
            st = download_status.get(vid, {"status": "none", "progress": 0})
            self.send_json(st)

        elif parsed.path == "/connect":
            body = CONNECT_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif parsed.path == "/auth/logout":
            save_auth({"connected": False, "name": "", "cookies": "", "topics": []})
            self.send_json({"success": True})

        elif parsed.path == "/stream":
            vid = params.get("id", [""])[0]
            url = get_stream_url(vid) if vid else None
            self.send_json({"url": url})

        elif parsed.path == "/mpv":
            action = params.get("action", [""])[0]
            if action == "play":
                vid = params.get("id", [""])[0]
                url = get_stream_url(vid) if vid else None
                if url:
                    mpv_send(["loadfile", url, "replace"])
                    self.send_json({"status": "playing", "url": url})
                else:
                    self.send_json({"status": "error", "message": "no_stream"})
            elif action == "play_local":
                vid = params.get("id", [""])[0]
                mp4_file = os.path.join(DOWNLOADS_DIR, f"{vid}.mp4")
                if os.path.exists(mp4_file):
                    mpv_send(["loadfile", mp4_file, "replace"])
                    self.send_json({"status": "playing_local", "file": mp4_file})
                else:
                    self.send_json({"status": "error", "message": "file_not_found"})
            elif action == "preview":
                vid = params.get("id", [""])[0]
                if vid:
                    local_jpg = os.path.join(DOWNLOADS_DIR, f"{vid}.jpg")
                    if os.path.exists(local_jpg):
                        mpv_send(["loadfile", local_jpg, "replace"])
                    else:
                        mpv_send(["loadfile", f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg", "replace"])
                self.send_json({"status": "previewing"})
            elif action == "pause":
                mpv_send(["cycle", "pause"])
                self.send_json({"status": "paused_cycled"})
            elif action == "stop":
                mpv_send(["stop"])
                self.send_json({"status": "stopped"})
            elif action == "seek":
                val = int(params.get("val", [10])[0])
                mpv_send(["seek", val, "relative"])
                self.send_json({"status": "seeked"})
            elif action == "vol":
                val = int(params.get("val", [5])[0])
                mpv_send(["add", "volume", val])
                self.send_json({"status": "volume_adjusted"})
            else:
                self.send_json({"status": "unknown_action"})

        elif parsed.path == "/status":
            pos = mpv_get_property("time-pos") or 0
            dur = mpv_get_property("duration") or 0
            pause = mpv_get_property("pause")
            vol = mpv_get_property("volume") or 100
            self.send_json({
                "time_pos": pos,
                "duration": dur,
                "pause": bool(pause),
                "volume": vol
            })

        elif parsed.path == "/thumb":
            vid = params.get("id", [""])[0]
            # Check offline downloaded thumbnail first
            local_thumb = os.path.join(DOWNLOADS_DIR, f"{vid}.jpg")
            cache_file = os.path.join(CACHE_DIR, f"{vid}.jpg")
            target_file = local_thumb if os.path.exists(local_thumb) else cache_file

            if not os.path.exists(target_file):
                try:
                    url = f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
                    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
                    with urllib.request.urlopen(req, timeout=3) as resp:
                        data = resp.read()
                    with open(cache_file, "wb") as f:
                        f.write(data)
                    target_file = cache_file
                except Exception:
                    pass

            if os.path.exists(target_file):
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(os.path.getsize(target_file)))
                self.end_headers()
                with open(target_file, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        content_len = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_len).decode("utf-8", errors="ignore") if content_len > 0 else ""

        if parsed.path == "/download":
            try:
                data = json.loads(raw_body)
            except Exception:
                data = dict(urllib.parse.parse_qsl(raw_body))
            vid = data.get("id", "")
            title = data.get("title", "Vídeo")
            channel = data.get("channel", "YouTube")
            duration = data.get("duration", "--:--")
            if vid:
                start_download_thread(vid, title, channel, duration)
                self.send_json({"success": True, "status": "started", "id": vid})
            else:
                self.send_json({"success": False, "message": "missing_id"})

        elif parsed.path == "/download/delete":
            try:
                data = json.loads(raw_body)
            except Exception:
                data = dict(urllib.parse.parse_qsl(raw_body))
            vid = data.get("id", "")
            if vid:
                delete_download_item(vid)
                self.send_json({"success": True, "status": "deleted", "id": vid})
            else:
                self.send_json({"success": False, "message": "missing_id"})

        elif parsed.path == "/connect":
            try:
                data = json.loads(raw_body)
            except Exception:
                data = dict(urllib.parse.parse_qsl(raw_body))

            if "cookies" in data:
                cookie_str = parse_cookie_input(data["cookies"])
                ok, name = verify_and_get_user(cookie_str)
                name = name or "Conta Google Conectada"
                save_auth({
                    "connected": True,
                    "name": name,
                    "cookies": cookie_str,
                    "topics": [],
                    "channels": []
                })
                self.send_json({"success": True, "name": name})
            elif "csv" in data:
                channels = parse_csv_subscriptions(data["csv"])
                if channels:
                    name = f"Google ({len(channels)} canais)"
                    save_auth({
                        "connected": True,
                        "name": name,
                        "cookies": "",
                        "topics": [c["title"] for c in channels[:10]],
                        "channels": channels
                    })
                    self.send_json({"success": True, "name": name, "count": len(channels)})
                else:
                    self.send_json({"success": False, "message": "Nenhum canal válido encontrado no arquivo subscriptions.csv"})
            elif "topics" in data:
                raw_topics = data["topics"]
                if isinstance(raw_topics, str):
                    topics = [t.strip() for t in raw_topics.split(",") if t.strip()]
                else:
                    topics = raw_topics
                save_auth({
                    "connected": True,
                    "name": "Feed Personalizado",
                    "cookies": "",
                    "topics": topics,
                    "channels": []
                })
                self.send_json({"success": True, "name": "Feed Personalizado"})
            else:
                self.send_json({"success": False, "message": "Dados inválidos"})

        elif parsed.path == "/auth/logout":
            save_auth({"connected": False, "name": "", "cookies": "", "topics": []})
            self.send_json({"success": True})
        else:
            self.send_response(404)
            self.end_headers()

    def send_json(self, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(("0.0.0.0", PORT), APIHandler)
    print(f"API server running on port {PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
