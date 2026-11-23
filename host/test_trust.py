import base64
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import trust as service

class ComputerNameTests(unittest.TestCase):
    def test_reads_computer_name_without_host_or_network_configuration(self):
        with patch.object(service.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '测试 MacBook Pro\n', '')) as run:
            self.assertEqual(service.local_computer_name(), '测试 MacBook Pro')
            self.assertEqual(run.call_args.args[0], ['/usr/sbin/scutil', '--get', 'ComputerName'])
            self.assertEqual(run.call_args.kwargs['timeout'], 2)
    def test_read_failure_uses_generic_mac_name(self):
        with patch.object(service.subprocess, 'run', side_effect=subprocess.TimeoutExpired('scutil', 2)):
            self.assertEqual(service.local_computer_name(), 'Mac')
    def test_unicode_name_fits_existing_protocol(self):
        with patch.object(service.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '名' * 100, '')):
            name = service.local_computer_name()
            self.assertLessEqual(len(name.encode('utf-8')), 128)
            self.assertTrue(name)
    def test_name_change_preserves_paired_identities(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            trust = service.Trust(root, 'a' * 64, name='Old computer name')
            trust.devices = {'b' * 64: {'name': 'iPhone', 'public_key': 'unchanged', 'paired_at': 1}}
            trust.save(); before = (root / 'devices.json').read_bytes()
            with patch.object(service, 'local_computer_name', return_value='Current computer name'):
                updated = service.Trust(root, 'a' * 64)
            self.assertEqual(updated.info()['name'], 'Current computer name')
            self.assertEqual(updated.host_id, trust.host_id)
            self.assertEqual(updated.devices, trust.devices)
            self.assertEqual((root / 'devices.json').read_bytes(), before)

class TrustTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.clock=[1000.0]; self.host='a'*64
        self.key=bytes([4])+bytes(range(64)); self.pub=service.b64(self.key)
        self.nonce=service.b64(b'n'*32)
        self.trust=service.Trust(self.root,self.host,now=lambda:self.clock[0],verify_signature=lambda p,m,s:s=='valid')
    def tearDown(self): self.temp.cleanup()
    def begin(self):
        self.trust.local({'command':'open-pairing'})
        return self.trust.begin({'commitment':service.sha(service.wire('GS-PAIR-COMMIT-1',self.pub,self.nonce))})
    def pair(self):
        first=self.begin()
        result=self.trust.pair({'host_id':self.host,'pair_id':first['pair_id'],'public_key':self.pub,'nonce':self.nonce,'name':'iPhone','signature':'valid'})
        return first,result
    def approve(self):
        first,result=self.pair()
        self.trust.local({'command':'approve','pair_id':first['pair_id'],'code':result['code']})
        return service.sha(self.key)
    def assertRejected(self,code,fn,*args):
        with self.assertRaises(service.Rejected) as ctx: fn(*args)
        self.assertEqual(code,ctx.exception.code)
    def test_closed_by_default(self):
        self.assertRejected('pairing_closed',self.trust.begin,{'commitment':'a'*64})
    def test_commitment_and_sas_match_independent_formula(self):
        first,result=self.pair()
        value='GS-HOST-COMMIT-1\n'+self.host+'\n'+first['pair_id']+'\n'+result['server_nonce']
        self.assertEqual(hashlib.sha256(value.encode()).hexdigest(),first['host_commitment'])
        text='\n'.join(['GS-SAS-1',self.host,first['pair_id'],self.pub,self.nonce,result['server_nonce']])
        code=f'{int.from_bytes(hashlib.sha256(text.encode()).digest()[:8],"big")%1000000:06d}'
        self.assertEqual(code,result['code'])
    def test_reveal_cannot_retry_after_wrong_commitment(self):
        first=self.begin(); request={'host_id':self.host,'pair_id':first['pair_id'],'public_key':self.pub,'nonce':service.b64(b'x'*32),'name':'iPhone','signature':'valid'}
        self.assertRejected('invalid_commitment',self.trust.pair,request)
        request['nonce']=self.nonce
        self.assertRejected('invalid_pairing',self.trust.pair,request)
    def test_host_mismatch_denied(self):
        first=self.begin()
        self.assertRejected('invalid_pairing',self.trust.pair,{'host_id':'b'*64,'pair_id':first['pair_id']})
    def test_bad_proof_denied(self):
        first=self.begin()
        self.assertRejected('invalid_proof',self.trust.pair,{'host_id':self.host,'pair_id':first['pair_id'],'public_key':self.pub,'nonce':self.nonce,'name':'iPhone','signature':'bad'})
    def test_approval_requires_code(self):
        first,result=self.pair()
        self.assertRejected('code_mismatch',self.trust.local,{'command':'approve','pair_id':first['pair_id'],'code':'wrong'})
        self.assertFalse(self.trust.devices)
        self.trust.local({'command':'approve','pair_id':first['pair_id'],'code':result['code']})
        status=self.trust.pair_status({'pair_id':first['pair_id'],'poll_token':result['poll_token']})
        self.assertEqual(status['status'],'approved'); self.assertEqual(status['device_id'],service.sha(self.key))
        self.assertEqual(0o600,os.stat(self.root/'devices.json').st_mode&0o777)
        loaded=service.Trust(self.root,self.host)
        self.assertIn(status['device_id'],loaded.devices)
    def test_poll_token_required(self):
        first,result=self.pair()
        self.assertRejected('invalid_pairing',self.trust.pair_status,{'pair_id':first['pair_id'],'poll_token':'wrong'})
    def test_pair_expires(self):
        first,result=self.pair(); self.clock[0]+=121
        self.assertEqual('expired',self.trust.pair_status({'pair_id':first['pair_id'],'poll_token':result['poll_token']})['status'])
    def test_three_commitments_per_window(self):
        self.trust.local({'command':'open-pairing'})
        for _ in range(3): self.trust.begin({'commitment':'a'*64})
        self.trust.local({'command':'open-pairing'})
        self.assertRejected('pairing_closed',self.trust.begin,{'commitment':'a'*64})
    def test_close_denies_pending(self):
        first,result=self.pair(); self.trust.local({'command':'close-pairing'})
        self.assertEqual('denied',self.trust.pair_status({'pair_id':first['pair_id'],'poll_token':result['poll_token']})['status'])
    def test_challenge_message_and_single_use(self):
        device=self.approve(); challenge=self.trust.challenge({'device_id':device,'operation':'start'})
        expected='\n'.join(['GS-COMMAND-1',self.host,device,'start',challenge['challenge_id'],'1030'])
        self.assertEqual(expected.encode(),base64.b64decode(challenge['message']))
        request={'device_id':device,'challenge_id':challenge['challenge_id'],'signature':'valid'}
        self.assertEqual('start',self.trust.authorize(request))
        self.assertRejected('invalid_challenge',self.trust.authorize,request)
    def test_challenge_expires(self):
        device=self.approve(); challenge=self.trust.challenge({'device_id':device,'operation':'status'}); self.clock[0]+=31
        self.assertRejected('invalid_challenge',self.trust.authorize,{'device_id':device,'challenge_id':challenge['challenge_id'],'signature':'valid'})
    def test_bad_proof_consumes_challenge(self):
        device=self.approve(); challenge=self.trust.challenge({'device_id':device,'operation':'status'})
        request={'device_id':device,'challenge_id':challenge['challenge_id'],'signature':'bad'}
        self.assertRejected('invalid_proof',self.trust.authorize,request)
        request['signature']='valid'; self.assertRejected('invalid_challenge',self.trust.authorize,request)
    def test_cross_device_denied(self):
        device=self.approve(); challenge=self.trust.challenge({'device_id':device,'operation':'status'})
        self.assertRejected('invalid_challenge',self.trust.authorize,{'device_id':'b'*64,'challenge_id':challenge['challenge_id'],'signature':'valid'})
    def test_unknown_operation_denied(self):
        device=self.approve()
        self.assertRejected('unsupported_operation',self.trust.challenge,{'device_id':device,'operation':'shell'})
    def test_revocation_invalidates_outstanding_proof(self):
        device=self.approve(); challenge=self.trust.challenge({'device_id':device,'operation':'start'})
        self.trust.local({'command':'revoke','device_id':device})
        self.assertRejected('invalid_challenge',self.trust.authorize,{'device_id':device,'challenge_id':challenge['challenge_id'],'signature':'valid'})
        self.assertRejected('untrusted_device',self.trust.challenge,{'device_id':device,'operation':'start'})
    def test_rate_limit(self):
        for _ in range(90): self.trust.rate_limit('test')
        self.assertRejected('rate_limited',self.trust.rate_limit,'test')
    def test_host_certificate_change_never_migrates_devices(self):
        self.approve()
        self.assertRejected('host_identity_changed',service.Trust,self.root,'b'*64)
    def test_local_rename_preserves_identity_and_outstanding_proof(self):
        device=self.approve(); previous=dict(self.trust.devices[device])
        challenge=self.trust.challenge({'device_id':device,'operation':'status'})
        result=self.trust.local({'command':'rename-device','device_id':device,'name':'  我的 iPhone  '})
        self.assertEqual(result['devices'][0]['name'],'我的 iPhone')
        self.assertEqual(result['host_id'],self.host)
        self.assertEqual(self.trust.devices[device],{**previous,'name':'我的 iPhone'})
        self.assertEqual(service.Trust(self.root,self.host).devices,self.trust.devices)
        self.assertEqual('status',self.trust.authorize({'device_id':device,'challenge_id':challenge['challenge_id'],'signature':'valid'}))
    def test_local_rename_rejects_missing_device_or_invalid_name(self):
        device=self.approve(); before=(self.root/'devices.json').read_bytes()
        for name in ('', '   ', 'a'*65, None):
            self.assertRejected('invalid_name',self.trust.local,{'command':'rename-device','device_id':device,'name':name})
        for unknown in ('b'*64, None, []):
            self.assertRejected('unknown_device',self.trust.local,{'command':'rename-device','device_id':unknown,'name':'New name'})
        self.assertEqual((self.root/'devices.json').read_bytes(),before)
        self.assertEqual(self.trust.devices[device]['name'],'iPhone')
    def test_local_rename_save_failure_keeps_previous_name(self):
        device=self.approve(); before=(self.root/'devices.json').read_bytes()
        with patch.object(self.trust,'save',side_effect=OSError('test write failure')):
            with self.assertRaises(OSError): self.trust.local({'command':'rename-device','device_id':device,'name':'New name'})
        self.assertEqual(self.trust.devices[device]['name'],'iPhone')
        self.assertEqual((self.root/'devices.json').read_bytes(),before)
    def test_remote_rename_command_not_authorized(self):
        device=self.approve()
        self.assertRejected('unsupported_operation',self.trust.challenge,{'device_id':device,'operation':'rename-device'})

class CryptoTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.key=self.root/'key.pem'; self.pub=self.root/'pub.der'
        subprocess.run([service.OPENSSL,'ecparam','-name','prime256v1','-genkey','-noout','-out',str(self.key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run([service.OPENSSL,'pkey','-in',str(self.key),'-pubout','-outform','DER','-out',str(self.pub)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    def tearDown(self): self.temp.cleanup()
    def test_real_p256_sha256_der_verification(self):
        public=service.b64(self.pub.read_bytes()[-65:]); message=b'bound host/device/operation/challenge'
        signed=subprocess.run([service.OPENSSL,'dgst','-sha256','-sign',str(self.key)],input=message,capture_output=True,check=True).stdout
        self.assertTrue(service.strict_der_signature(signed)); self.assertTrue(service.verify(public,message,service.b64(signed)))
        self.assertFalse(service.verify(public,message+b' tamper',service.b64(signed)))
        self.assertFalse(service.verify(public,message,service.b64(signed+b'\x00')))
        self.assertFalse(service.verify(service.b64(b'\x04'+b'\0'*64),message,service.b64(signed)))
    def test_identity_stable_and_private(self):
        first,context=service.identity(self.root); second,_=service.identity(self.root)
        self.assertEqual(first,second); self.assertEqual(ssl.TLSVersion.TLSv1_2,context.minimum_version)
        self.assertEqual(0o600,os.stat(self.root/'host-key.pem').st_mode&0o777)
    def test_incomplete_identity_refused(self):
        (self.root/'host-key.pem').write_text('partial')
        with self.assertRaises(service.Rejected) as ctx: service.identity(self.root)
        self.assertEqual('incomplete_host_identity',ctx.exception.code)
    def test_strict_der_rejects_negative_and_nonminimal(self):
        for raw in [bytes.fromhex('3006020180020101'),bytes.fromhex('300702020001020101'),bytes.fromhex('3006020100020101')]:
            self.assertFalse(service.strict_der_signature(raw))


class TransportTests(unittest.TestCase):
    def setUp(self):
        import threading
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        host,tls=service.identity(self.root)
        self.trust=service.Trust(self.root,host)
        self.server=service.HTTPServer(('127.0.0.1',0),service.Handler)
        self.server.trust=self.trust; self.server.tls=tls
        def fake_operation(operation, local_ip, device_id):
            self.assertEqual(operation, 'start')
            self.assertEqual(local_ip, '127.0.0.1')
            self.assertIn(device_id, self.trust.devices)
            return {'state':'waiting','url':'http://127.0.0.1:1/#test-only'}
        self.server.operation = fake_operation
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True); self.thread.start()
        self.key=self.root/'device.pem'; self.pub=self.root/'device.der'
        subprocess.run([service.OPENSSL,'ecparam','-name','prime256v1','-genkey','-noout','-out',str(self.key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run([service.OPENSSL,'pkey','-in',str(self.key),'-pubout','-outform','DER','-out',str(self.pub)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=3); self.temp.cleanup()
    def request(self,path,data=None):
        import http.client
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); context.check_hostname=False; context.verify_mode=ssl.CERT_NONE
        connection=http.client.HTTPSConnection('127.0.0.1',self.server.server_port,context=context,timeout=3)
        connection.connect()
        self.assertEqual(self.trust.host_id,service.sha(connection.sock.getpeercert(binary_form=True)))
        connection.request('POST' if data is not None else 'GET',path,body=json.dumps(data).encode() if data is not None else None,headers={'Content-Type':'application/json'})
        response=connection.getresponse(); result=(response.status,json.loads(response.read())); connection.close(); return result
    def sign(self,message):
        return service.b64(subprocess.run([service.OPENSSL,'dgst','-sha256','-sign',str(self.key)],input=message,capture_output=True,check=True).stdout)
    def test_tls_pair_approve_command_replay_and_revoke(self):
        self.assertEqual(self.request('/v1/info')[0],200)
        self.trust.local({'command':'open-pairing'})
        pub=service.b64(self.pub.read_bytes()[-65:]); nonce=service.b64(os.urandom(32)); host=self.trust.host_id
        status,begin=self.request('/v1/pair/begin',{'commitment':service.sha(service.wire('GS-PAIR-COMMIT-1',pub,nonce))}); self.assertEqual(status,200)
        message=service.wire('GS-PAIR-1',host,begin['pair_id'],pub,nonce)
        status,pair=self.request('/v1/pair',{'host_id':host,'pair_id':begin['pair_id'],'public_key':pub,'nonce':nonce,'name':'Offline TLS device','signature':self.sign(message)}); self.assertEqual(status,200)
        self.assertEqual(service.sha(service.wire('GS-HOST-COMMIT-1',host,pair['pair_id'],pair['server_nonce'])),begin['host_commitment'])
        self.trust.local({'command':'approve','pair_id':pair['pair_id'],'code':pair['code']})
        status,approved=self.request('/v1/pair/status',{'pair_id':pair['pair_id'],'poll_token':pair['poll_token']}); self.assertEqual(approved['status'],'approved')
        status,challenge=self.request('/v1/challenge',{'device_id':approved['device_id'],'operation':'start'}); self.assertEqual(status,200)
        command={'device_id':approved['device_id'],'challenge_id':challenge['challenge_id'],'signature':self.sign(base64.b64decode(challenge['message']))}
        status,result=self.request('/v1/command',command); self.assertEqual(status,200); self.assertIn('url',result)
        self.assertEqual(self.request('/v1/command',command)[0],403)
        self.trust.local({'command':'revoke','device_id':approved['device_id']})
        self.assertEqual(self.request('/v1/challenge',{'device_id':approved['device_id'],'operation':'start'})[0],403)
    def test_unauthenticated_command_denied(self):
        self.assertEqual(self.request('/v1/command',{'device_id':'a'*64,'challenge_id':'b'*64,'signature':'x'})[0],403)
    def test_private_peer_boundary(self):
        for address in ('127.0.0.1','10.0.0.2','172.16.1.1','192.168.1.3','169.254.1.2'): self.assertTrue(service.private_peer(address))
        for address in ('8.8.8.8','172.32.0.1','192.0.2.1','100.64.0.1','::1','nonsense'): self.assertFalse(service.private_peer(address))
