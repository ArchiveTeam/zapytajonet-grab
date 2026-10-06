# encoding=utf8
import base64
from distutils.version import StrictVersion
import datetime
import gzip
import hashlib
import os
import re
import shutil
import socket
import sys
import time

if sys.version_info[0] < 3:
    from urllib import unquote, quote
else:
    from urllib.parse import unquote, quote

import seesaw
from seesaw.config import realize, NumberConfigValue
from seesaw.externalprocess import WgetDownload
from seesaw.item import ItemInterpolation, ItemValue
from seesaw.pipeline import Pipeline
from seesaw.project import Project
from seesaw.task import SimpleTask, LimitConcurrent
from seesaw.tracker import GetItemFromTracker, PrepareStatsForTracker, \
    UploadWithTracker, SendDoneToTracker
from seesaw.util import find_executable

if StrictVersion(seesaw.__version__) < StrictVersion('0.8.5'):
    raise Exception('This pipeline needs seesaw version 0.8.5 or higher.')


###########################################################################
# Find a useful Wget+Lua executable.
#
# WGET_AT will be set to the first path that
# 1. does not crash with --version, and
# 2. prints the required version string

class HigherVersion:
    def __init__(self, expression, min_version):
        self._expression = re.compile(expression)
        self._min_version = min_version

    def search(self, text):
        for result in self._expression.findall(text):
            if result >= self._min_version:
                print('Found version {}.'.format(result))
                return True


WGET_AT = find_executable(
    'Wget+AT',
    HigherVersion(
        r'(GNU Wget 1\.[0-9]{2}\.[0-9]{1}-at\.[0-9]{8}\.[0-9]{2})[^0-9a-zA-Z\.-_]',
        'GNU Wget 1.21.3-at.20260319.01'
    ),
    [
        './wget-at',
        '/home/warrior/data/wget-at-nss'
    ]
)

if not WGET_AT:
    raise Exception('No usable Wget+At found.')


###########################################################################
# The version number of this pipeline definition.
#
# Update this each time you make a non-cosmetic change.
# It will be added to the WARC files and reported to the tracker.
VERSION = '20261006.02'
TRACKER_ID = 'zapytajonet'
TRACKER_HOST = 'legacy-api.arpa.li'
MULTI_ITEM_SIZE = 100


###########################################################################
# This section defines project-specific tasks.
#
# Simple tasks (tasks that do not need any concurrency) are based on the
# SimpleTask class and have a process(item) method that is called for
# each item.
class CheckIP(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'CheckIP')
        self._counter = 0

    def process(self, item):
        # NEW for 2014! Check if we are behind firewall/proxy

        if self._counter <= 0:
            item.log_output('Checking IP address.')
            ip_set = set()

            ip_set.add(socket.gethostbyname('twitter.com'))
            #ip_set.add(socket.gethostbyname('facebook.com'))
            ip_set.add(socket.gethostbyname('youtube.com'))
            ip_set.add(socket.gethostbyname('microsoft.com'))
            ip_set.add(socket.gethostbyname('icanhas.cheezburger.com'))
            ip_set.add(socket.gethostbyname('archiveteam.org'))

            if len(ip_set) != 5:
                item.log_output('Got IP addresses: {0}'.format(ip_set))
                item.log_output(
                    'Are you behind a firewall/proxy? That is a big no-no!')
                raise Exception(
                    'Are you behind a firewall/proxy? That is a big no-no!')

        # Check only occasionally
        if self._counter <= 0:
            self._counter = 10
        else:
            self._counter -= 1


class PrepareDirectories(SimpleTask):
    def __init__(self, warc_prefix):
        SimpleTask.__init__(self, 'PrepareDirectories')
        self.warc_prefix = warc_prefix

    def process(self, item):
        item_name = item['item_name']
        item_name_hash = hashlib.sha1(item_name.encode('utf8')).hexdigest()
        escaped_item_name = item_name_hash
        dirname = '/'.join((item['data_dir'], escaped_item_name))

        if os.path.isdir(dirname):
            shutil.rmtree(dirname)

        os.makedirs(dirname)

        item['item_dir'] = dirname
        item['warc_file_base'] = '-'.join([
            self.warc_prefix,
            item_name_hash,
            time.strftime('%Y%m%d-%H%M%S')
        ])

        open('%(item_dir)s/%(warc_file_base)s.warc.gz' % item, 'w').close()


class CheckIntegrity(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'CheckIntegrity')

    def process(self, item):
        # experimental, first use
        seen_digests = set()
        total = 0
        chunksize = 1024 ** 2
        with gzip.open('%(item_dir)s/%(warc_file_base)s.warc.gz' % item, 'rb') as f:
            d = f.readline()
            while True:
                while b'\r\n\r\n' not in d:
                    chunk = f.readline()
                    if not chunk:
                        raise Exception('Incomplete WARC headers.')
                    d += chunk
                warc_headers_raw = d.split(b'\r\n\r\n', 1)[0]
                warc_headers = {}
                for header in warc_headers_raw.split(b'\r\n'):
                    if b': ' not in header:
                        continue
                    k, v = header.split(b': ', 1)
                    warc_headers[str(k, 'utf8')] = v
                item.log_output('Checking {} {}.'.format(
                    str(warc_headers['WARC-Type'], 'utf8'),
                    str(warc_headers['WARC-Record-ID'], 'utf8')
                ))
                d = b''
                block_digest = hashlib.sha1()
                has_payload = 'WARC-Payload-Digest' in warc_headers \
                    and warc_headers['WARC-Type'] != b'revisit' \
                    and warc_headers['WARC-Payload-Digest'] != warc_headers['WARC-Block-Digest'] # for now
                if warc_headers['WARC-Type'] == b'revisit':
                    assert warc_headers['WARC-Payload-Digest'] in seen_digests
                payload_digest = None
                data = b''
                chunked = False
                length = None
                content_length = int(warc_headers['Content-Length'])
                for i in range(0, content_length, chunksize):
                    d = f.read(min(chunksize, content_length-i))
                    if len(d) != min(chunksize, content_length-i):
                        raise Exception('Incomplete WARC record.')
                    if has_payload:
                        if payload_digest is None:
                            data += d
                            if b'\r\n\r\n' in data:
                                http_headers_raw, data = data.split(b'\r\n\r\n', 1)
                                payload_digest = hashlib.sha1()
                                if b'transfer-encoding: ' in http_headers_raw.lower():
                                    chunked = b'transfer-encoding: chunked' in http_headers_raw.lower()
                                    has_payload = chunked
                                if not chunked:
                                    payload_digest.update(data)
                                    data = b''
                        elif chunked:
                            data += d
                        else:
                            payload_digest.update(d)
                        if chunked:
                            while length != -1:
                                if length is None:
                                    if b'\r\n' not in data:
                                        break
                                    line, data = data.split(b'\r\n', 1)
                                    length = int(line.split(b';', 1)[0], 16)
                                    if length < 0:
                                        raise Exception('Invalid chunked payload.')
                                    if length == 0:
                                        length = -1
                                        break
                                if length > 0:
                                    chunk = data[:length]
                                    payload_digest.update(chunk)
                                    length -= len(chunk)
                                    data = data[len(chunk):]
                                    if length > 0:
                                        break
                                if len(data) < 2:
                                    break
                                if data[:2] != b'\r\n':
                                    raise Exception('Invalid chunked payload.')
                                data = data[2:]
                                length = None
                            if length == -1:
                                data = b''
                    block_digest.update(d)
                block_digest = b'sha1:' + base64.b32encode(block_digest.digest())
                if block_digest != warc_headers['WARC-Block-Digest']:
                    raise Exception('Block digests do not match. Got {}, expected {}.'
                                    .format(block_digest, warc_headers['WARC-Block-Digest']))
                if chunked and length != -1:
                    raise Exception('Incomplete chunked payload.')
                if has_payload:
                    payload_digest = b'sha1:' + base64.b32encode(payload_digest.digest())
                    if payload_digest != warc_headers['WARC-Payload-Digest']:
                        raise Exception('Payload digests do not match. Got {}, expected {}.'
                                        .format(payload_digest, warc_headers['WARC-Payload-Digest']))
                    seen_digests.add(payload_digest)
                if f.read(4) != b'\r\n\r\n':
                    raise Exception('Invalid WARC separator.')
                d = f.readline()
                if not d:
                    break


class MoveFiles(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'MoveFiles')

    def process(self, item):
        os.rename('%(item_dir)s/%(warc_file_base)s.warc.gz' % item,
              '%(data_dir)s/%(warc_file_base)s.warc.gz' % item)

        shutil.rmtree('%(item_dir)s' % item)


def normalize_string(s):
    while True:
        temp = unquote(s).strip().lower()
        if temp == s:
            break
        s = temp
    return s


class SetBadUrls(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'SetBadUrls')

    def process(self, item):
        item['item_name_original'] = item['item_name']
        items = item['item_name'].split('\0')
        items_lower = [normalize_string(s) for s in items]
        with open('%(item_dir)s/%(warc_file_base)s_bad-items.txt' % item, 'r') as f:
            for s in {
                normalize_string(s) for s in f
            }:
                index = items_lower.index(s)
                item.log_output('Item {} is aborted.'.format(s))
                items.pop(index)
                items_lower.pop(index)
        item['item_name'] = '\0'.join(items)


class MaybeUploadWithTracker(UploadWithTracker):
    def enqueue(self, item):
        if len(item['item_name']) == 0:
            item.log_output('Skipping UploadWithTracker.')
            return self.complete_item(item)
        return super(MaybeUploadWithTracker, self).enqueue(item)


class MaybeSendDoneToTracker(SendDoneToTracker):
    def enqueue(self, item):
        if len(item['item_name']) == 0:
            return self.complete_item(item)
        return super(MaybeSendDoneToTracker, self).enqueue(item)


def get_hash(filename):
    with open(filename, 'rb') as in_file:
        return hashlib.sha1(in_file.read()).hexdigest()


CWD = os.getcwd()
PIPELINE_SHA1 = get_hash(os.path.join(CWD, 'pipeline.py'))
LUA_SHA1 = get_hash(os.path.join(CWD, 'zapytajonet.lua'))


def stats_id_function(item):
    d = {
        'pipeline_hash': PIPELINE_SHA1,
        'lua_hash': LUA_SHA1,
        'python_version': sys.version,
    }

    return d


class WgetArgs(object):
    def realize(self, item):
        wget_args = [
            WGET_AT,
            '-nv',
            '--no-hsts',
            '--host-lookups', 'dns',
            '--hosts-file', '/dev/null',
            '--resolvconf-file', '/dev/null',
            '--dns-servers', ','.join([
                '1.1.1.1',
                '1.0.0.1',
                '2606:4700:4700::1111',
                '2606:4700:4700::1001',
            ]),
            '--reject-reserved-subnets',
            #'--prefer-family', ('IPv4' if 'PREFER_IPV4' in os.environ else 'IPv6'),
            '--content-on-error',
            '--lua-script', 'zapytajonet.lua',
            '-o', ItemInterpolation('%(item_dir)s/wget.log'),
            '--output-document', ItemInterpolation('%(item_dir)s/wget.tmp'),
            '--truncate-output',
            '-e', 'robots=off',
            '--recursive', '--level=inf',
            '--no-parent',
            '--page-requisites',
            '--timeout', '60',
            '--connect-timeout', '10',
            '--tries', 'inf',
            '--span-hosts',
            '--waitretry', '30',
            '--wait', '1',
            '--random-wait',
            '--warc-file', ItemInterpolation('%(item_dir)s/%(warc_file_base)s'),
            '--warc-header', 'operator: Archive Team',
            '--warc-header', 'x-wget-at-project-version: ' + VERSION,
            '--warc-header', 'x-wget-at-project-name: ' + TRACKER_ID,
            '--warc-dedup-url-agnostic',
            '--impersonate', 'firefox148-h1',
            '--header', 'Accept-Encoding: identity'
        ]

        for item_name in item['item_name'].split('\0'):
            wget_args.extend(['--warc-header', 'x-wget-at-project-item-name: '+item_name])
            wget_args.append('item-name://'+item_name)
            item_type, item_value = item_name.split(':', 1)
            if item_type == 'question':
                wget_args.extend(['--warc-header', 'zapytajonet-question: '+item_value])
                wget_args.append('https://zapytaj.onet.pl/Category/000,000/2,'+item_value+',redir.html')
            elif item_type == 'user':
                wget_args.extend(['--warc-header', 'zapytajonet-user: '+item_value])
                wget_args.append('https://zapytaj.onet.pl/Profile/user_'+item_value+'.html')
            elif item_type == 'club':
                wget_args.extend(['--warc-header', 'zapytajonet-club: '+item_value])
                wget_args.append('https://zapytaj.onet.pl/klub/'+quote(unquote(item_value), safe=''))
            elif item_type == 'media':
                wget_args.extend(['--warc-header', 'zapytajonet-media: '+item_value])
                wget_args.append('https://'+item_value)
            else:
                raise Exception('Unknown item')

        if 'bind_address' in globals():
            wget_args.extend(['--bind-address', globals()['bind_address']])
            print('')
            print('*** Wget will bind address at {0} ***'.format(
                globals()['bind_address']))
            print('')

        return realize(wget_args, item)


###########################################################################
# Initialize the project.
#
# This will be shown in the warrior management panel. The logo should not
# be too big. The deadline is optional.
project = Project(
    title=TRACKER_ID,
    project_html='''
        <img class="project-logo" alt="Project logo" src="https://wiki.archiveteam.org/images/7/7c/Zapytaj-onet-icon.png" height="50px" title=""/>
        <h2>Zapytaj Onet <span class="links"><a href="https://zapytaj.onet.pl/">Website</a> &middot; <a href="https://tracker.archiveteam.org/zapytajonet/">Leaderboard</a> &middot; <a href="https://wiki.archiveteam.org/index.php/Zapytaj_Onet">Wiki</a></span></h2>
        <p>Archiving Zapytaj Onet.</p>
    ''',
    utc_deadline=datetime.datetime(2026, 9, 30, 0, 0, 0)
)


pipeline = Pipeline(
    CheckIP(),
    GetItemFromTracker('https://{}/{}/multi={}/'
        .format(TRACKER_HOST, TRACKER_ID, MULTI_ITEM_SIZE),
        downloader, VERSION),
    PrepareDirectories(warc_prefix=TRACKER_ID),
    WgetDownload(
        WgetArgs(),
        max_tries=1,
        accept_on_exit_code=[0, 4, 8],
        env={
            'item_dir': ItemValue('item_dir'),
            'warc_file_base': ItemValue('warc_file_base')
        }
    ),
    CheckIntegrity(),
    SetBadUrls(),
    PrepareStatsForTracker(
        defaults={'downloader': downloader, 'version': VERSION},
        file_groups={
            'data': [
                ItemInterpolation('%(item_dir)s/%(warc_file_base)s.warc.gz')
            ]
        },
        id_function=stats_id_function,
    ),
    MoveFiles(),
    LimitConcurrent(NumberConfigValue(min=1, max=20, default='20',
        name='shared:rsync_threads', title='Rsync threads',
        description='The maximum number of concurrent uploads.'),
        MaybeUploadWithTracker(
            'https://%s/%s' % (TRACKER_HOST, TRACKER_ID),
            downloader=downloader,
            version=VERSION,
            files=[
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s.warc.gz')
            ],
            rsync_target_source_path=ItemInterpolation('%(data_dir)s/'),
            rsync_extra_args=[
                '--recursive',
                '--min-size', '1',
                '--no-compress',
                '--compress-level', '0'
            ]
        ),
    ),
    MaybeSendDoneToTracker(
        tracker_url='https://%s/%s' % (TRACKER_HOST, TRACKER_ID),
        stats=ItemValue('stats')
    )
)
