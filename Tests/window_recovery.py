#!/usr/bin/env python3
"""Exercise the packaged app without touching the normal Browser profile.

Launch a separately identified test bundle with BROWSER_PROBE=window-live,
Enable that profile's test socket first:
  defaults write com.agencidev.browser.test.window-live bench -bool true
Then run: python3 Tests/window_recovery.py --world window-live --app /path/to/Test.app
The fixture connects two local WebRTC peers; no camera, microphone or server
outside this machine is used. Finder's reopen AppleEvent restores each window.
"""
import argparse
import http.server
import json
import os
import socket
import struct
import subprocess
import threading
import time

FIXTURE = b"""<!doctype html><title>Window recovery test</title>
<body>Local WebRTC connection survives window recovery<script>
window.token = crypto.randomUUID(); window.received = 0; window.rtcError = ''; window.phase = 'init';
const config = {iceServers: [{urls: 'stun:127.0.0.1:STUN_PORT'}]};
window.left = new RTCPeerConnection(config);
window.right = new RTCPeerConnection(config);
const pendingLeft = [], pendingRight = [];
left.onicecandidate = e => { if (e.candidate) {
  if (right.remoteDescription) right.addIceCandidate(e.candidate);
  else pendingRight.push(e.candidate);
}};
right.onicecandidate = e => { if (e.candidate) {
  if (left.remoteDescription) left.addIceCandidate(e.candidate);
  else pendingLeft.push(e.candidate);
}};
right.ondatachannel = e => { e.channel.onmessage = () => window.received++; };
window.channel = left.createDataChannel('meeting');
setInterval(() => { if (channel.readyState === 'open') channel.send('still-connected'); }, 100);
(async () => {
  window.phase = 'offer';
  await left.setLocalDescription(await left.createOffer());
  window.phase = 'remote-offer';
  await right.setRemoteDescription(left.localDescription);
  for (const c of pendingRight) await right.addIceCandidate(c);
  await right.setLocalDescription(await right.createAnswer());
  window.phase = 'remote-answer';
  await left.setRemoteDescription(right.localDescription);
  for (const c of pendingLeft) await left.addIceCandidate(c);
  window.phase = 'negotiated';
})().catch(e => window.rtcError = String(e));
</script></body>"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', required=True)
    parser.add_argument('--app', required=True)
    args = parser.parse_args()
    if not args.world or not all(c.isascii() and (c.isalnum() or c == '-') for c in args.world):
        parser.error('a named test world is required')
    path = os.path.expanduser(f'~/Library/Application Support/Browser ({args.world})/bench.sock')

    def ask(verb, **values):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(10)
            client.connect(path)
            client.sendall((json.dumps({'do': verb, **values}) + '\n').encode())
            data = b''
            while b'\n' not in data:
                part = client.recv(65536)
                if not part:
                    break
                data += part
        reply = json.loads(data)
        assert 'error' not in reply, reply
        return reply

    def until(check, label):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            result = check()
            if result:
                return result
            time.sleep(0.1)
        raise AssertionError(f'Timed out: {label}')

    # WebKit can withhold host candidates without camera permission. A local
    # STUN binding responder provides reflexive candidates without asking for
    # a real capture device or sending anything to an external STUN service.
    stun = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stun.bind(('127.0.0.1', 0))
    stun.settimeout(0.2)
    stop = threading.Event()

    def bindings():
        while not stop.is_set():
            try:
                packet, sender = stun.recvfrom(2048)
            except socket.timeout:
                continue
            if len(packet) < 20 or packet[:2] != b'\x00\x01':
                continue
            ip = struct.unpack('!I', socket.inet_aton(sender[0]))[0] ^ 0x2112A442
            mapped = struct.pack('!HHBBHI', 0x0020, 8, 0, 1, sender[1] ^ 0x2112, ip)
            stun.sendto(struct.pack('!HH', 0x0101, len(mapped)) + packet[4:20] + mapped, sender)

    threading.Thread(target=bindings, daemon=True).start()
    fixture = FIXTURE.replace(b'STUN_PORT', str(stun.getsockname()[1]).encode())

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(fixture)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tab = None
    try:
        ask('ui', welcome=False)
        tab = ask('open', url=f'http://127.0.0.1:{server.server_port}/')['id']
        ask('select', id=tab)

        def state():
            return ask('eval', id=tab, js="JSON.stringify({token:window.token, received:window.received, left:window.left?.connectionState, right:window.right?.connectionState, error:window.rtcError, phase:window.phase, ice:window.left?.iceGatheringState})")['value']

        initial = until(lambda: (s if s.get('received', 0) > 0 else None)
                        if (s := json.loads(state())) else None, 'local WebRTC connection')

        def visible():
            p = ask('probe')
            return next((w for w in p['windows'] if w['number'] == p['browserWindow']
                         and w['visible'] and not w['miniaturized'] and w['alpha'] == 1
                         and w['onActiveSpace'] and not w['occluded']), None)

        for action in ['orderOut', 'transparent', 'offscreen', 'minimize', 'close', 'close', 'close', 'fullscreen', 'fullscreen']:
            before = json.loads(state())
            ask('window-test', action=action)
            time.sleep(1.5 if action == 'fullscreen' else 0.5)
            # LaunchServices sends the same reopen event as a Dock click.
            subprocess.run(['open', '-a', os.path.abspath(args.app)], check=True)
            window = until(visible, f'{action} window recovery')
            after = until(lambda: (s if s.get('received', 0) > before['received'] else None)
                          if (s := json.loads(state())) else None, f'{action} WebRTC continuity')
            assert after['token'] == initial['token'], (action, 'page was reloaded')
            assert after['left'] == after['right'] == 'connected', (action, after)
            assert not after['error'], after
            print(f"PASS {action}: window {window['number']}, same page, connected, messages {before['received']} -> {after['received']}", flush=True)
    except Exception:
        if tab is not None:
            print('Fixture state:', state(), flush=True)
        raise
    finally:
        if tab is not None:
            ask('close', id=tab)
        server.shutdown()
        stop.set()


if __name__ == '__main__':
    main()
