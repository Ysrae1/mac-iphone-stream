"""Pairing, device keys, and pinned HTTPS control for a local stream."""

from __future__ import annotations
import base64
import collections
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time

OPENSSL = '/usr/bin/openssl'
MAX_BODY = 8192
HEX64 = re.compile(r'^[0-9a-f]{64}$')
SPKI_PREFIX = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')

class Rejected(Exception):
    def __init__(self, code, status=400):
        self.code, self.status = code, status
        super().__init__(code)

def b64(data): return base64.b64encode(data).decode('ascii')
def sha(data): return hashlib.sha256(data).hexdigest()
def wire(*parts): return '\n'.join(parts).encode('utf-8')
def decode(value, size=None, maximum=256):
    if not isinstance(value, str) or len(value) > maximum * 2:
        raise Rejected('invalid_encoding')
    try: result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError): raise Rejected('invalid_encoding') from None
    if b64(result) != value or len(result) > maximum or (size is not None and len(result) != size):
        raise Rejected('invalid_encoding')
    return result

def safe_name(value):
    if not isinstance(value, str): raise Rejected('invalid_name')
    value = ''.join(c for c in value if c.isprintable()).strip()
    if not 1 <= len(value) <= 64: raise Rejected('invalid_name')
    return value

def local_computer_name():
    """Read the user's macOS ComputerName; never change host/certificate identity."""
    try:
        result = subprocess.run(['/usr/sbin/scutil', '--get', 'ComputerName'],
                                capture_output=True, text=True, timeout=2)
        if result.returncode == 0:
            value = ''.join(c for c in result.stdout if c.isprintable()).strip()
            # Keep the existing protocol's character and UTF-8 size limits.
            value = value[:64].encode('utf-8')[:128].decode('utf-8', errors='ignore').strip()
            return safe_name(value)
    except (OSError, UnicodeError, subprocess.TimeoutExpired, Rejected):
        pass
    return 'Mac'

def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Rejected('unsafe_state_directory')
    os.chmod(path, 0o700)

def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, ensure_ascii=False, separators=(',', ':'))
            out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def strict_der_signature(signature):
    # P-256 ECDSA DER: minimal positive INTEGERs, each in [1,n-1].
    order = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
    if not 8 <= len(signature) <= 72 or signature[0] != 0x30 or signature[1] != len(signature) - 2:
        return False
    position = 2
    for _ in range(2):
        if position + 2 > len(signature) or signature[position] != 2: return False
        length = signature[position + 1]; position += 2
        if not 1 <= length <= 33 or position + length > len(signature): return False
        number = signature[position:position + length]; position += length
        if number[0] & 0x80 or (len(number) > 1 and number[0] == 0 and not number[1] & 0x80): return False
        if not 0 < int.from_bytes(number, 'big') < order: return False
    return position == len(signature)

def verify(public_key, message, signature):
    try:
        key, signed = decode(public_key, 65), decode(signature, maximum=72)
        if key[0] != 4 or not strict_der_signature(signed): return False
        with tempfile.TemporaryDirectory(prefix='stream-proof-') as temp:
            pub = Path(temp) / 'pub.pem'; sig = Path(temp) / 'sig.der'
            encoded = b64(SPKI_PREFIX + key)
            pub.write_text('-----BEGIN PUBLIC KEY-----\n' + '\n'.join(encoded[i:i+64] for i in range(0,len(encoded),64)) + '\n-----END PUBLIC KEY-----\n')
            sig.write_bytes(signed)
            result = subprocess.run([OPENSSL, 'dgst', '-sha256', '-verify', str(pub), '-signature', str(sig)], input=message, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
            return result.returncode == 0
    except (Rejected, OSError, subprocess.TimeoutExpired): return False

def identity(directory):
    key, certificate = directory / 'host-key.pem', directory / 'host-cert.pem'
    if key.exists() != certificate.exists(): raise Rejected('incomplete_host_identity')
    if not key.exists():
        # Both files originate inside private temporary directory; no partially
        # generated identity is ever silently replaced after pairing.
        with tempfile.TemporaryDirectory(prefix='.identity-', dir=directory) as temp:
            k, c = Path(temp)/'key.pem', Path(temp)/'cert.pem'
            result = subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-pkeyopt', 'ec_param_enc:named_curve', '-sha256', '-nodes', '-keyout', str(k), '-out', str(c), '-days', '3650', '-subj', '/CN=Mac iPhone Stream Device Trust'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            if result.returncode: raise Rejected('identity_generation_failed')
            os.chmod(k, 0o600); os.chmod(c, 0o600)
            os.replace(k, key); os.replace(c, certificate)
    for file in (key, certificate):
        info = file.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Rejected('unsafe_identity_permissions')
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(certificate), str(key))
    return sha(der), context

class Trust:
    def __init__(self, directory, host_id, name=None, now=time.time, verify_signature=verify):
        self.directory, self.host_id, self.name, self.now, self.verify = directory, host_id, name or local_computer_name(), now, verify_signature
        self.lock = threading.RLock()
        self.until = 0; self.attempts = 0
        self.pairs = {}; self.challenges = {}; self.rates = collections.defaultdict(collections.deque)
        self.devices = {}
        devices_file = directory / 'devices.json'
        if devices_file.exists():
            info = devices_file.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise Rejected('unsafe_devices_permissions')
            stored = json.loads(devices_file.read_text())
            if stored.get('host_id') != host_id or stored.get('schema') != 1: raise Rejected('host_identity_changed')
            self.devices = stored['devices']

    def save(self): atomic_json(self.directory/'devices.json', {'schema':1,'host_id':self.host_id,'devices':self.devices})
    def prune(self):
        now = self.now()
        self.pairs = {k:v for k,v in self.pairs.items() if v['expires_at'] > now}
        self.challenges = {k:v for k,v in self.challenges.items() if v['expires_at'] > now}
        for key in list(self.rates):
            rate = self.rates[key]
            while rate and rate[0] < now-60: rate.popleft()
            if not rate: del self.rates[key]
    def rate_limit(self, address):
        with self.lock:
            self.prune()
            # Global cap bounds spoofed-address bookkeeping and expensive crypto.
            if sum(map(len,self.rates.values())) >= 240: raise Rejected('rate_limited',429)
            rate = self.rates[address]
            if len(rate) >= 90: raise Rejected('rate_limited',429)
            rate.append(self.now())
    def info(self):
        with self.lock:
            return {'protocol':1,'host_id':self.host_id,'name':self.name,'pairing_open':self.until > self.now() and self.attempts < 3}
    def begin(self, data):
        with self.lock:
            self.prune()
            if self.until <= self.now() or self.attempts >= 3: raise Rejected('pairing_closed',403)
            commitment = data.get('commitment')
            if not isinstance(commitment,str) or not HEX64.fullmatch(commitment): raise Rejected('invalid_commitment')
            self.attempts += 1
            pair_id = secrets.token_hex(16); nonce = b64(secrets.token_bytes(32))
            expires = min(self.until, self.now()+120)
            self.pairs[pair_id] = {'commitment':commitment,'server_nonce':nonce,'expires_at':expires,'status':'committed'}
            return {'pair_id':pair_id,'host_commitment':sha(wire('GS-HOST-COMMIT-1',self.host_id,pair_id,nonce)),'expires_at':expires}
    def pair(self, data):
        with self.lock:
            self.prune()
            pair_id = data.get('pair_id'); item = self.pairs.get(pair_id)
            if item is None or item['status'] != 'committed': raise Rejected('invalid_pairing',403)
            # The commitment can be revealed only once, including failed proofs.
            item['status'] = 'denied'
            if self.until <= self.now() or data.get('host_id') != self.host_id: raise Rejected('invalid_pairing',403)
            public_key, nonce = data.get('public_key'), data.get('nonce')
            key_bytes = decode(public_key,65); decode(nonce,32)
            if key_bytes[0] != 4 or not hmac.compare_digest(item['commitment'],sha(wire('GS-PAIR-COMMIT-1',public_key,nonce))): raise Rejected('invalid_commitment',403)
            name = safe_name(data.get('name'))
            message = wire('GS-PAIR-1',self.host_id,pair_id,public_key,nonce)
            if not self.verify(public_key,message,data.get('signature')): raise Rejected('invalid_proof',403)
            code_hash = hashlib.sha256(wire('GS-SAS-1',self.host_id,pair_id,public_key,nonce,item['server_nonce'])).digest()
            item.update(public_key=public_key,device_id=sha(key_bytes),name=name,status='pending',code=f'{int.from_bytes(code_hash[:8],"big")%1000000:06d}',poll_token=secrets.token_urlsafe(32))
            return {k:item[k] for k in ('server_nonce','code','poll_token','expires_at','status')} | {'pair_id':pair_id}
    def pair_status(self,data):
        with self.lock:
            self.prune()
            item = self.pairs.get(data.get('pair_id'))
            if item is None: return {'status':'expired'}
            token = data.get('poll_token')
            if not isinstance(token,str) or not hmac.compare_digest(token,item.get('poll_token','')) or not item.get('poll_token'): raise Rejected('invalid_pairing',403)
            result = {'status':item['status'],'host_id':self.host_id}
            if item['status'] == 'approved': result['device_id'] = item['device_id']
            return result
    def challenge(self,data):
        with self.lock:
            self.prune()
            device_id,operation = data.get('device_id'),data.get('operation')
            if operation not in ('start','status'): raise Rejected('unsupported_operation')
            if device_id not in self.devices: raise Rejected('untrusted_device',403)
            if len(self.challenges) >= 64: raise Rejected('rate_limited',429)
            challenge_id = secrets.token_hex(32); expires = int(self.now()) + 30
            message = wire('GS-COMMAND-1',self.host_id,device_id,operation,challenge_id,str(expires))
            self.challenges[challenge_id] = {'device_id':device_id,'operation':operation,'message':message,'expires_at':expires}
            return {'challenge_id':challenge_id,'message':b64(message),'expires_at':expires}
    def authorize(self,data):
        with self.lock:
            self.prune()
            challenge_id,device_id = data.get('challenge_id'),data.get('device_id')
            item = self.challenges.pop(challenge_id,None)
            if item is None or item['device_id'] != device_id or device_id not in self.devices: raise Rejected('invalid_challenge',403)
            if not self.verify(self.devices[device_id]['public_key'],item['message'],data.get('signature')): raise Rejected('invalid_proof',403)
            return item['operation']
    def local(self,data):
        with self.lock:
            self.prune()
            command = data.get('command')
            if command == 'open-pairing':
                if self.until > self.now(): return self.local({'command':'status'})
                self.until=self.now()+120; self.attempts=0
            elif command == 'close-pairing':
                self.until=0
                for item in self.pairs.values():
                    if item['status'] in ('pending','committed'): item['status']='denied'
            elif command in ('approve','deny'):
                item = self.pairs.get(data.get('pair_id'))
                if item is None or item['status'] != 'pending': raise Rejected('pair_not_pending')
                if command == 'approve':
                    code=data.get('code')
                    if not isinstance(code,str) or not hmac.compare_digest(code,item['code']): raise Rejected('code_mismatch')
                    device_id = item['device_id']
                    previous = self.devices.get(device_id)
                    self.devices[device_id] = {'name':item['name'],'public_key':item['public_key'],'paired_at':self.now()}
                    try: self.save()
                    except OSError:
                        if previous is None: self.devices.pop(device_id)
                        else: self.devices[device_id] = previous
                        raise
                    item['status']='approved'; self.until=0
                    for other in self.pairs.values():
                        if other is not item and other['status'] in ('pending','committed'): other['status']='denied'
                else: item['status']='denied'
            elif command == 'rename-device':
                device_id=data.get('device_id')
                if not isinstance(device_id,str) or device_id not in self.devices: raise Rejected('unknown_device')
                name=safe_name(data.get('name'))
                previous=self.devices[device_id]
                if previous['name'] != name:
                    # A display label is metadata, never a new trust identity.
                    self.devices[device_id]={**previous,'name':name}
                    try: self.save()
                    except BaseException:
                        self.devices[device_id]=previous
                        raise
            elif command == 'revoke':
                device_id=data.get('device_id')
                if device_id not in self.devices: raise Rejected('unknown_device')
                previous = self.devices.pop(device_id)
                try: self.save()
                except OSError:
                    self.devices[device_id] = previous
                    raise
                self.challenges={k:v for k,v in self.challenges.items() if v['device_id'] != device_id}
                for item in self.pairs.values():
                    if item.get('device_id') == device_id: item['status']='denied'
            elif command != 'status': raise Rejected('unknown_command')
            return {'state':'ready','host_id':self.host_id,'pairing_open':self.until>self.now() and self.attempts<3,'pairing_expires_at':self.until,'pending':[{'pair_id':k,**{key:v[key] for key in ('name','code','device_id','expires_at')}} for k,v in self.pairs.items() if v['status']=='pending'], 'devices':[{'device_id':k,'name':v['name'],'paired_at':v['paired_at']} for k,v in self.devices.items()]}

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    server_version='StreamTrust/1'
    def setup(self): super().setup(); self.connection.settimeout(5)
    def log_message(self,*args): pass
    def respond(self,status,data):
        raw=json.dumps(data,ensure_ascii=False,separators=(',',':')).encode()
        self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.send_header('Cache-Control','no-store'); self.send_header('Connection','close'); self.end_headers(); self.wfile.write(raw); self.close_connection=True
    def do_GET(self): self.dispatch(False)
    def do_POST(self): self.dispatch(True)
    def dispatch(self,is_post):
        try:
            self.server.trust.rate_limit(self.client_address[0])
            if not is_post:
                if self.path != '/v1/info': raise Rejected('not_found',404)
                return self.respond(200,self.server.trust.info())
            if self.headers.get_all('Transfer-Encoding'): raise Rejected('unsupported_transfer')
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) != 1 or not re.fullmatch(r'[0-9]{1,5}', lengths[0]): raise Rejected('invalid_length')
            length = int(lengths[0])
            if not 1 <= length <= MAX_BODY: raise Rejected('invalid_length',413)
            raw = self.rfile.read(length)
            if len(raw) != length: raise Rejected('invalid_length')
            data=json.loads(raw)
            if not isinstance(data,dict): raise Rejected('invalid_json')
            methods={'/v1/pair/begin':self.server.trust.begin,'/v1/pair':self.server.trust.pair,'/v1/pair/status':self.server.trust.pair_status,'/v1/challenge':self.server.trust.challenge}
            if self.path in methods: result=methods[self.path](data)
            elif self.path == '/v1/command': result=self.server.operation(self.server.trust.authorize(data), self.connection.getsockname()[0], data.get('device_id'))
            else: raise Rejected('not_found',404)
            self.respond(200,result)
        except Rejected as exc: self.respond(exc.status,{'error':exc.code})
        except (ValueError,UnicodeError,TypeError,RecursionError): self.respond(400,{'error':'invalid_json'})
        except (BrokenPipeError,ConnectionError,socket.timeout): pass
        except Exception: self.respond(500,{'error':'internal_error'})

def private_peer(address):
    try:
        ip = ipaddress.ip_address(address)
        return any(ip in ipaddress.ip_network(net) for net in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','127.0.0.0/8'))
    except ValueError: return False

class HTTPServer(ThreadingHTTPServer):
    daemon_threads=True
    request_queue_size=16
    def __init__(self,*args,**kwargs):
        self.slots=threading.BoundedSemaphore(12)
        super().__init__(*args,**kwargs)
    def verify_request(self,request,address): return private_peer(address[0])
    def handle_error(self,request,address): pass
    def process_request(self,request,address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request); return
        try: super().process_request(request,address)
        except Exception:
            self.slots.release(); raise
    def process_request_thread(self,request,address):
        secured=None
        try:
            request.settimeout(5)
            secured=self.tls.wrap_socket(request,server_side=True)
            super().process_request_thread(secured,address)
        except (OSError,ssl.SSLError): pass
        finally:
            if secured is not None: secured.close()
            else: request.close()
            self.slots.release()
